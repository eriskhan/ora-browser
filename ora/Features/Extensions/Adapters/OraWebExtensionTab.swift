import Foundation
@preconcurrency import WebKit

@MainActor
final class OraWebExtensionTab: NSObject, WKWebExtensionTab {
    weak var tab: Tab?
    weak var owner: ExtensionManager?

    init(tab: Tab, owner: ExtensionManager) {
        self.tab = tab
        self.owner = owner
        super.init()
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard let tab else { return nil }
        return owner?.window(for: tab)
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        owner?.index(of: self) ?? NSNotFound
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
        guard let tab, let owner else {
            completionHandler(extensionError("The Ora tab no longer exists."))
            return
        }
        owner.setPinned(pinned, for: tab)
        completionHandler(nil)
    }

    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool {
        tab?.isPlayingMedia ?? false
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
        tab?.browserPage?.currentURL ?? tab?.url
    }

    func pendingURL(for context: WKWebExtensionContext) -> URL? {
        guard tab?.isLoading == true else { return nil }
        return tab?.url
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !(tab?.isLoading ?? false)
    }

    func loadURL(
        _ url: URL,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let tab else {
            completionHandler(extensionError("The Ora tab no longer exists."))
            return
        }
        tab.loadURL(url.absoluteString)
        completionHandler(nil)
    }

    func reload(
        fromOrigin: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let tab else {
            completionHandler(extensionError("The Ora tab no longer exists."))
            return
        }
        tab.reload()
        completionHandler(nil)
    }

    func goBack(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let tab else {
            completionHandler(extensionError("The Ora tab no longer exists."))
            return
        }
        tab.goBack()
        completionHandler(nil)
    }

    func goForward(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let tab else {
            completionHandler(extensionError("The Ora tab no longer exists."))
            return
        }
        tab.goForward()
        completionHandler(nil)
    }

    func activate(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let tab, let owner else {
            completionHandler(extensionError("The Ora tab no longer exists."))
            return
        }
        owner.activate(tab)
        completionHandler(nil)
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        guard let tab else { return false }
        return tab.tabManager?.activeTab?.id == tab.id
    }

    func close(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let tab, let owner else {
            completionHandler(extensionError("The Ora tab no longer exists."))
            return
        }
        owner.close(tab)
        completionHandler(nil)
    }

    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        true
    }

    private func extensionError(_ message: String) -> NSError {
        NSError(
            domain: "Ora.WebExtension.Tab",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
