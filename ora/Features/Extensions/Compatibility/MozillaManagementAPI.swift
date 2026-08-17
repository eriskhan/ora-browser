import Combine
import Foundation
@preconcurrency import WebKit

@MainActor
enum MozillaManagementAPI {
    private static let readMethods: Set<String> = [
        "getSelf",
        "getAll",
        "get",
        "getPermissionWarningsById",
        "getPermissionWarningsByManifest"
    ]

    private static var observer: AnyCancellable?
    private static var previousExtensions: [UUID: InstalledWebExtension] = [:]

    static func handle(
        method: String,
        arguments: [Any],
        context: WKWebExtensionContext,
        manager: ExtensionManager
    ) async throws -> Any {
        startObserving(manager: manager)
        if readMethods.contains(method) {
            return try handleRead(
                method: method,
                arguments: arguments,
                context: context,
                manager: manager
            )
        }
        return try await handleMutation(
            method: method,
            arguments: arguments,
            context: context,
            manager: manager
        )
    }

    private static func handleRead(
        method: String,
        arguments: [Any],
        context: WKWebExtensionContext,
        manager: ExtensionManager
    ) throws -> Any {
        switch method {
        case "getSelf":
            return try getSelf(context: context, manager: manager)
        case "getAll":
            try requireManagement(context: context, manager: manager)
            return manager.installedExtensions.map(MozillaManagementSupport.extensionInfo)
        case "get":
            return try get(arguments: arguments, context: context, manager: manager)
        case "getPermissionWarningsById":
            return try warningsByID(arguments: arguments, context: context, manager: manager)
        case "getPermissionWarningsByManifest":
            return try warningsByManifest(arguments: arguments)
        default:
            throw MozillaNativeAPIBridge.BridgeError.unsupportedMethod("management", method)
        }
    }

    private static func handleMutation(
        method: String,
        arguments: [Any],
        context: WKWebExtensionContext,
        manager: ExtensionManager
    ) async throws -> Any {
        switch method {
        case "setEnabled":
            return try await setEnabled(arguments: arguments, context: context, manager: manager)
        case "uninstall":
            return try uninstall(arguments: arguments, context: context, manager: manager)
        case "uninstallSelf":
            return try uninstallSelf(arguments: arguments, context: context, manager: manager)
        case "install":
            return try await install(arguments: arguments, context: context, manager: manager)
        case "__subscribe":
            return NSNull()
        default:
            throw MozillaNativeAPIBridge.BridgeError.unsupportedMethod("management", method)
        }
    }

    private static func getSelf(
        context: WKWebExtensionContext,
        manager: ExtensionManager
    ) throws -> [String: Any] {
        guard let caller = callingExtension(context: context, manager: manager) else {
            throw MozillaNativeAPIBridge.BridgeError.itemNotFound(
                "The calling extension is not installed."
            )
        }
        return MozillaManagementSupport.extensionInfo(caller)
    }

    private static func get(
        arguments: [Any],
        context: WKWebExtensionContext,
        manager: ExtensionManager
    ) throws -> [String: Any] {
        try requireManagement(context: context, manager: manager)
        guard let identifier = arguments.first as? String,
              let extensionValue = installedExtension(identifier, manager: manager)
        else {
            throw MozillaNativeAPIBridge.BridgeError.itemNotFound(
                "The requested extension is not installed."
            )
        }
        return MozillaManagementSupport.extensionInfo(extensionValue)
    }

