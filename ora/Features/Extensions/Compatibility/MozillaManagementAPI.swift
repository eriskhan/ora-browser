import AppKit
import Combine
import CryptoKit
import Foundation
import ZIPFoundation
@preconcurrency import WebKit

@MainActor
enum MozillaManagementAPI {
    private static var observer: AnyCancellable?
    private static var previousExtensions: [UUID: InstalledWebExtension] = [:]

    static func handle(
        method: String,
        arguments: [Any],
        context: WKWebExtensionContext,
        manager: ExtensionManager
    ) async throws -> Any {
        startObserving(manager: manager)
        let caller = callingExtension(context: context, manager: manager)

        switch method {
        case "getSelf":
            guard let caller else {
                throw MozillaNativeAPIBridge.BridgeError.itemNotFound("The calling extension is not installed.")
            }
            return extensionInfo(caller)

        case "getAll":
            try requireManagement(context: context, manager: manager)
            return manager.installedExtensions.map(extensionInfo)

        case "get":
            try requireManagement(context: context, manager: manager)
            guard let identifier = arguments.first as? String,
                  let extensionValue = installedExtension(identifier, manager: manager)
            else {
                throw MozillaNativeAPIBridge.BridgeError.itemNotFound("The requested extension is not installed.")
            }
            return extensionInfo(extensionValue)

        case "setEnabled":
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
            if caller?.id == extensionValue.id, !enabled {
                Task { @MainActor in
                    await Task.yield()
                    try? await manager.setEnabled(false, extensionID: extensionValue.id)
                }
            } else {
                try await manager.setEnabled(enabled, extensionID: extensionValue.id)
            }
            return NSNull()

        case "uninstall":
            try requireManagement(context: context, manager: manager)
            guard let identifier = arguments.first as? String,
                  let extensionValue = installedExtension(identifier, manager: manager)
            else {
                throw MozillaNativeAPIBridge.BridgeError.itemNotFound("The requested extension is not installed.")
            }
            let options = arguments.dropFirst().first as? [String: Any] ?? [:]
            let isSelf = caller?.id == extensionValue.id
            let showConfirmation = !isSelf || (options["showConfirmDialog"] as? Bool ?? false)
            if showConfirmation, !confirmUninstall(extensionValue) {
                throw MozillaNativeAPIBridge.BridgeError.invalidArguments("The user canceled extension removal.")
            }
            if isSelf {
                Task { @MainActor in
                    await Task.yield()
                    manager.removeExtension(extensionValue.id)
                }
            } else {
                manager.removeExtension(extensionValue.id)
            }
            return NSNull()

        case "uninstallSelf":
            guard let caller else {
                throw MozillaNativeAPIBridge.BridgeError.itemNotFound("The calling extension is not installed.")
            }
            let options = arguments.first as? [String: Any] ?? [:]
            if options["showConfirmDialog"] as? Bool == true, !confirmUninstall(caller) {
                throw MozillaNativeAPIBridge.BridgeError.invalidArguments("The user canceled extension removal.")
            }
            Task { @MainActor in
                await Task.yield()
                manager.removeExtension(caller.id)
            }
            return NSNull()

        case "getPermissionWarningsById":
            try requireManagement(context: context, manager: manager)
            guard let identifier = arguments.first as? String,
                  let extensionValue = installedExtension(identifier, manager: manager)
            else {
                throw MozillaNativeAPIBridge.BridgeError.itemNotFound("The requested extension is not installed.")
            }
            return permissionWarnings(
                permissions: extensionValue.originalPermissions,
                hostPermissions: extensionValue.grantedMatchPatterns
            )

        case "getPermissionWarningsByManifest":
            guard let manifestText = arguments.first as? String,
                  let data = WebExtensionPackagePreparer.removingJSONComments(from: manifestText).data(using: .utf8),
                  let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw MozillaNativeAPIBridge.BridgeError.invalidArguments("A valid extension manifest is required.")
            }
            let permissions = Set(manifest["permissions"] as? [String] ?? [])
            let hostPermissions = Set(manifest["host_permissions"] as? [String] ?? [])
                .union(permissions.filter(isHostPermission))
            return permissionWarnings(
                permissions: permissions.filter { !isHostPermission($0) },
                hostPermissions: hostPermissions
            )

        case "install":
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
            let installed = try await installTheme(
                from: url,
                expectedHash: options["hash"] as? String,
                manager: manager
            )
            return ["id": installed.runtimeIdentifier]

        case "__subscribe":
            return NSNull()

        default:
            throw MozillaNativeAPIBridge.BridgeError.unsupportedMethod("management", method)
        }
    }

    private static func requireManagement(
        context: WKWebExtensionContext,
        manager: ExtensionManager
    ) throws {
        try MozillaNativeAPIRouter.require("management", context: context, manager: manager)
    }

    private static func startObserving(manager: ExtensionManager) {
        guard observer == nil else { return }
        previousExtensions = Dictionary(uniqueKeysWithValues: manager.installedExtensions.map { ($0.id, $0) })
        observer = manager.$installedExtensions.dropFirst().sink { extensions in
            Task { @MainActor in
                let current = Dictionary(uniqueKeysWithValues: extensions.map { ($0.id, $0) })

                for (id, value) in current where previousExtensions[id] == nil {
                    MozillaNativeAPIBridge.shared.emit(
                        namespace: "management",
                        event: "onInstalled",
                        arguments: [extensionInfo(value)]
                    )
                }
                for (id, oldValue) in previousExtensions where current[id] == nil {
                    MozillaNativeAPIBridge.shared.emit(
                        namespace: "management",
                        event: "onUninstalled",
                        arguments: [extensionInfo(oldValue)]
                    )
                }
                for (id, value) in current {
                    guard let oldValue = previousExtensions[id], oldValue.isEnabled != value.isEnabled else { continue }
                    MozillaNativeAPIBridge.shared.emit(
                        namespace: "management",
                        event: value.isEnabled ? "onEnabled" : "onDisabled",
                        arguments: [extensionInfo(value)]
                    )
                }
                previousExtensions = current
            }
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
            $0.runtimeIdentifier == identifier || $0.id.uuidString.caseInsensitiveCompare(identifier) == .orderedSame
        }
    }

    private static func extensionInfo(_ installed: InstalledWebExtension) -> [String: Any] {
        let manifest = manifest(for: installed)
        let apiPermissions = installed.declaredPermissions.filter { !isHostPermission($0) }.sorted()
        var hostPermissions = installed.declaredPermissions.filter(isHostPermission)
        hostPermissions.formUnion(installed.grantedMatchPatterns)

        var value: [String: Any] = [
            "id": installed.runtimeIdentifier,
            "name": installed.name,
            "description": manifest["description"] as? String ?? "",
            "version": installed.version,
            "enabled": installed.isEnabled,
            "mayDisable": true,
            "offlineEnabled": false,
            "installType": installed.resourceRelativePath.contains("/prepared") ? "normal" : "development",
            "type": manifest["theme"] == nil ? "extension" : "theme",
            "permissions": apiPermissions,
            "hostPermissions": Array(hostPermissions).sorted()
        ]
        if !installed.isEnabled {
            value["disabledReason"] = "unknown"
        }
        if let shortName = manifest["short_name"] as? String {
            value["shortName"] = shortName
        }
        if let versionName = manifest["version_name"] as? String {
            value["versionName"] = versionName
        }
        if let homepageURL = manifest["homepage_url"] as? String {
            value["homepageUrl"] = homepageURL
        }
        if let optionsURL = optionsURL(from: manifest) {
            value["optionsUrl"] = optionsURL
        }
        if let updateURL = updateURL(from: manifest) {
            value["updateUrl"] = updateURL
        }
        if let icons = manifest["icons"] as? [String: Any] {
            value["icons"] = icons.compactMap { size, path -> [String: Any]? in
                guard let sizeValue = Int(size), let pathValue = path as? String else { return nil }
                return ["size": sizeValue, "url": pathValue]
            }.sorted { ($0["size"] as? Int ?? 0) < ($1["size"] as? Int ?? 0) }
        } else {
            value["icons"] = [[String: Any]]()
        }
        return value
    }

    private static func manifest(for installed: InstalledWebExtension) -> [String: Any] {
        let url = extensionsDirectory
            .appendingPathComponent(installed.resourceRelativePath, isDirectory: true)
            .appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return manifest
    }

    private static func optionsURL(from manifest: [String: Any]) -> String? {
        if let page = manifest["options_page"] as? String {
            return page
        }
        return (manifest["options_ui"] as? [String: Any])?["page"] as? String
    }

    private static func updateURL(from manifest: [String: Any]) -> String? {
        if let value = manifest["update_url"] as? String {
            return value
        }
        let settings = manifest["browser_specific_settings"] as? [String: Any]
        let gecko = settings?["gecko"] as? [String: Any]
        return gecko?["update_url"] as? String
    }

    private static func permissionWarnings(
        permissions: Set<String>,
        hostPermissions: Set<String>
    ) -> [String] {
        var warnings: [String] = []
        let sensitivePermissions: Set<String> = [
            "bookmarks", "browsingData", "clipboardRead", "clipboardWrite", "contextualIdentities",
            "cookies", "downloads", "history", "management", "nativeMessaging", "notifications",
            "privacy", "proxy", "tabs", "webNavigation", "webRequest", "webRequestBlocking"
        ]
        for permission in permissions.intersection(sensitivePermissions).sorted() {
            warnings.append("Permission: \(permission)")
        }
        if !hostPermissions.isEmpty {
            warnings.append("Website access: \(hostPermissions.sorted().joined(separator: ", "))")
        }
        return warnings
    }

    private static func confirmUninstall(_ installed: InstalledWebExtension) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove \(installed.name)?"
        alert.informativeText = "This removes the extension and its installed package from Ora."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func installTheme(
        from url: URL,
        expectedHash: String?,
        manager: ExtensionManager
    ) async throws -> InstalledWebExtension {
        let (downloadedURL, response) = try await URLSession.shared.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments("The theme package could not be downloaded.")
        }

        let data = try Data(contentsOf: downloadedURL)
        try verify(data: data, expectedHash: expectedHash)
        guard try archiveContainsTheme(downloadedURL) else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "browser.management.install only installs theme extensions."
            )
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("xpi")
        try data.write(to: temporaryURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        return try await manager.installLocalResource(at: temporaryURL)
    }

    private static func archiveContainsTheme(_ url: URL) throws -> Bool {
        guard let archive = Archive(url: url, accessMode: .read),
              let entry = archive["manifest.json"]
        else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments("The downloaded XPI has no manifest.json.")
        }
        var manifestData = Data()
        _ = try archive.extract(entry) { manifestData.append($0) }
        guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments("The downloaded theme manifest is invalid.")
        }
        return manifest["theme"] != nil
    }

    private static func verify(data: Data, expectedHash: String?) throws {
        guard let expectedHash, !expectedHash.isEmpty else { return }
        let components = expectedHash.split(separator: ":", maxSplits: 1).map(String.init)
        guard components.count == 2 else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments("The management.install hash is malformed.")
        }
        let actual: String
        switch components[0].lowercased() {
        case "sha256":
            actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "sha384":
            actual = SHA384.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "sha512":
            actual = SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
        default:
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "Ora requires sha256, sha384, or sha512 for management.install verification."
            )
        }
        guard actual.caseInsensitiveCompare(components[1]) == .orderedSame else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments("The downloaded theme hash does not match.")
        }
    }

    private static func isHostPermission(_ permission: String) -> Bool {
        permission == "<all_urls>" || permission.contains("://")
    }

    private static var extensionsDirectory: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Ora/Extensions", isDirectory: true)
    }
}
