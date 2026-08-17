import AppKit
import Combine
import Foundation
@preconcurrency import WebKit

@MainActor
final class ExtensionManager: NSObject, ObservableObject {
    enum ExtensionError: LocalizedError {
        case extensionNotFound
        case unsupportedLocalResource
        case windowUnavailable

        var errorDescription: String? {
            switch self {
            case .extensionNotFound:
                return "The extension is no longer installed."
            case .unsupportedLocalResource:
                return "Choose an unpacked extension folder, ZIP archive, or Firefox XPI package."
            case .windowUnavailable:
                return "No Ora browser window is available for this extension request."
            }
        }
    }

    static let shared = ExtensionManager()

    @Published private(set) var installedExtensions: [InstalledWebExtension] = []
    @Published private(set) var loadErrors: [UUID: String] = [:]

    let controller: WKWebExtensionController

    private static let controllerIdentifier = UUID(uuidString: "05D136B4-08F0-4A4D-A6CC-4E386B206D31")!
    private let registryDefaultsKey = "webExtensions.registry.v2"
    private let fileManager = FileManager.default
    private var extensionObjects: [UUID: WKWebExtension] = [:]
    private var contexts: [UUID: WKWebExtensionContext] = [:]
    private var tabWrappers: [UUID: OraWebExtensionTab] = [:]
    private var windowWrappers: [ObjectIdentifier: OraWebExtensionWindow] = [:]
    private var didLoadRegistryExtensions = false

    override private init() {
        let configuration = WKWebExtensionController.Configuration(identifier: Self.controllerIdentifier)
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
        restoreRegistry()
    }

    func attach(tabManager: TabManager, window: NSWindow?, isPrivate: Bool) {
        let key = ObjectIdentifier(tabManager)
        if let existing = windowWrappers[key] {
            existing.window = window
            if window?.isKeyWindow == true {
                controller.didFocusWindow(existing)
            }
        } else {
            let wrapper = OraWebExtensionWindow(
                tabManager: tabManager,
                window: window,
                isPrivate: isPrivate,
                owner: self
            )
            windowWrappers[key] = wrapper
            for tab in orderedTabs(for: tabManager) {
                _ = ensureTabWrapper(for: tab)
            }
            controller.didOpenWindow(wrapper)
            if window?.isKeyWindow == true {
                controller.didFocusWindow(wrapper)
            }
        }
    }

    func detach(tabManager: TabManager) {
        let key = ObjectIdentifier(tabManager)
        guard let wrapper = windowWrappers.removeValue(forKey: key) else { return }
        controller.didCloseWindow(wrapper)
        tabWrappers = tabWrappers.filter { _, wrapper in
            wrapper.tab?.tabManager !== tabManager
        }
    }

    func updateWindow(_ window: NSWindow?, for tabManager: TabManager) {
        guard let wrapper = windowWrappers[ObjectIdentifier(tabManager)] else { return }
        wrapper.window = window
        if window?.isKeyWindow == true {
            controller.didFocusWindow(wrapper)
        }
    }

    func loadAllExtensions() async {
        guard !didLoadRegistryExtensions else { return }
        didLoadRegistryExtensions = true
        for installedExtension in installedExtensions where installedExtension.isEnabled {
            do {
                try await load(installedExtension)
            } catch {
                loadErrors[installedExtension.id] = error.localizedDescription
            }
        }
    }

