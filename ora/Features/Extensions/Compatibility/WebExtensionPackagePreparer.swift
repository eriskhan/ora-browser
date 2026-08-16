import Foundation
import ZIPFoundation

struct PreparedWebExtensionPackage {
    let resourceURL: URL
    let compatibilityPermissions: Set<String>
}

struct WebExtensionPackagePreparer {
    enum PreparationError: LocalizedError {
        case missingManifest
        case invalidManifest

        var errorDescription: String? {
            switch self {
            case .missingManifest:
                return "The extension package does not contain manifest.json."
            case .invalidManifest:
                return "The extension manifest is not valid JSON."
            }
        }
    }

    private static let bridgePermission = "nativeMessaging"
    private static let bridgeWorkerFileName = "__ora_background_bridge.js"

    static func prepare(resourceURL: URL, installDirectory: URL) throws -> PreparedWebExtensionPackage {
        let rootURL: URL
        let values = try resourceURL.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            rootURL = try locateManifestRoot(startingAt: resourceURL)
        } else {
            let extractedURL = installDirectory.appendingPathComponent("prepared", isDirectory: true)
            if FileManager.default.fileExists(atPath: extractedURL.path) {
                try FileManager.default.removeItem(at: extractedURL)
            }
            try FileManager.default.createDirectory(at: extractedURL, withIntermediateDirectories: true)
            try FileManager.default.unzipItem(at: resourceURL, to: extractedURL)
            rootURL = try locateManifestRoot(startingAt: extractedURL)
        }

        let manifestURL = rootURL.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              var manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw PreparationError.invalidManifest
        }

        var permissions = manifest["permissions"] as? [String] ?? []
        if !permissions.contains(bridgePermission) {
            permissions.append(bridgePermission)
        }
        manifest["permissions"] = permissions

        let bridgeURL = rootURL.appendingPathComponent(OraChromeAPIBridgeScript.fileName)
        try OraChromeAPIBridgeScript.source.write(to: bridgeURL, atomically: true, encoding: .utf8)

        patchBackground(in: &manifest, rootURL: rootURL)
        patchContentScripts(in: &manifest)
        try patchExtensionHTMLFiles(rootURL: rootURL)

        let updatedManifest = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try updatedManifest.write(to: manifestURL, options: .atomic)

        return PreparedWebExtensionPackage(
            resourceURL: rootURL,
            compatibilityPermissions: [bridgePermission]
        )
    }

    private static func locateManifestRoot(startingAt directory: URL) throws -> URL {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) {
            return directory
        }

        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw PreparationError.missingManifest
        }

        for case let candidate as URL in enumerator {
            let values = try? candidate.resourceValues(forKeys: keys)
            guard values?.isDirectory == true else { continue }
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) {
                return candidate
            }
        }
        throw PreparationError.missingManifest
    }

    private static func patchBackground(in manifest: inout [String: Any], rootURL: URL) {
        guard var background = manifest["background"] as? [String: Any] else { return }

        if let worker = background["service_worker"] as? String, !worker.isEmpty {
            let type = (background["type"] as? String)?.lowercased()
            let workerLiteral = jsonStringLiteral(type == "module" ? moduleSpecifier(for: worker) : worker)
            let wrapper: String
            if type == "module" {
                wrapper = OraChromeAPIBridgeScript.source + "\nimport \(workerLiteral);\n"
            } else {
                wrapper = OraChromeAPIBridgeScript.source + "\nimportScripts(\(workerLiteral));\n"
            }
            try? wrapper.write(
                to: rootURL.appendingPathComponent(bridgeWorkerFileName),
                atomically: true,
                encoding: .utf8
            )
            background["service_worker"] = bridgeWorkerFileName
        }

        if var scripts = background["scripts"] as? [String] {
            scripts.removeAll { $0 == OraChromeAPIBridgeScript.fileName }
            scripts.insert(OraChromeAPIBridgeScript.fileName, at: 0)
            background["scripts"] = scripts
        }

        manifest["background"] = background
    }

    private static func patchContentScripts(in manifest: inout [String: Any]) {
        guard var contentScripts = manifest["content_scripts"] as? [[String: Any]] else { return }
        for index in contentScripts.indices {
            var scripts = contentScripts[index]["js"] as? [String] ?? []
            scripts.removeAll { $0 == OraChromeAPIBridgeScript.fileName }
            scripts.insert(OraChromeAPIBridgeScript.fileName, at: 0)
            contentScripts[index]["js"] = scripts
        }
        manifest["content_scripts"] = contentScripts
    }

    private static func patchExtensionHTMLFiles(rootURL: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let tag = "<script src=\"/\(OraChromeAPIBridgeScript.fileName)\"></script>"
        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "html" {
            guard var html = try? String(contentsOf: fileURL, encoding: .utf8),
                  !html.contains(OraChromeAPIBridgeScript.fileName)
            else { continue }

            if let headRange = html.range(of: "</head>", options: [.caseInsensitive]) {
                html.insert(contentsOf: tag, at: headRange.lowerBound)
            } else {
                html = tag + html
            }
            try html.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    private static func moduleSpecifier(for path: String) -> String {
        if path.hasPrefix("./") || path.hasPrefix("../") || path.hasPrefix("/") {
            return path
        }
        return "./" + path
    }

    private static func jsonStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let result = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        return result
    }
}
