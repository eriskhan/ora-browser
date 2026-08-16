import Foundation
@preconcurrency import WebKit

@MainActor
final class OraWebExtensionTab: NSObject, WKWebExtensionTab {
    weak var tab: Tab?

    init(tab: Tab) {
        self.tab = tab
        super.init()
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard let tab, let tabManager = tab.tabManager else { return nil }
        return WebExtensionPermissionPrompter.shared.windowAdapter(
            for: tabManager,
            spaceID: tab.container.id
        )
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let tab else { return NSNotFound }
        let orderedTabs = tab.container.tabs.sorted { $0.order < $1.order }
        return orderedTabs.firstIndex(where: { $0.id == tab.id }) ?? NSNotFound
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        tab?.browserPage?.webExtensionWebView
    }

    func title(for context: WKWebExtensionContext) -> String? {
        tab?.title
    }

    func isPinned(for context: WKWebExtensionContext) -> Bool {
        tab?.type == .pinned
    }

    func setPinned(
        _ pinned: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let tab, let tabManager = tab.tabManager else {
            completionHandler(nil)
            return
        }

        if pinned != (tab.type == .pinned) {
            tabManager.togglePinTab(tab)
        }
        completionHandler(nil)
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        guard let tab else { return false }
        return tab.tabManager?.activeTab?.id == tab.id
    }

    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool {
        tab?.isPlayingMedia ?? false
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        tab?.url
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !(tab?.isLoading ?? false)
    }

    func activate(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let tab, let tabManager = tab.tabManager else {
            completionHandler(nil)
            return
        }
        tabManager.activateTab(tab)
        completionHandler(nil)
    }

    func loadURL(
        _ url: URL,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        if url.scheme == context.baseURL.scheme, url.host == context.baseURL.host {
            completionHandler(NSError(
                domain: "Ora.WebExtension",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey: "Extension pages in normal Ora tabs are not supported yet."
                ]
            ))
            return
        }

        tab?.loadURL(url.absoluteString)
        completionHandler(nil)
    }

    func goBack(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        tab?.goBack()
        completionHandler(nil)
    }

    func goForward(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        tab?.goForward()
        completionHandler(nil)
    }

    func reload(
        fromOrigin: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        tab?.reload()
        completionHandler(nil)
    }

    func close(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let tab, let tabManager = tab.tabManager else {
            completionHandler(nil)
            return
        }

        context.webExtensionController?.didCloseTab(self, windowIsClosing: false)
        tabManager.closeTab(tab: tab)
        OraWebExtensionTabCache.shared.remove(tabID: tab.id)
        completionHandler(nil)
    }
}

@MainActor
final class OraWebExtensionTabCache {
    static let shared = OraWebExtensionTabCache()

    private var adapters: [UUID: OraWebExtensionTab] = [:]

    func adapter(for tab: Tab) -> OraWebExtensionTab {
        if let existing = adapters[tab.id], existing.tab != nil {
            return existing
        }

        let adapter = OraWebExtensionTab(tab: tab)
        adapters[tab.id] = adapter
        return adapter
    }

    func remove(tabID: UUID) {
        adapters[tabID] = nil
    }
}