    @discardableResult
    func installLocalResource(at sourceURL: URL) async throws -> InstalledWebExtension {
        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let installID = UUID()
        let installDirectory = try makeInstallDirectory(for: installID)

        do {
            let copiedURL = try copyLocalResource(sourceURL, into: installDirectory)
            let prepared = try WebExtensionPackagePreparer.prepare(
                resourceURL: copiedURL,
                installDirectory: installDirectory
            )
            let extensionObject = try await WKWebExtension(resourceBaseURL: prepared.resourceURL)
            let runtimeIdentifier = runtimeIdentifier(for: extensionObject, fallback: installID)
            let relativePath = prepared.resourceURL.path.replacingOccurrences(
                of: extensionsDirectory.path + "/",
                with: ""
            )
            var installedExtension = InstalledWebExtension(
                id: installID,
                runtimeIdentifier: runtimeIdentifier,
                name: extensionObject.displayName ?? "Unnamed Extension",
                version: extensionObject.displayVersion ?? extensionObject.version ?? "Unknown",
                manifestVersion: extensionObject.manifestVersion,
                resourceRelativePath: relativePath,
                originalPermissions: prepared.originalPermissions,
                compatibilityRevision: prepared.compatibilityRevision
            )

            let requestedPermissions = Set(extensionObject.requestedPermissions.map(\.rawValue))
                .intersection(prepared.originalPermissions)
            let permissionDecision = requestInitialAccess(
                permissions: requestedPermissions,
                matchPatterns: Set(extensionObject.requestedPermissionMatchPatterns.map(\.string)),
                name: installedExtension.name
            )
            installedExtension.permissionDecisionMade = true
            if permissionDecision {
                installedExtension.grantedPermissions = requestedPermissions
                installedExtension.grantedMatchPatterns = Set(
                    extensionObject.requestedPermissionMatchPatterns.map(\.string)
                )
            }

            extensionObjects[installID] = extensionObject
            installedExtensions.append(installedExtension)
            installedExtensions.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            persistRegistry()
            try await load(installedExtension)
            return installedExtension
        } catch {
            try? fileManager.removeItem(at: installDirectory)
            throw error
        }
    }

    func removeExtension(_ extensionID: UUID) {
        guard let installedExtension = installedExtensions.first(where: { $0.id == extensionID }) else { return }
        if let context = contexts.removeValue(forKey: extensionID) {
            try? controller.unload(context)
        }
        extensionObjects[extensionID] = nil
        loadErrors[extensionID] = nil
        installedExtensions.removeAll { $0.id == extensionID }
        persistRegistry()
        try? fileManager.removeItem(at: extensionsDirectory.appendingPathComponent(installedExtension.id.uuidString))
    }

    func setEnabled(_ enabled: Bool, extensionID: UUID) async throws {
        guard let index = installedExtensions.firstIndex(where: { $0.id == extensionID }) else {
            throw ExtensionError.extensionNotFound
        }
        installedExtensions[index].isEnabled = enabled
        persistRegistry()

        if enabled {
            try await load(installedExtensions[index])
        } else if let context = contexts.removeValue(forKey: extensionID) {
            try controller.unload(context)
        }
    }

    func window(for tab: Tab) -> OraWebExtensionWindow? {
        guard let tabManager = tab.tabManager else { return nil }
        return windowWrappers[ObjectIdentifier(tabManager)]
    }

    func index(of wrapper: OraWebExtensionTab) -> Int {
        guard let tab = wrapper.tab, let window = window(for: tab) else { return NSNotFound }
        return tabs(in: window).firstIndex { candidate in
            (candidate as? OraWebExtensionTab) === wrapper
        } ?? NSNotFound
    }

    func tabs(in window: OraWebExtensionWindow) -> [any WKWebExtensionTab] {
        guard let tabManager = window.tabManager else { return [] }
        return orderedTabs(for: tabManager).map { ensureTabWrapper(for: $0) }
    }

    func activeTab(in window: OraWebExtensionWindow) -> (any WKWebExtensionTab)? {
        guard let tab = window.tabManager?.activeTab else { return nil }
        return ensureTabWrapper(for: tab)
    }

    func didCreateTab(_ tab: Tab) {
        let existed = tabWrappers[tab.id] != nil
        let wrapper = ensureTabWrapper(for: tab)
        if !existed {
            controller.didOpenTab(wrapper)
        }
    }

    func didCloseTab(_ tab: Tab, windowIsClosing: Bool = false) {
        guard let wrapper = tabWrappers.removeValue(forKey: tab.id) else { return }
        controller.didCloseTab(wrapper, windowIsClosing: windowIsClosing)
    }

    func didActivateTab(_ tab: Tab, previousTab: Tab?) {
        let wrapper = ensureTabWrapper(for: tab)
        let previousWrapper = previousTab.map { ensureTabWrapper(for: $0) }
        controller.didActivateTab(wrapper, previousActiveTab: previousWrapper)
    }

    func didChangeTabProperties(_ properties: WKWebExtension.TabChangedProperties, for tab: Tab) {
        controller.didChangeTabProperties(properties, for: ensureTabWrapper(for: tab))
    }

