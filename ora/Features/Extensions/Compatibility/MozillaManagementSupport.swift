import AppKit
import CryptoKit
import Foundation
import ZIPFoundation

@MainActor
enum MozillaManagementSupport {
    static func extensionInfo(_ installed: InstalledWebExtension) -> [String: Any] {
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
        applyOptionalInfo(manifest: manifest, value: &value)
        return value
    }

    static func permissionWarnings(
        permissions: Set<String>,
        hostPermissions: Set<String>
    ) -> [String] {
        let sensitivePermissions: Set<String> = [
            "bookmarks", "browsingData", "clipboardRead", "clipboardWrite",
            "contextualIdentities", "cookies", "downloads", "history", "management",
            "nativeMessaging", "notifications", "privacy", "proxy", "tabs",
            "webNavigation", "webRequest", "webRequestBlocking"
        ]
        var warnings = permissions.intersection(sensitivePermissions).sorted().map {
            "Permission: \($0)"
        }
        if !hostPermissions.isEmpty {
            warnings.append("Website access: \(hostPermissions.sorted().joined(separator: ", "))")
        }
        return warnings
    }

    static func isHostPermission(_ permission: String) -> Bool {
        permission == "<all_urls>" || permission.contains("://")
    }

    static func confirmUninstall(_ installed: InstalledWebExtension) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove \(installed.name)?"
        alert.informativeText = "This removes the extension and its installed package from Ora."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func installTheme(
        from url: URL,
        expectedHash: String?,
        manager: ExtensionManager
    ) async throws -> InstalledWebExtension {
        let (downloadedURL, response) = try await URLSession.shared.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "The theme package could not be downloaded."
            )
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

    private static func applyOptionalInfo(
        manifest: [String: Any],
        value: inout [String: Any]
    ) {
        if !((value["enabled"] as? Bool) ?? true) {
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
        value["icons"] = extensionIcons(from: manifest)
    }

    private static func extensionIcons(from manifest: [String: Any]) -> [[String: Any]] {
        guard let icons = manifest["icons"] as? [String: Any] else { return [] }
        return icons.compactMap { size, path -> [String: Any]? in
            guard let sizeValue = Int(size), let pathValue = path as? String else { return nil }
            return ["size": sizeValue, "url": pathValue]
        }
        .sorted { ($0["size"] as? Int ?? 0) < ($1["size"] as? Int ?? 0) }
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

    private static func archiveContainsTheme(_ url: URL) throws -> Bool {
        guard let archive = Archive(url: url, accessMode: .read),
              let entry = archive["manifest.json"]
        else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "The downloaded XPI has no manifest.json."
            )
        }
        var manifestData = Data()
        _ = try archive.extract(entry) { manifestData.append($0) }
        guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "The downloaded theme manifest is invalid."
            )
        }
        return manifest["theme"] != nil
    }

    private static func verify(data: Data, expectedHash: String?) throws {
        guard let expectedHash, !expectedHash.isEmpty else { return }
        let components = expectedHash.split(separator: ":", maxSplits: 1).map(String.init)
        guard components.count == 2 else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "The management.install hash is malformed."
            )
        }
        let actual = try digest(data: data, algorithm: components[0])
        guard actual.caseInsensitiveCompare(components[1]) == .orderedSame else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "The downloaded theme hash does not match."
            )
        }
    }

    private static func digest(data: Data, algorithm: String) throws -> String {
        switch algorithm.lowercased() {
        case "sha256":
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "sha384":
            return SHA384.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "sha512":
            return SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
        default:
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "Ora requires sha256, sha384, or sha512 for management.install verification."
            )
        }
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
