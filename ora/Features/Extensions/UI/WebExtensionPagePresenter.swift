import AppKit
@preconcurrency import WebKit

@MainActor
final class WebExtensionPagePresenter: NSObject, NSWindowDelegate {
    static let shared = WebExtensionPagePresenter()

    private var retainedWindows: [ObjectIdentifier: NSWindow] = [:]

    private override init() {
        super.init()
    }

    func present(
        url: URL,
        context: WKWebExtensionContext,
        title: String,
        size: CGSize = CGSize(width: 760, height: 620)
    ) throws {
        guard let configuration = context.webViewConfiguration else {
            throw NSError(
                domain: "Ora.WebExtension.PagePresenter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "WebKit did not provide an extension web-view configuration."]
            )
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = context.isInspectable
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        retainedWindows[ObjectIdentifier(window)] = window
        webView.load(URLRequest(url: url))
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        retainedWindows[ObjectIdentifier(window)] = nil
    }
}
