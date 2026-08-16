import Foundation
@preconcurrency import WebKit

@MainActor
final class OraWebExtensionTab: NSObject, WKWebExtensionTab {
    weak var tab: Tab?

    init(tab: Tab) {
        self.tab = tab
        super.init()
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

    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool {
        tab?.isPlayingMedia ?? false
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        tab?.url
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !(tab?.isLoading ?? false)
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
