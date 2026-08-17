import Foundation
import ZIPFoundation

struct PreparedWebExtensionPackage {
    let resourceURL: URL
}

enum WebExtensionPackagePreparer {
    enum PreparationError: LocalizedError {
        case missingManifest
        case invalidManifest
        case unsupportedArchive

        var errorDescription: String? {
            switch self {
            case .missingManifest:
                return "The extension package does not contain manifest.json."
            case .invalidManifest:
                return "The extension manifest is not valid JSON."
            case .unsupportedArchive:
                return "Choose an unpacked extension folder, ZIP archive, or Firefox XPI package."
            }
        }
    }

    static let internalBridgePermission = "nativeMessaging"
    private static let bridgeWorkerFileName = "__ora_mozilla_background.js"

    static func prepare(resourceURL: URL, installDirectory: URL) throws -> PreparedWebExtensionPackage {
        let rootURL: URL
        let values = try resourceURL.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            rootURL = try locateManifestRoot(startingAt: resourceURL)
        } else {
            let fileExtension = resourceURL.pathExtension.lowercased()
            guard fileExtension == "zip" || fileExtension == "xpi" else {
                throw PreparationError.unsupportedArchive
            }

            let extractedURL = installDirectory.appendingPathComponent("prepared", isDirectory: true)
            if FileManager.default.fileExists(atPath: extractedURL.path) {
                try FileManager.default.removeItem(at: extractedURL)
            }
            try FileManager.default.createDirectory(at: extractedURL, withIntermediateDirectories: true)
            try FileManager.default.unzipItem(at: resourceURL, to: extractedURL)
            rootURL = try locateManifestRoot(startingAt: extractedURL)
        }

        let manifestURL = rootURL.appendingPathComponent("manifest.json")
        guard let text = try? String(contentsOf: manifestURL, encoding: .utf8),
              let data = removingJSONComments(from: text).data(using: .utf8),
              var manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw PreparationError.invalidManifest
        }

        let originalPermissions = manifest["permissions"] as? [String] ?? []
        let originallyRequestedNativeMessaging = originalPermissions.contains(internalBridgePermission)
        let encodedOriginalPermissions = jsonArrayLiteral(originalPermissions)
        let compatibilitySource = OraMozillaCompatibilityScript.source
            .replacingOccurrences(
                of: "__ORA_ORIGINAL_NATIVE_MESSAGING__",
                with: originallyRequestedNativeMessaging ? "true" : "false"
            )
            .replacingOccurrences(of: "__ORA_ORIGINAL_PERMISSIONS__", with: encodedOriginalPermissions)

        try compatibilitySource.write(
            to: rootURL.appendingPathComponent(OraMozillaCompatibilityScript.fileName),
            atomically: true,
            encoding: .utf8
        )

        patchInternalBridgePermission(in: &manifest)
        try patchBackground(in: &manifest, rootURL: rootURL, compatibilitySource: compatibilitySource)
        patchContentScripts(in: &manifest)
        try patchExtensionHTMLFiles(rootURL: rootURL)

        let updatedManifest = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        )
        try updatedManifest.write(to: manifestURL, options: .atomic)
        return PreparedWebExtensionPackage(resourceURL: rootURL)
    }

    private static func locateManifestRoot(startingAt directory: URL) throws -> URL {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) {
            return directory
        }

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw PreparationError.missingManifest
        }

        for case let candidate as URL in enumerator {
            let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) {
                return candidate
            }
        }
        throw PreparationError.missingManifest
    }

    private static func patchInternalBridgePermission(in manifest: inout [String: Any]) {
        var permissions = manifest["permissions"] as? [String] ?? []
        guard !permissions.contains(internalBridgePermission) else { return }
        permissions.append(internalBridgePermission)
        manifest["permissions"] = permissions
    }

    private static func patchBackground(
        in manifest: inout [String: Any],
        rootURL: URL,
        compatibilitySource: String
    ) throws {
        guard var background = manifest["background"] as? [String: Any] else { return }

        if let worker = background["service_worker"] as? String, !worker.isEmpty {
            let isModule = (background["type"] as? String)?.lowercased() == "module"
            let workerPath = isModule ? moduleSpecifier(for: worker) : worker
            let workerLiteral = jsonStringLiteral(workerPath)
            let wrapper: String

            if isModule {
                let compatibilityLiteral = jsonStringLiteral(
                    moduleSpecifier(for: OraMozillaCompatibilityScript.fileName)
                )
                wrapper = "import \(compatibilityLiteral);\nimport \(workerLiteral);\n"
            } else {
                wrapper = compatibilitySource + "\nimportScripts(\(workerLiteral));\n"
            }

            try wrapper.write(
                to: rootURL.appendingPathComponent(bridgeWorkerFileName),
                atomically: true,
                encoding: .utf8
            )
            background["service_worker"] = bridgeWorkerFileName
        }

        if var scripts = background["scripts"] as? [String] {
            scripts.removeAll { $0 == OraMozillaCompatibilityScript.fileName }
            scripts.insert(OraMozillaCompatibilityScript.fileName, at: 0)
            background["scripts"] = scripts
        }

        manifest["background"] = background
    }

    private static func patchContentScripts(in manifest: inout [String: Any]) {
        guard var contentScripts = manifest["content_scripts"] as? [[String: Any]] else { return }
        for index in contentScripts.indices {
            var scripts = contentScripts[index]["js"] as? [String] ?? []
            scripts.removeAll { $0 == OraMozillaCompatibilityScript.fileName }
            scripts.insert(OraMozillaCompatibilityScript.fileName, at: 0)
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

        let tag = "<script src=\"/\(OraMozillaCompatibilityScript.fileName)\"></script>"
        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "html" {
            guard var html = try? String(contentsOf: fileURL, encoding: .utf8),
                  !html.contains(OraMozillaCompatibilityScript.fileName)
            else { continue }

            if let headRange = html.range(of: "</head>", options: [.caseInsensitive]) {
                html.insert(contentsOf: tag, at: headRange.lowerBound)
            } else {
                html = tag + html
            }
            try html.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    static func removingJSONComments(from source: String) -> String {
        var result = ""
        var index = source.startIndex
        var inString = false
        var escaped = false
        var inLineComment = false
        var inBlockComment = false

        while index < source.endIndex {
            let character = source[index]
            let nextIndex = source.index(after: index)
            let nextCharacter = nextIndex < source.endIndex ? source[nextIndex] : nil

            if inLineComment {
                if character == "\n" || character == "\r" {
                    inLineComment = false
                    result.append(character)
                }
                index = nextIndex
                continue
            }

            if inBlockComment {
                if character == "*", nextCharacter == "/" {
                    inBlockComment = false
                    index = source.index(after: nextIndex)
                } else {
                    if character == "\n" || character == "\r" {
                        result.append(character)
                    }
                    index = nextIndex
                }
                continue
            }

            if inString {
                result.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = nextIndex
                continue
            }

            if character == "\"" {
                inString = true
                result.append(character)
                index = nextIndex
                continue
            }

            if character == "/", nextCharacter == "/" {
                inLineComment = true
                index = source.index(after: nextIndex)
                continue
            }

            if character == "/", nextCharacter == "*" {
                inBlockComment = true
                index = source.index(after: nextIndex)
                continue
            }

            result.append(character)
            index = nextIndex
        }

        return result
    }

    private static func moduleSpecifier(for path: String) -> String {
        if path.hasPrefix("./") || path.hasPrefix("../") || path.hasPrefix("/") {
            return path
        }
        return "./" + path
    }

    private static func jsonArrayLiteral(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let result = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return result
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
