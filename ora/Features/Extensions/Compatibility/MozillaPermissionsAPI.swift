import AppKit
import Foundation
@preconcurrency import WebKit

@MainActor
enum MozillaPermissionsAPI {
    static func handle(
        method: String,
        arguments: [Any],
        context: WKWebExtensionContext,
        manager: ExtensionManager
    ) throws -> Any {
        guard let record = installedExtension(context: context, manager: manager) else {
            throw MozillaNativeAPIBridge.BridgeError.itemNotFound(
                "The calling extension is not installed."
            )
        }

        switch method {
        case "ensureRequired":
            let requested = permissionNames(arguments.first)
            let required = bridgePermissions(in: record.originalPermissions)
                .subtracting(bridgePermissions(in: record.optionalPermissions))
            let needed = requested.intersection(required)
                .subtracting(record.grantedPermissions)
            return grant(
                permissions: needed,
                context: context,
                manager: manager,
                title: "Allow \(record.name) Extension Access?"
            )
        case "getAll":
            return Array(
                bridgePermissions(in: record.grantedPermissions)
                    .intersection(bridgePermissions(in: record.originalPermissions))
            ).sorted()
        case "contains":
            let requested = permissionNames(arguments.first)
            return requested.isSubset(of: record.grantedPermissions)
        case "request":
            let requested = permissionNames(arguments.first)
            let optional = bridgePermissions(in: record.optionalPermissions)
            guard requested.isSubset(of: optional) else {
                throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                    "browser.permissions.request can only request optional Firefox bridge permissions."
                )
            }
            let needed = requested.subtracting(record.grantedPermissions)
            return grant(
                permissions: needed,
                context: context,
                manager: manager,
                title: "Allow Extension Permission?"
            )
        case "remove":
            let requested = permissionNames(arguments.first)
            let optional = bridgePermissions(in: record.optionalPermissions)
            guard requested.isSubset(of: optional) else {
                return false
            }
            for permission in requested {
                manager.setBridgePermission(permission, granted: false, for: context)
            }
            return requested.isDisjoint(with: manager.grantedOriginalPermissions(for: context))
        default:
            throw MozillaNativeAPIBridge.BridgeError.unsupportedMethod("permissions", method)
        }
    }

    private static func grant(
        permissions: Set<String>,
        context: WKWebExtensionContext,
        manager: ExtensionManager,
        title: String
    ) -> Bool {
        guard !permissions.isEmpty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = permissions.sorted().joined(separator: "\n")
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        for permission in permissions {
            manager.setBridgePermission(permission, granted: true, for: context)
        }
        return permissions.isSubset(of: manager.grantedOriginalPermissions(for: context))
    }

    private static func installedExtension(
        context: WKWebExtensionContext,
        manager: ExtensionManager
    ) -> InstalledWebExtension? {
        manager.installedExtensions.first { $0.runtimeIdentifier == context.uniqueIdentifier }
    }

    private static func permissionNames(_ value: Any?) -> Set<String> {
        if let values = value as? [String] {
            return Set(values)
        }
        if let values = value as? [Any] {
            return Set(values.compactMap { $0 as? String })
        }
        return []
    }

    private static func bridgePermissions(in permissions: Set<String>) -> Set<String> {
        Set(permissions.filter { permission in
            nativeBridgePermissions.contains(permission) && !isMatchPattern(permission)
        })
    }

    private static func isMatchPattern(_ value: String) -> Bool {
        (try? WKWebExtension.MatchPattern(string: value)) != nil
    }

    private static let nativeBridgePermissions: Set<String> = [
        "browserSettings",
        "browsingData",
        "contextualIdentities",
        "cookies",
        "dns",
        "downloads",
        "downloads.open",
        "find",
        "history",
        "idle",
        "management",
        "privacy",
        "search",
        "topSites"
    ]
}
