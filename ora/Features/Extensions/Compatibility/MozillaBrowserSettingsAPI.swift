import Foundation
@preconcurrency import WebKit

@MainActor
enum MozillaBrowserSettingsAPI {
    private static let values: [String: Any] = [
        "verticalTabs": true,
        "newTabPosition": "atEnd"
    ]

    static func handle(
        method: String,
        arguments: [Any],
        context: WKWebExtensionContext,
        manager: ExtensionManager
    ) throws -> Any {
        try MozillaNativeAPIRouter.require(
            "browserSettings",
            context: context,
            manager: manager
        )
        guard let setting = arguments.first as? String,
              let value = values[setting]
        else {
            throw MozillaNativeAPIBridge.BridgeError.itemNotFound(
                "Ora does not expose that Firefox browser setting."
            )
        }

        switch method {
        case "get":
            return [
                "value": value,
                "levelOfControl": "not_controllable"
            ]
        case "set", "clear":
            return false
        default:
            throw MozillaNativeAPIBridge.BridgeError.unsupportedMethod(
                "browserSettings",
                method
            )
        }
    }
}
