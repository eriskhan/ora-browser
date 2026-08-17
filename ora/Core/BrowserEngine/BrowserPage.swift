import AppKit
import Foundation
@preconcurrency import WebKit

final class BrowserPage: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    weak var delegate: BrowserPageDelegate?

    private let webView: WKWebView
    private let messageNames: [String]
    private var originalURL: URL?
    private(set) var lastCommittedURL: URL?
    private(set) var isDownloadNavigation = false
    private(set) var sslBypassedHosts: Set<String> = []
    private var isReadyForNavigation = false
    private var pendingLoadRequest: URLRequest?
    private var pendingReload = false

    var websiteDataStore: WKWebsiteDataStore {
        webView.configuration.websiteDataStore
    }

    init(
        profile: BrowserEngineProfile,
        configuration: BrowserPageConfiguration,
        delegate: BrowserPageDelegate?
    ) {
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.applicationNameForUserAgent = configuration.userAgent
        webConfiguration.websiteDataStore = profile.dataStore
        webConfiguration.webExtensionController = ExtensionManager.shared.controller
        webConfiguration.allowsAirPlayForMediaPlayback = configuration.allowsAirPlayForMediaPlayback
        webConfiguration.preferences.setValue(
            configuration.allowsInspectableDebugging,
            forKey: "developerExtrasEnabled"
        )
        webConfiguration.preferences.setValue(
            configuration.allowsPictureInPicture,
            forKey: "allowsPictureInPictureMediaPlayback"
        )
        webConfiguration.preferences.setValue(configuration.allowsJavaScript, forKey: "javaScriptEnabled")
        webConfiguration.preferences.setValue(
            configuration.allowsJavaScriptWindowsAutomatically,
            forKey: "javaScriptCanOpenWindowsAutomatically"
        )
        webConfiguration.preferences.javaScriptCanOpenWindowsAutomatically =
            configuration.allowsJavaScriptWindowsAutomatically
        webConfiguration.preferences.isElementFullscreenEnabled = true
        webConfiguration.mediaTypesRequiringUserActionForPlayback =
            configuration.mediaPlaybackRequiresUserAction ? .all : []

        let webpagePreferences = WKWebpagePreferences()
        webpagePreferences.allowsContentJavaScript = configuration.allowsJavaScript
        webConfiguration.defaultWebpagePreferences = webpagePreferences

        let contentController = WKUserContentController()
        webConfiguration.userContentController = contentController
        messageNames = configuration.scriptMessageNames
        webView = WKWebView(frame: .zero, configuration: webConfiguration)
        self.delegate = delegate

        super.init()

        for messageName in configuration.scriptMessageNames {
            contentController.add(self, name: messageName)
        }
        for script in configuration.userScripts {
            let userScript = WKUserScript(
                source: script.source,
                injectionTime: mapInjectionTime(script.injectionTime),
                forMainFrameOnly: script.forMainFrameOnly
            )
            contentController.addUserScript(userScript)
        }

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true
        webView.allowsBackForwardNavigationGestures = configuration.allowsBackForwardNavigationGestures
        webView.wantsLayer = true
        webView.isInspectable = configuration.allowsInspectableDebugging
        if let layer = webView.layer {
            layer.isOpaque = true
            layer.drawsAsynchronously = true
        }

        configureObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func configureObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    @objc private func applicationDidBecomeActive() {
        webView.setValue(false, forKey: "drawsBackground")
    }

    @objc private func applicationDidResignActive() {
        webView.setValue(false, forKey: "drawsBackground")
    }

    func load(_ request: URLRequest) {
        originalURL = request.url
        guard isReadyForNavigation else {
            pendingLoadRequest = request
            return
        }
        webView.load(request)
    }

    func reload() {
        guard isReadyForNavigation else {
            pendingReload = true
            return
        }
        webView.reload()
    }

    func reloadFromOrigin() {
        guard isReadyForNavigation else {
            pendingReload = true
            return
        }
        webView.reloadFromOrigin()
    }

    func stopLoading() {
        webView.stopLoading()
    }

    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }

    var canGoBack: Bool {
        webView.canGoBack
    }

    var canGoForward: Bool {
        webView.canGoForward
    }

    var isLoading: Bool {
        webView.isLoading
    }

    var estimatedProgress: Double {
        webView.estimatedProgress
    }

    var url: URL? {
        webView.url
    }

    var title: String? {
        webView.title
    }

    func evaluateJavaScript(
        _ javaScriptString: String,
        completionHandler: ((Any?, Error?) -> Void)? = nil
    ) {
        webView.evaluateJavaScript(javaScriptString, completionHandler: completionHandler)
    }

    func takeSnapshot(
        with configuration: WKSnapshotConfiguration? = nil,
        completionHandler: @escaping (NSImage?, Error?) -> Void
    ) {
        webView.takeSnapshot(with: configuration, completionHandler: completionHandler)
    }

    func setFrame(_ frame: CGRect) {
        webView.frame = frame
    }

    var frame: CGRect {
        webView.frame
    }

    var view: NSView {
        webView
    }

    func teardown() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        for messageName in messageNames {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: messageName)
        }
    }

    func closeMediaPresentations(completion: @escaping () -> Void) {
        webView.closeAllMediaPresentations {
            completion()
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        sslBypassedHosts.removeAll()
        delegate?.browserPageDidStartNavigation(self)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        lastCommittedURL = webView.url
        delegate?.browserPageDidCommitNavigation(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        delegate?.browserPageDidFinishNavigation(self)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: Error
    ) {
        delegate?.browserPage(self, didFailNavigationWith: error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        delegate?.browserPage(self, didFailNavigationWith: error)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let requestURL = navigationAction.request.url
        if navigationAction.shouldPerformDownload {
            isDownloadNavigation = true
            decisionHandler(.download)
            return
        }
        isDownloadNavigation = false
        if let requestURL,
           let originalURL,
           requestURL.host != originalURL.host,
           navigationAction.navigationType == .linkActivated
        {
            self.originalURL = requestURL
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        let url = navigationAction.request.url ?? originalURL ?? URL(string: "about:blank")!
        delegate?.browserPage(self, didStartDownload: BrowserDownloadTask(download: download, originalURL: url))
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.canShowMIMEType {
            decisionHandler(.allow)
        } else {
            isDownloadNavigation = true
            decisionHandler(.download)
        }
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        let url = navigationResponse.response.url ?? originalURL ?? URL(string: "about:blank")!
        delegate?.browserPage(self, didStartDownload: BrowserDownloadTask(download: download, originalURL: url))
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        delegate?.browserPage(self, requestsNewTabFor: url)
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        delegate?.browserPage(self, runJavaScriptAlert: message, completion: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        delegate?.browserPage(self, runJavaScriptConfirm: message, completion: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        delegate?.browserPage(self, runJavaScriptPrompt: prompt, defaultText: defaultText, completion: completionHandler)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.browserPage(self, didReceiveScriptMessage: message)
    }

    private func mapInjectionTime(_ time: BrowserUserScript.InjectionTime) -> WKUserScriptInjectionTime {
        switch time {
        case .documentStart:
            return .atDocumentStart
        case .documentEnd:
            return .atDocumentEnd
        }
    }
}