    func setPinned(_ pinned: Bool, for tab: Tab) {
        guard let tabManager = tab.tabManager, (tab.type == .pinned) != pinned else { return }
        tabManager.togglePinTab(tab)
    }

    func activate(_ tab: Tab) {
        tab.tabManager?.activateTab(tab)
    }

    func close(_ tab: Tab) {
        tab.tabManager?.closeTab(tab: tab)
    }

    func hasBridgeAccess(to permission: String, for context: WKWebExtensionContext) -> Bool {
        guard let index = recordIndex(for: context) else { return false }
        let installedExtension = installedExtensions[index]
        return installedExtension.originalPermissions.contains(permission) &&
            installedExtension.grantedPermissions.contains(permission)
    }

    func originalPermissions(for context: WKWebExtensionContext) -> Set<String> {
        guard let index = recordIndex(for: context) else { return [] }
        return installedExtensions[index].originalPermissions
    }

    func grantedOriginalPermissions(for context: WKWebExtensionContext) -> Set<String> {
        guard let index = recordIndex(for: context) else { return [] }
        return installedExtensions[index].grantedPermissions
            .intersection(installedExtensions[index].originalPermissions)
    }

    func setBridgePermission(_ permission: String, granted: Bool, for context: WKWebExtensionContext) {
        guard let index = recordIndex(for: context),
              installedExtensions[index].originalPermissions.contains(permission)
        else { return }

        if granted {
            installedExtensions[index].grantedPermissions.insert(permission)
        } else {
            installedExtensions[index].grantedPermissions.remove(permission)
        }
        persistRegistry()
    }

    private func ensureTabWrapper(for tab: Tab) -> OraWebExtensionTab {
        if let existing = tabWrappers[tab.id] {
            return existing
        }
        let wrapper = OraWebExtensionTab(tab: tab, owner: self)
        tabWrappers[tab.id] = wrapper
        return wrapper
    }

    private func orderedTabs(for tabManager: TabManager) -> [Tab] {
        tabManager.containers.flatMap { container in
            container.tabs.sorted { $0.order < $1.order }
        }
    }

    private func load(_ installedExtension: InstalledWebExtension) async throws {
        guard installedExtension.isEnabled else { return }
        if contexts[installedExtension.id] != nil {
            return
        }

        let currentExtension = try ensureCurrentCompatibility(for: installedExtension)
        let resourceURL = extensionsDirectory.appendingPathComponent(currentExtension.resourceRelativePath)
        let extensionObject: WKWebExtension
        if let cached = extensionObjects[currentExtension.id] {
            extensionObject = cached
        } else {
            extensionObject = try await WKWebExtension(resourceBaseURL: resourceURL)
            extensionObjects[currentExtension.id] = extensionObject
        }

        let context = WKWebExtensionContext(for: extensionObject)
        context.uniqueIdentifier = currentExtension.runtimeIdentifier
        context.isInspectable = true
        context.inspectionName = currentExtension.name
        context.unsupportedAPIs = MozillaExtensionAPICatalog.unsupportedAPIPaths.union(["browser.windows.create"])

        var grantedPermissions = currentExtension.grantedPermissions
        grantedPermissions.insert(WebExtensionPackagePreparer.internalBridgePermission)
        context.grantedPermissions = Dictionary(
            uniqueKeysWithValues: grantedPermissions.map {
                (WKWebExtension.Permission(rawValue: $0), Date.distantFuture)
            }
        )

        var patterns: [WKWebExtension.MatchPattern: Date] = [:]
        for rawPattern in currentExtension.grantedMatchPatterns {
            if let pattern = try? WKWebExtension.MatchPattern(string: rawPattern) {
                patterns[pattern] = .distantFuture
            }
        }
        context.grantedPermissionMatchPatterns = patterns

        try controller.load(context)
        contexts[currentExtension.id] = context
        loadErrors[currentExtension.id] = nil
    }