    private static func setEnabled(
        arguments: [Any],
        context: WKWebExtensionContext,
        manager: ExtensionManager
    ) async throws -> Any {
        try requireManagement(context: context, manager: manager)
        guard arguments.count >= 2,
              let identifier = arguments[0] as? String,
              let enabled = arguments[1] as? Bool,
              let extensionValue = installedExtension(identifier, manager: manager)
        else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "browser.management.setEnabled requires an installed extension ID and enabled state."
            )
        }

        let caller = callingExtension(context: context, manager: manager)
        if caller?.id == extensionValue.id, !enabled {
            deferRemovalAction {
                try? await manager.setEnabled(false, extensionID: extensionValue.id)
            }
        } else {
            try await manager.setEnabled(enabled, extensionID: extensionValue.id)
        }
        return NSNull()
    }

    private static func uninstall(
        arguments: [Any],
        context: WKWebExtensionContext,
        manager: ExtensionManager
    ) throws -> Any {
        try requireManagement(context: context, manager: manager)
        guard let identifier = arguments.first as? String,
              let extensionValue = installedExtension(identifier, manager: manager)
        else {
            throw MozillaNativeAPIBridge.BridgeError.itemNotFound(
                "The requested extension is not installed."
            )
        }

        let caller = callingExtension(context: context, manager: manager)
        let options = arguments.dropFirst().first as? [String: Any] ?? [:]
        let isSelf = caller?.id == extensionValue.id
        let shouldConfirm = !isSelf || (options["showConfirmDialog"] as? Bool ?? false)
        if shouldConfirm, !MozillaManagementSupport.confirmUninstall(extensionValue) {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "The user canceled extension removal."
            )
        }
        remove(extensionValue, deferred: isSelf, manager: manager)
        return NSNull()
    }

    private static func uninstallSelf(
        arguments: [Any],
        context: WKWebExtensionContext,
        manager: ExtensionManager
    ) throws -> Any {
        guard let caller = callingExtension(context: context, manager: manager) else {
            throw MozillaNativeAPIBridge.BridgeError.itemNotFound(
                "The calling extension is not installed."
            )
        }
        let options = arguments.first as? [String: Any] ?? [:]
        if options["showConfirmDialog"] as? Bool == true,
           !MozillaManagementSupport.confirmUninstall(caller)
        {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "The user canceled extension removal."
            )
        }
        remove(caller, deferred: true, manager: manager)
        return NSNull()
    }

    private static func warningsByID(
        arguments: [Any],
        context: WKWebExtensionContext,
        manager: ExtensionManager
    ) throws -> [String] {
        try requireManagement(context: context, manager: manager)
        guard let identifier = arguments.first as? String,
              let extensionValue = installedExtension(identifier, manager: manager)
        else {
            throw MozillaNativeAPIBridge.BridgeError.itemNotFound(
                "The requested extension is not installed."
            )
        }
        return MozillaManagementSupport.permissionWarnings(
            permissions: extensionValue.originalPermissions,
            hostPermissions: extensionValue.grantedMatchPatterns
        )
    }

    private static func warningsByManifest(arguments: [Any]) throws -> [String] {
        guard let manifestText = arguments.first as? String,
              let data = WebExtensionPackagePreparer
                .removingJSONComments(from: manifestText).data(using: .utf8),
              let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "A valid extension manifest is required."
            )
        }
        let permissions = Set(manifest["permissions"] as? [String] ?? [])
        let hostPermissions = Set(manifest["host_permissions"] as? [String] ?? [])
            .union(permissions.filter(MozillaManagementSupport.isHostPermission))
        return MozillaManagementSupport.permissionWarnings(
            permissions: permissions.filter { !MozillaManagementSupport.isHostPermission($0) },
            hostPermissions: hostPermissions
        )
    }

    private static func install(
        arguments: [Any],
        context: WKWebExtensionContext,
        manager: ExtensionManager
    ) async throws -> [String: String] {
        try requireManagement(context: context, manager: manager)
        guard let options = arguments.first as? [String: Any],
              let urlString = options["url"] as? String,
              let url = URL(string: urlString),
              url.scheme == "https",
              url.host?.lowercased() == "addons.mozilla.org"
        else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "Ora only accepts HTTPS theme installs initiated from addons.mozilla.org."
            )
        }
        let installed = try await MozillaManagementSupport.installTheme(
            from: url,
            expectedHash: options["hash"] as? String,
            manager: manager
        )
        return ["id": installed.runtimeIdentifier]
    }

    private static func requireManagement(
        context: WKWebExtensionContext,
        manager: ExtensionManager
    ) throws {
        try MozillaNativeAPIRouter.require("management", context: context, manager: manager)
    }

    private static func deferRemovalAction(
        _ action: @escaping @MainActor () async -> Void
    ) {
        Task { @MainActor in
            await Task.yield()
            await action()
        }
    }

    private static func remove(
        _ installed: InstalledWebExtension,
        deferred: Bool,
        manager: ExtensionManager
    ) {
        if deferred {
            deferRemovalAction {
                manager.removeExtension(installed.id)
            }
        } else {
            manager.removeExtension(installed.id)
        }
    }

    private static func startObserving(manager: ExtensionManager) {
        guard observer == nil else { return }
        previousExtensions = Dictionary(
            uniqueKeysWithValues: manager.installedExtensions.map { ($0.id, $0) }
        )
        observer = manager.$installedExtensions.dropFirst().sink { extensions in
            Task { @MainActor in
                emitChanges(extensions)
            }
        }
    }

    private static func emitChanges(_ extensions: [InstalledWebExtension]) {
        let current = Dictionary(uniqueKeysWithValues: extensions.map { ($0.id, $0) })
        emitInstalled(current: current)
        emitUninstalled(current: current)
        emitEnabledChanges(current: current)
        previousExtensions = current
    }

    private static func emitInstalled(current: [UUID: InstalledWebExtension]) {
        for (id, value) in current where previousExtensions[id] == nil {
            MozillaNativeAPIBridge.shared.emit(
                namespace: "management",
                event: "onInstalled",
                arguments: [MozillaManagementSupport.extensionInfo(value)]
            )
        }
    }

    private static func emitUninstalled(current: [UUID: InstalledWebExtension]) {
        for (id, oldValue) in previousExtensions where current[id] == nil {
            MozillaNativeAPIBridge.shared.emit(
                namespace: "management",
                event: "onUninstalled",
                arguments: [MozillaManagementSupport.extensionInfo(oldValue)]
            )
        }
    }

    private static func emitEnabledChanges(current: [UUID: InstalledWebExtension]) {
        for (id, value) in current {
            guard let oldValue = previousExtensions[id], oldValue.isEnabled != value.isEnabled else {
                continue
            }
            MozillaNativeAPIBridge.shared.emit(
                namespace: "management",
                event: value.isEnabled ? "onEnabled" : "onDisabled",
                arguments: [MozillaManagementSupport.extensionInfo(value)]
            )
        }
    }

    private static func callingExtension(
        context: WKWebExtensionContext,
        manager: ExtensionManager
    ) -> InstalledWebExtension? {
        manager.installedExtensions.first { $0.runtimeIdentifier == context.uniqueIdentifier }
    }

    private static func installedExtension(
        _ identifier: String,
        manager: ExtensionManager
    ) -> InstalledWebExtension? {
        manager.installedExtensions.first {
            $0.runtimeIdentifier == identifier ||
                $0.id.uuidString.caseInsensitiveCompare(identifier) == .orderedSame
        }
    }
}
