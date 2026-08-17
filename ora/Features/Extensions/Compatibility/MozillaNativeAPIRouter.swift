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
        case "browserSettings":
            return try MozillaBrowserSettingsAPI.handle(
                method: method,
                arguments: arguments,
                context: extensionContext,
                manager: manager
            )
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
        case "cookies":
            return try await MozillaCookiesAPI.handle(
                method: method,
                arguments: arguments,
                context: extensionContext,
                manager: manager
            )
        case "dns":
            try require("dns", context: extensionContext, manager: manager)
            return try await MozillaDNSAPI.handle(method: method, arguments: arguments)
        case "downloads":
            return try await MozillaDownloadsAPI.handle(
                method: method,
                arguments: arguments,
                context: extensionContext,
                manager: manager
            )
        case "find":
            return try await MozillaFindAPI.handle(
                method: method,
                arguments: arguments,
                context: extensionContext,
                manager: manager
            )
        case "idle":
            return try MozillaIdleAPI.handle(
                method: method,
                arguments: arguments,
                context: extensionContext,
                manager: manager
            )
        case "management":
            return try await MozillaManagementAPI.handle(
                method: method,
                arguments: arguments,
                context: extensionContext,
                manager: manager
            )
        case "permissions":
            return try MozillaPermissionsAPI.handle(
                method: method,
                arguments: arguments,
                context: extensionContext,
                manager: manager
            )
        case "privacy":
            return try MozillaPrivacyAPI.handle(
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
