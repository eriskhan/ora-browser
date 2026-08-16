import AppKit
import Foundation
@preconcurrency import WebKit

@MainActor
final class WebExtensionPermissionPrompter: NSObject, WKWebExtensionControllerDelegate {
    static let shared = WebExtensionPermissionPrompter()

    struct InitialAccessDecision {
        let permissions: Set<WKWebExtension.Permission>
        let matchPatterns: Set<WKWebExtension.MatchPattern>
    }

    private final class WeakTabManager {
        weak var value: TabManager?

        init(_ value: TabManager) {
            self.value = value
        }
    }

    private struct WindowKey: Hashable {
        let tabManager: ObjectIdentifier
        let spaceID: UUID
    }

    private var popupAnchor: (view: NSView, rect: NSRect)?
    private var tabManagers: [ObjectIdentifier: WeakTabManager] = [:]
    private var windowAdapters: [WindowKey: OraWebExtensionWindow] = [:]
    private var announcedTabs: Set<ObjectIdentifier> = []

    func register(tabManager: TabManager) {
        tabManagers[ObjectIdentifier(tabManager)] = WeakTabManager(tabManager)
    }

    func unregister(tabManager: TabManager) {
        let identifier = ObjectIdentifier(tabManager)
        tabManagers[identifier] = nil
        windowAdapters = windowAdapters.filter { $0.key.tabManager != identifier }
    }

    func windowAdapter(for tabManager: TabManager, spaceID: UUID) -> OraWebExtensionWindow {
        let key = WindowKey(tabManager: ObjectIdentifier(tabManager), spaceID: spaceID)
        if let existing = windowAdapters[key] {
            return existing
        }

        let adapter = OraWebExtensionWindow(tabManager: tabManager, spaceID: spaceID)
        windowAdapters[key] = adapter
        return adapter
    }

    func tabDidBecomeAvailable(_ tab: Tab, controller: WKWebExtensionController) {
        let identifier = ObjectIdentifier(tab)
        guard announcedTabs.insert(identifier).inserted else { return }

        let adapter = OraWebExtensionTabCache.shared.adapter(for: tab)
        controller.didOpenTab(adapter)
        if tab.tabManager?.activeTab?.id == tab.id {
            controller.didActivateTab(adapter, previousActiveTab: nil)
        }
    }

    func activeTabDidChange(from oldTab: Tab?, to newTab: Tab?) {
        guard let newTab, !newTab.isPrivate,
              let controller = newTab.browserPage?.webExtensionWebView.configuration.webExtensionController
        else {
            return
        }

        let newAdapter = OraWebExtensionTabCache.shared.adapter(for: newTab)
        let previousAdapter: OraWebExtensionTab? = if let oldTab, oldTab.container.id == newTab.container.id {
            OraWebExtensionTabCache.shared.adapter(for: oldTab)
        } else {
            nil
        }
        controller.didActivateTab(newAdapter, previousActiveTab: previousAdapter)
    }

    func requestInitialAccess(for webExtension: WKWebExtension) -> InitialAccessDecision {
        let permissions = webExtension.requestedPermissions
        let matchPatterns = webExtension.requestedPermissionMatchPatterns
        guard !permissions.isEmpty || !matchPatterns.isEmpty else {
            return InitialAccessDecision(permissions: [], matchPatterns: [])
        }

        let details = permissionDescription(permissions: permissions, matchPatterns: matchPatterns)
        let allowed = showPrompt(
            extensionName: webExtension.displayName ?? "This extension",
            message: "Requests access when enabled in this Ora space:\n\n\(details)"
        )
        return InitialAccessDecision(
            permissions: allowed ? permissions : [],
            matchPatterns: allowed ? matchPatterns : []
        )
    }

