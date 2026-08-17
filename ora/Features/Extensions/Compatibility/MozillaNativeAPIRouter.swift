import Foundation
@preconcurrency import WebKit

@MainActor
enum MozillaNativeAPIRouter {
    static func handle(
        _ message: Any,
        for extensionContext: WKWebExtensionContext,
        manager: ExtensionManager
    ) async throws -> Any {
        guard let payload = message as? [String: Any],
              payload["ora"] as? String == "mozilla-api",
              let namespace = payload["namespace"] as? String,
              let method = payload["method"] as? String
        else {
            throw MozillaNativeAPIBridge.BridgeError.invalidMessage
        }

        let arguments = payload["args"] as? [Any] ?? []
        switch namespace {
        case "browsingData":
            try require("browsingData", context: extensionContext, manager: manager)
            return try await MozillaBrowsingDataAPI.handle(
                method: method,
                arguments: arguments,
                context: extensionContext
            )
        case "contextualIdentities":
            return try await MozillaContextualIdentitiesAPI.handle(
                method: method,
                arguments: arguments,
                context: extensionContext,
                manager: manager
            )
        default:
            return try await MozillaNativeAPIBridge.shared.handleMessage(
                message,
                for: extensionContext,
                manager: manager
            )
        }
    }

    static func require(
        _ permission: String,
        context: WKWebExtensionContext,
        manager: ExtensionManager
    ) throws {
        guard manager.hasBridgeAccess(to: permission, for: context) else {
            throw MozillaNativeAPIBridge.BridgeError.permissionDenied(permission)
        }
    }
}
