import Foundation
@preconcurrency import WebKit

extension ExtensionManager {
    func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for extensionContext: WKWebExtensionContext,
        replyHandler: @escaping (Any?, (any Error)?) -> Void
    ) {
        guard applicationIdentifier == MozillaNativeAPIBridge.applicationIdentifier else {
            replyHandler(
                nil,
                NSError(
                    domain: "Ora.WebExtension.NativeMessaging",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Ora does not expose arbitrary native messaging hosts from its sandbox."
                    ]
                )
            )
            return
        }

        Task { @MainActor in
            do {
                let value = try await MozillaNativeAPIRouter.handle(
                    message,
                    for: extensionContext,
                    manager: self
                )
                replyHandler(["ok": true, "value": value], nil)
            } catch {
                replyHandler(
                    [
                        "ok": false,
                        "error": error.localizedDescription
                    ],
                    nil
                )
            }
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        do {
            try MozillaNativeAPIBridge.shared.connect(port: port, context: extensionContext)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}