    func performAction(
        for context: WKWebExtensionContext,
        tab: OraWebExtensionTab,
        sourceView: NSView
    ) {
        popupAnchor = (sourceView, sourceView.bounds)
        context.userGesturePerformed(in: tab)
        let presentsPopup = context.action(for: tab)?.presentsPopup ?? false
        context.performAction(for: tab)
        if !presentsPopup {
            popupAnchor = nil
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        orderedWindowAdapters(for: controller)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        orderedWindowAdapters(for: controller).first(where: { $0.browserWindow?.isKeyWindow == true })
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        guard let spaceID = controller.configuration.identifier else {
            completionHandler(nil, webExtensionError("The extension controller has no space identifier."))
            return
        }

        let requestedWindow = configuration.window as? OraWebExtensionWindow
        let targetWindow = requestedWindow
            ?? orderedWindowAdapters(for: controller).first(where: { $0.browserWindow?.isKeyWindow == true })
            ?? orderedWindowAdapters(for: controller).first

        guard let targetWindow, let tabManager = targetWindow.tabManager else {
            completionHandler(nil, webExtensionError("No Ora window is available for this extension."))
            return
        }

        guard tabManager.activeContainer?.id == spaceID else {
            completionHandler(nil, webExtensionError("Activate this Ora space before an extension opens a new tab."))
            return
        }

        let url = configuration.url ?? URL(string: "https://www.google.com")!
        if url.scheme == extensionContext.baseURL.scheme, url.host == extensionContext.baseURL.host {
            completionHandler(nil, webExtensionError("Opening extension pages in normal Ora tabs is not supported yet."))
            return
        }

        let previousTab = tabManager.activeTab
        let historyManager = HistoryManager(
            modelContainer: tabManager.modelContainer,
            modelContext: tabManager.modelContext
        )
        guard let newTab = tabManager.openTab(
            url: url,
            historyManager: historyManager,
            focusAfterOpening: configuration.shouldBeActive,
            isPrivate: false,
            loadSilently: true
        ) else {
            completionHandler(nil, webExtensionError("Ora could not create the requested tab."))
            return
        }

        if configuration.shouldBePinned, newTab.type != .pinned {
            tabManager.togglePinTab(newTab)
        }

        let adapter = OraWebExtensionTabCache.shared.adapter(for: newTab)
        controller.didOpenTab(adapter)
        if configuration.shouldBeActive {
            let previousAdapter = previousTab.map { OraWebExtensionTabCache.shared.adapter(for: $0) }
            controller.didActivateTab(adapter, previousActiveTab: previousAdapter)
        }
        completionHandler(adapter, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        let allowed = showPrompt(
            extensionName: extensionContext.webExtension.displayName ?? "This extension",
            message: "Requests additional permissions:\n\n\(permissionDescription(permissions: permissions, matchPatterns: []))"
        )
        let granted = allowed ? permissions : []
        if allowed {
            WebExtensionManager.shared.recordGrantedPermissions(granted, for: extensionContext)
        }
        completionHandler(granted, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        let allowed = showPrompt(
            extensionName: extensionContext.webExtension.displayName ?? "This extension",
            message: "Requests access to these websites:\n\n\(permissionDescription(permissions: [], matchPatterns: matchPatterns))"
        )
        let granted = allowed ? matchPatterns : []
        if allowed {
            WebExtensionManager.shared.recordGrantedMatchPatterns(granted, for: extensionContext)
        }
        completionHandler(granted, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        let displayURLs = urls
            .map(\.absoluteString)
            .sorted()
            .prefix(12)
            .joined(separator: "\n")
        let allowed = showPrompt(
            extensionName: extensionContext.webExtension.displayName ?? "This extension",
            message: "Requests access to:\n\n\(displayURLs)"
        )
        completionHandler(allowed ? urls : [], nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let popover = action.popupPopover else {
            completionHandler(nil)
            return
        }

        let anchor = popupAnchor ?? fallbackPopupAnchor()
        popupAnchor = nil
        guard let anchor else {
            completionHandler(webExtensionError("No browser window is available to present the extension popup."))
            return
        }

        popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: .minY)
        completionHandler(nil)
    }

    private func orderedWindowAdapters(for controller: WKWebExtensionController) -> [OraWebExtensionWindow] {
        guard let spaceID = controller.configuration.identifier else { return [] }

        tabManagers = tabManagers.filter { $0.value.value != nil }
        let adapters = tabManagers.values.compactMap { weakManager -> OraWebExtensionWindow? in
            guard let tabManager = weakManager.value,
                  tabManager.containers.contains(where: { $0.id == spaceID })
            else {
                return nil
            }
            return windowAdapter(for: tabManager, spaceID: spaceID)
        }

        return adapters.sorted { lhs, rhs in
            (lhs.browserWindow?.isKeyWindow == true) && (rhs.browserWindow?.isKeyWindow != true)
        }
    }

    private func fallbackPopupAnchor() -> (view: NSView, rect: NSRect)? {
        guard let view = NSApp.keyWindow?.contentView else { return nil }
        let rect = NSRect(x: view.bounds.maxX - 32, y: view.bounds.maxY - 32, width: 24, height: 24)
        return (view, rect)
    }

    private func showPrompt(extensionName: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow \(extensionName)?"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func permissionDescription(
        permissions: Set<WKWebExtension.Permission>,
        matchPatterns: Set<WKWebExtension.MatchPattern>
    ) -> String {
        var lines = permissions.map(\.rawValue).sorted()
        lines.append(contentsOf: matchPatterns.map(\.string).sorted())
        if lines.count > 12 {
            let remaining = lines.count - 12
            lines = Array(lines.prefix(12)) + ["…and \(remaining) more"]
        }
        return lines.joined(separator: "\n")
    }

    private func webExtensionError(_ message: String) -> NSError {
        NSError(
            domain: "Ora.WebExtension",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