    private func ensureCurrentCompatibility(for installedExtension: InstalledWebExtension) throws -> InstalledWebExtension {
        guard installedExtension.compatibilityRevision < WebExtensionPackagePreparer.currentCompatibilityRevision else {
            return installedExtension
        }

        guard let index = installedExtensions.firstIndex(where: { $0.id == installedExtension.id }) else {
            throw ExtensionError.extensionNotFound
        }
        let resourceURL = extensionsDirectory.appendingPathComponent(installedExtension.resourceRelativePath)
        let originalPermissions = installedExtension.originalPermissions.isEmpty
            ? try WebExtensionPackagePreparer.inferOriginalPermissions(at: resourceURL)
            : installedExtension.originalPermissions
        let refreshed = try WebExtensionPackagePreparer.refreshPreparedResource(
            at: resourceURL,
            originalPermissions: originalPermissions
        )

        installedExtensions[index].originalPermissions = refreshed.originalPermissions
        installedExtensions[index].compatibilityRevision = refreshed.compatibilityRevision
        extensionObjects[installedExtension.id] = nil
        persistRegistry()
        return installedExtensions[index]
    }

    private func runtimeIdentifier(for webExtension: WKWebExtension, fallback: UUID) -> String {
        if let browserSettings = webExtension.manifest["browser_specific_settings"] as? [String: Any],
           let gecko = browserSettings["gecko"] as? [String: Any],
           let identifier = gecko["id"] as? String,
           !identifier.isEmpty
        {
            return identifier
        }
        if let applications = webExtension.manifest["applications"] as? [String: Any],
           let gecko = applications["gecko"] as? [String: Any],
           let identifier = gecko["id"] as? String,
           !identifier.isEmpty
        {
            return identifier
        }
        return fallback.uuidString.lowercased()
    }

    private func requestInitialAccess(
        permissions: Set<String>,
        matchPatterns: Set<String>,
        name: String
    ) -> Bool {
        let permissionNames = permissions.sorted()
        let hosts = matchPatterns.sorted()
        guard !permissionNames.isEmpty || !hosts.isEmpty else { return true }

        let details = [
            permissionNames.isEmpty ? nil : "Permissions: " + permissionNames.joined(separator: ", "),
            hosts.isEmpty ? nil : "Sites: " + hosts.joined(separator: ", ")
        ].compactMap { $0 }.joined(separator: "\n\n")

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Allow \(name) Extension Access?"
        alert.informativeText = details
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Install Without Access")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func requestPermissionApproval(title: String, details: [String]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = details.sorted().joined(separator: "\n")
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func recordIndex(for context: WKWebExtensionContext) -> Int? {
        guard let id = contexts.first(where: { $0.value === context })?.key else { return nil }
        return installedExtensions.firstIndex(where: { $0.id == id })
    }

    private func copyLocalResource(_ sourceURL: URL, into installDirectory: URL) throws -> URL {
        let values = try sourceURL.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            let destination = installDirectory.appendingPathComponent("resource", isDirectory: true)
            try fileManager.copyItem(at: sourceURL, to: destination)
            return destination
        }

        let fileExtension = sourceURL.pathExtension.lowercased()
        guard fileExtension == "zip" || fileExtension == "xpi" else {
            throw ExtensionError.unsupportedLocalResource
        }
        let destination = installDirectory.appendingPathComponent("extension.\(fileExtension)")
        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
    }

