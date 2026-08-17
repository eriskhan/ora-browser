import AppKit
@preconcurrency import WebKit

@MainActor
final class WebExtensionAuthFlowCoordinator: NSObject, WKNavigationDelegate, NSWindowDelegate {
    static let shared = WebExtensionAuthFlowCoordinator()

    private struct Session {
        let window: NSWindow
        let continuation: CheckedContinuation<String, Error>
        let redirectPrefix: String
    }

    private var sessions: [ObjectIdentifier: Session] = [:]

    private override init() {
        super.init()
    }

    func start(
        url: URL,
        redirectPrefix: String,
        context: WKWebExtensionContext
    ) async throws -> String {
        guard let configuration = context.webViewConfiguration else {
            throw NSError(
                domain: "Ora.WebExtension.Identity",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "WebKit did not provide an extension web-view configuration."]
            )
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign In"
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.delegate = self
        window.center()

        return try await withCheckedThrowingContinuation { continuation in
            sessions[ObjectIdentifier(webView)] = Session(
                window: window,
                continuation: continuation,
                redirectPrefix: redirectPrefix
            )
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            webView.load(URLRequest(url: url))
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let identifier = ObjectIdentifier(webView)
        guard let session = sessions[identifier],
              let url = navigationAction.request.url,
              url.absoluteString.hasPrefix(session.redirectPrefix)
        else {
            decisionHandler(.allow)
            return
        }

        decisionHandler(.cancel)
        finish(webView: webView, result: Swift.Result.success(url.absoluteString))
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let match = sessions.first(where: { $0.value.window === window })
        else { return }
        sessions[match.key] = nil
        match.value.continuation.resume(throwing: NSError(
            domain: "Ora.WebExtension.Identity",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "The authentication flow was cancelled."]
        ))
    }

    private func finish(webView: WKWebView, result: Swift.Result<String, Error>) {
        let identifier = ObjectIdentifier(webView)
        guard let session = sessions.removeValue(forKey: identifier) else { return }
        session.window.delegate = nil
        session.window.close()
        session.continuation.resume(with: result)
    }
}
