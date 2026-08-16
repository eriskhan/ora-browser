import Foundation
@preconcurrency import WebKit

extension WebExtensionPermissionPrompter {
    func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for extensionContext: WKWebExtensionContext,
        replyHandler: @escaping (Any?, (any Error)?) -> Void
    ) {
        OraChromeExtensionAPIHost.shared.handleNativeMessage(
            message,
            applicationIdentifier: applicationIdentifier,
            extensionContext: extensionContext,
            replyHandler: replyHandler
        )
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        OraChromeExtensionAPIHost.shared.connectNativePort(
            port,
            extensionContext: extensionContext,
            completionHandler: completionHandler
        )
    }
}