    private func makeInstallDirectory(for installID: UUID) throws -> URL {
        let directory = extensionsDirectory.appendingPathComponent(installID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private var extensionsDirectory: URL {
        let applicationSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        let directory = applicationSupport
            .appendingPathComponent("Ora", isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func restoreRegistry() {
        guard let data = UserDefaults.standard.data(forKey: registryDefaultsKey),
              let decoded = try? JSONDecoder().decode([InstalledWebExtension].self, from: data)
        else {
            return
        }
        installedExtensions = decoded
    }

    private func persistRegistry() {
        guard let data = try? JSONEncoder().encode(installedExtensions) else { return }
        UserDefaults.standard.set(data, forKey: registryDefaultsKey)
    }
}

extension ExtensionManager: WKWebExtensionControllerDelegate {
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        let visibleWindows = windowWrappers.values.filter {
            !$0.isPrivateWindow || extensionContext.hasAccessToPrivateData
        }
        guard let focused = focusedWindow(for: extensionContext) else {
            return Array(visibleWindows)
        }
        return [focused] + visibleWindows.filter { $0 !== focused }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        focusedWindow(for: extensionContext)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        guard let window = (configuration.window as? OraWebExtensionWindow) ?? focusedWindow(for: extensionContext),
              let tabManager = window.tabManager
        else {
            completionHandler(nil, ExtensionError.windowUnavailable)
            return
        }

        let historyManager = HistoryManager(
            modelContainer: tabManager.modelContainer,
            modelContext: tabManager.modelContext
        )
        let downloadManager = DownloadManager(
            modelContainer: tabManager.modelContainer,
            modelContext: tabManager.modelContext
        )
        let url = configuration.url ?? URL(string: "about:blank")!
        let tab: Tab?
        if url.host != nil {
            tab = tabManager.openTab(
                url: url,
                historyManager: historyManager,
                downloadManager: downloadManager,
                focusAfterOpening: configuration.shouldBeActive,
                isPrivate: window.isPrivateWindow,
                loadSilently: true
            )
        } else {
            let container = tabManager.activeContainer ?? tabManager.createContainer()
            tab = tabManager.addTab(
                url: url,
                container: container,
                historyManager: historyManager,
                downloadManager: downloadManager,
                isPrivate: window.isPrivateWindow
            )
        }

        guard let tab else {
            completionHandler(nil, ExtensionError.windowUnavailable)
            return
        }
        if configuration.shouldBePinned, tab.type != .pinned {
            tabManager.togglePinTab(tab)
        }
        didCreateTab(tab)
        completionHandler(ensureTabWrapper(for: tab), nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let url = extensionContext.optionsPageURL,
              let window = focusedWindow(for: extensionContext),
              let tabManager = window.tabManager
        else {
            completionHandler(ExtensionError.windowUnavailable)
            return
        }
        let historyManager = HistoryManager(
            modelContainer: tabManager.modelContainer,
            modelContext: tabManager.modelContext
        )
        _ = tabManager.openTab(
            url: url,
            historyManager: historyManager,
            focusAfterOpening: true,
            isPrivate: window.isPrivateWindow,
            loadSilently: true
        )
        completionHandler(nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let popover = action.popupPopover,
              let view = NSApp.keyWindow?.contentView
        else {
            completionHandler(ExtensionError.windowUnavailable)
            return
        }
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        completionHandler(nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        let internalPermission = WKWebExtension.Permission(
            rawValue: WebExtensionPackagePreparer.internalBridgePermission
        )
        let userFacingPermissions = permissions.filter { permission in
            permission != internalPermission || originalPermissions(for: extensionContext).contains(permission.rawValue)
        }
        let names = userFacingPermissions.map(\.rawValue)

        if names.isEmpty {
            completionHandler(permissions.contains(internalPermission) ? [internalPermission] : [], .distantFuture)
            return
        }

        guard requestPermissionApproval(title: "Allow Extension Permission?", details: names) else {
            let internalOnly: Set<WKWebExtension.Permission> = permissions.contains(internalPermission)
                ? [internalPermission]
                : []
            completionHandler(internalOnly, internalOnly.isEmpty ? nil : .distantFuture)
            return
        }
        if let index = recordIndex(for: extensionContext) {
            installedExtensions[index].grantedPermissions.formUnion(names)
            persistRegistry()
        }
        completionHandler(Set(userFacingPermissions).union([internalPermission]), .distantFuture)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        let patterns = matchPatterns.map(\.string)
        guard requestPermissionApproval(title: "Allow Extension Website Access?", details: patterns) else {
            completionHandler([], nil)
            return
        }
        if let index = recordIndex(for: extensionContext) {
            installedExtensions[index].grantedMatchPatterns.formUnion(patterns)
            persistRegistry()
        }
        completionHandler(matchPatterns, .distantFuture)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        let values = urls.map(\.absoluteString)
        guard requestPermissionApproval(title: "Allow Extension Website Access?", details: values) else {
            completionHandler([], nil)
            return
        }
        completionHandler(urls, .distantFuture)
    }

    private func focusedWindow(for extensionContext: WKWebExtensionContext) -> OraWebExtensionWindow? {
        let visible = windowWrappers.values.filter {
            !$0.isPrivateWindow || extensionContext.hasAccessToPrivateData
        }
        if let keyWindow = NSApp.keyWindow,
           let match = visible.first(where: { $0.window === keyWindow })
        {
            return match
        }
        return visible.first
    }
}
