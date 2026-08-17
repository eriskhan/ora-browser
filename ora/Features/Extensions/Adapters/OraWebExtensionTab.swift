import AppKit
import Foundation
@preconcurrency import WebKit

@MainActor
final class OraWebExtensionTab: NSObject, WKWebExtensionTab {
    weak var tab: Tab?
    weak var parentAdapter: OraWebExtensionTab?
    private var muted = false

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

    func parentTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        parentAdapter
    }

    func setParentTab(
        _ parentTab: (any WKWebExtensionTab)?,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        if let parentTab, !(parentTab is OraWebExtensionTab) {
            completionHandler(extensionError("The parent tab belongs to a different browser host."))
            return
        }
        parentAdapter = parentTab as? OraWebExtensionTab
        completionHandler(nil)
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
            completionHandler(extensionError("The Ora tab is no longer available."))
            return
        }

        if pinned != (tab.type == .pinned) {
            tabManager.togglePinTab(tab)
            context.webExtensionController?.didChangeTabProperties(.pinned, for: self)
        }
        completionHandler(nil)
    }

    func isReaderModeAvailable(for context: WKWebExtensionContext) -> Bool {
        false
    }

    func isReaderModeActive(for context: WKWebExtensionContext) -> Bool {
        false
    }

    func setReaderModeActive(
        _ active: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        completionHandler(extensionError("Reader mode is not available in Ora yet."))
    }

    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool {
        tab?.isPlayingMedia ?? false
    }

    func isMuted(for context: WKWebExtensionContext) -> Bool {
        muted
    }

    func setMuted(
        _ muted: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let tab else {
            completionHandler(extensionError("The Ora tab is no longer available."))
            return
        }

        let script = """
        (() => {
          for (const element of document.querySelectorAll('audio, video')) {
            if (\(muted ? "true" : "false")) {
              if (!element.hasAttribute('data-ora-extension-muted')) {
                element.setAttribute('data-ora-extension-muted', element.muted ? '1' : '0');
              }
              element.muted = true;
            } else {
              const original = element.getAttribute('data-ora-extension-muted');
              if (original !== null) {
                element.muted = original === '1';
                element.removeAttribute('data-ora-extension-muted');
              }
            }
          }
        })();
        """
        tab.evaluateJavaScript(script) { [weak self] _, error in
            Task { @MainActor in
                guard let self else {
                    completionHandler(error)
                    return
                }
                if let error {
                    completionHandler(error)
                    return
                }
                self.muted = muted
                context.webExtensionController?.didChangeTabProperties(.muted, for: self)
                completionHandler(nil)
            }
        }
    }

    func size(for context: WKWebExtensionContext) -> CGSize {
        tab?.browserPage?.webExtensionWebView.bounds.size ?? .zero
    }

    func zoomFactor(for context: WKWebExtensionContext) -> Double {
        Double(tab?.browserPage?.webExtensionWebView.pageZoom ?? 1)
    }

    func setZoomFactor(
        _ zoomFactor: Double,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard zoomFactor.isFinite, zoomFactor > 0,
              let webView = tab?.browserPage?.webExtensionWebView
        else {
            completionHandler(extensionError("A positive finite zoom factor is required."))
            return
        }
        webView.pageZoom = CGFloat(zoomFactor)
        context.webExtensionController?.didChangeTabProperties(.zoomFactor, for: self)
        completionHandler(nil)
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        tab?.url
    }

    func pendingURL(for context: WKWebExtensionContext) -> URL? {
        guard tab?.isLoading == true else { return nil }
        return tab?.browserPage?.currentURL ?? tab?.url
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !(tab?.isLoading ?? false)
    }

    func detectWebpageLocale(
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Locale?, (any Error)?) -> Void
    ) {
        guard let page = tab?.browserPage else {
            completionHandler(nil, extensionError("The Ora tab is no longer available."))
            return
        }

        page.evaluateJavaScript("document.documentElement.lang || navigator.language || ''") { value, error in
            if let error {
                completionHandler(nil, error)
                return
            }
            guard let identifier = value as? String, !identifier.isEmpty else {
                completionHandler(nil, nil)
                return
            }
            completionHandler(Locale(identifier: identifier), nil)
        }
    }

    func takeSnapshot(
        using configuration: WKSnapshotConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (NSImage?, (any Error)?) -> Void
    ) {
        guard let webView = tab?.browserPage?.webExtensionWebView else {
            completionHandler(nil, extensionError("The Ora tab is no longer available."))
            return
        }
        webView.takeSnapshot(with: configuration, completionHandler: completionHandler)
    }

    func activate(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let tab, let tabManager = tab.tabManager else {
            completionHandler(extensionError("The Ora tab is no longer available."))
            return
        }
        tabManager.activateTab(tab)
        completionHandler(nil)
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        guard let tab else { return false }
        return tab.tabManager?.activeTab?.id == tab.id
    }

    func setSelected(
        _ selected: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let tab, let tabManager = tab.tabManager else {
            completionHandler(extensionError("The Ora tab is no longer available."))
            return
        }

        if selected {
            tabManager.activateTab(tab)
        }
        completionHandler(nil)
    }

    func loadURL(
        _ url: URL,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        if url.scheme == context.baseURL.scheme, url.host == context.baseURL.host {
            completionHandler(extensionError("Extension URLs require an extension-configured web view."))
            return
        }

        tab?.loadURL(url.absoluteString)
        completionHandler(nil)
    }

    func reload(
        fromOrigin: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let webView = tab?.browserPage?.webExtensionWebView else {
            completionHandler(extensionError("The Ora tab is no longer available."))
            return
        }
        if fromOrigin {
            webView.reloadFromOrigin()
        } else {
            webView.reload()
        }
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

    func duplicate(
        using configuration: WKWebExtension.TabConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        guard let tab, let tabManager = tab.tabManager else {
            completionHandler(nil, extensionError("The Ora tab is no longer available."))
            return
        }
        guard tabManager.activeContainer?.id == tab.container.id else {
            completionHandler(nil, extensionError("Activate the tab's Ora space before duplicating it."))
            return
        }

        let historyManager = HistoryManager(
            modelContainer: tabManager.modelContainer,
            modelContext: tabManager.modelContext
        )
        guard let duplicated = tabManager.openTab(
            url: configuration.url ?? tab.url,
            historyManager: historyManager,
            focusAfterOpening: configuration.shouldBeActive,
            isPrivate: tab.isPrivate,
            loadSilently: true
        ) else {
            completionHandler(nil, extensionError("Ora could not duplicate the tab."))
            return
        }

        if configuration.shouldBePinned, duplicated.type != .pinned {
            tabManager.togglePinTab(duplicated)
        }
        let adapter = OraWebExtensionTabCache.shared.adapter(for: duplicated)
        adapter.parentAdapter = parentAdapter
        context.webExtensionController?.didOpenTab(adapter)
        completionHandler(adapter, nil)
    }

    func close(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let tab, let tabManager = tab.tabManager else {
            completionHandler(extensionError("The Ora tab is no longer available."))
            return
        }

        context.webExtensionController?.didCloseTab(self, windowIsClosing: false)
        tabManager.closeTab(tab: tab)
        OraWebExtensionTabCache.shared.remove(tabID: tab.id)
        completionHandler(nil)
    }

    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        true
    }

    func shouldBypassPermissions(for context: WKWebExtensionContext) -> Bool {
        false
    }

    private func extensionError(_ message: String) -> NSError {
        NSError(
            domain: "Ora.WebExtension.Tab",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
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
