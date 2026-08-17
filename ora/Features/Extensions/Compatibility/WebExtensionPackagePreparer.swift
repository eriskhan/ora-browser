import Foundation
import ZIPFoundation

struct PreparedWebExtensionPackage {
    let resourceURL: URL
    let originalPermissions: Set<String>
    let optionalPermissions: Set<String>
    let compatibilityRevision: Int
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

    static let currentCompatibilityRevision = 5
    static let internalBridgePermission = "nativeMessaging"
    private static let bridgeWorkerFileName = "__ora_mozilla_background.js"
    private static let bridgeWorkerTargetFileName = "__ora_mozilla_background_target.txt"

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

        return try patchPreparedResource(at: rootURL, originalPermissions: nil)
    }

    static func refreshPreparedResource(
        at rootURL: URL,
        originalPermissions: Set<String>
    ) throws -> PreparedWebExtensionPackage {
        try patchPreparedResource(at: rootURL, originalPermissions: originalPermissions)
    }

    static func inferOriginalPermissions(at rootURL: URL) throws -> Set<String> {
        var permissions = try manifestPermissions(at: rootURL, key: "permissions")
        let compatibilityURL = rootURL.appendingPathComponent(OraMozillaCompatibilityScript.fileName)
        if FileManager.default.fileExists(atPath: compatibilityURL.path),
           let source = try? String(contentsOf: compatibilityURL, encoding: .utf8),
           source.contains("ORA_ORIGINAL_PERMISSIONS"),
           source.contains("const ORA_ORIGINAL_NATIVE_MESSAGING = false")
        {
            permissions.remove(internalBridgePermission)
        }
        return permissions
    }

    static func inferOptionalPermissions(at rootURL: URL) throws -> Set<String> {
        try manifestPermissions(at: rootURL, key: "optional_permissions")
    }

    private static func manifestPermissions(at rootURL: URL, key: String) throws -> Set<String> {
        let manifestURL = rootURL.appendingPathComponent("manifest.json")
        guard let text = try? String(contentsOf: manifestURL, encoding: .utf8),
              let data = removingJSONComments(from: text).data(using: .utf8),
              let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw PreparationError.invalidManifest
        }
        return Set(manifest[key] as? [String] ?? [])
    }

    private static func patchPreparedResource(
        at rootURL: URL,
        originalPermissions explicitOriginalPermissions: Set<String>?
    ) throws -> PreparedWebExtensionPackage {
        let manifestURL = rootURL.appendingPathComponent("manifest.json")
        guard let text = try? String(contentsOf: manifestURL, encoding: .utf8),
              let data = removingJSONComments(from: text).data(using: .utf8),
              var manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw PreparationError.invalidManifest
        }

        let originalPermissions = explicitOriginalPermissions ?? Set(manifest["permissions"] as? [String] ?? [])
        let optionalPermissions = Set(manifest["optional_permissions"] as? [String] ?? [])
        let declaredPermissions = originalPermissions.union(optionalPermissions)
        let originallyRequestedNativeMessaging = originalPermissions.contains(internalBridgePermission)
        let encodedRequiredPermissions = jsonArrayLiteral(Array(originalPermissions).sorted())
        let encodedOptionalPermissions = jsonArrayLiteral(Array(optionalPermissions).sorted())
        let encodedDeclaredPermissions = jsonArrayLiteral(Array(declaredPermissions).sorted())
        let compatibilitySource = OraMozillaCompatibilityScript.source
            .replacingOccurrences(
                of: "__ORA_ORIGINAL_NATIVE_MESSAGING__",
                with: originallyRequestedNativeMessaging ? "true" : "false"
            )
            .replacingOccurrences(of: "__ORA_ORIGINAL_PERMISSIONS__", with: encodedDeclaredPermissions)
            .replacingOccurrences(of: "__ORA_REQUIRED_PERMISSIONS__", with: encodedRequiredPermissions)
            .replacingOccurrences(of: "__ORA_OPTIONAL_PERMISSIONS__", with: encodedOptionalPermissions)
        let nativeNamespaceSource = OraMozillaNativeNamespaceScript.source(
            declaredPermissions: declaredPermissions
        )

        try compatibilitySource.write(
            to: rootURL.appendingPathComponent(OraMozillaCompatibilityScript.fileName),
            atomically: true,
            encoding: .utf8
        )
        try nativeNamespaceSource.write(
            to: rootURL.appendingPathComponent(OraMozillaNativeNamespaceScript.fileName),
            atomically: true,
            encoding: .utf8
        )

        patchInternalBridgePermission(in: &manifest)
        try patchBackground(
            in: &manifest,
            rootURL: rootURL,
            compatibilitySource: compatibilitySource,
            nativeNamespaceSource: nativeNamespaceSource
        )
        patchContentScripts(in: &manifest)
        try patchExtensionHTMLFiles(rootURL: rootURL)

        let updatedManifest = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        )
        try updatedManifest.write(to: manifestURL, options: .atomic)
        return PreparedWebExtensionPackage(
            resourceURL: rootURL,
            originalPermissions: declaredPermissions,
            optionalPermissions: optionalPermissions,
            compatibilityRevision: currentCompatibilityRevision
        )
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
        compatibilitySource: String,
        nativeNamespaceSource: String
    ) throws {
        guard var background = manifest["background"] as? [String: Any] else { return }

        if let configuredWorker = background["service_worker"] as? String, !configuredWorker.isEmpty {
            let isModule = (background["type"] as? String)?.lowercased() == "module"
            let originalWorker = try recoverOriginalWorker(
                configuredWorker: configuredWorker,
                rootURL: rootURL,
                isModule: isModule
            )
            let workerPath = isModule ? moduleSpecifier(for: originalWorker) : originalWorker
            let workerLiteral = jsonStringLiteral(workerPath)
            let wrapper: String

            if isModule {
                let compatibilityLiteral = jsonStringLiteral(
                    moduleSpecifier(for: OraMozillaCompatibilityScript.fileName)
                )
                let nativeLiteral = jsonStringLiteral(
                    moduleSpecifier(for: OraMozillaNativeNamespaceScript.fileName)
                )
                wrapper = "import \(compatibilityLiteral);\nimport \(nativeLiteral);\nimport \(workerLiteral);\n"
            } else {
                wrapper = compatibilitySource + "\n" + nativeNamespaceSource +
                    "\nimportScripts(\(workerLiteral));\n"
            }

            try originalWorker.write(
                to: rootURL.appendingPathComponent(bridgeWorkerTargetFileName),
                atomically: true,
                encoding: .utf8
            )
            try wrapper.write(
                to: rootURL.appendingPathComponent(bridgeWorkerFileName),
                atomically: true,
                encoding: .utf8
            )
            background["service_worker"] = bridgeWorkerFileName
        }

        if var scripts = background["scripts"] as? [String] {
            scripts.removeAll {
                $0 == OraMozillaCompatibilityScript.fileName ||
                    $0 == OraMozillaNativeNamespaceScript.fileName
            }
            scripts.insert(OraMozillaNativeNamespaceScript.fileName, at: 0)
            scripts.insert(OraMozillaCompatibilityScript.fileName, at: 0)
            background["scripts"] = scripts
        }

        manifest["background"] = background
    }

    private static func recoverOriginalWorker(
        configuredWorker: String,
        rootURL: URL,
        isModule: Bool
    ) throws -> String {
        guard configuredWorker == bridgeWorkerFileName else { return configuredWorker }

        let targetURL = rootURL.appendingPathComponent(bridgeWorkerTargetFileName)
        if let stored = try? String(contentsOf: targetURL, encoding: .utf8), !stored.isEmpty {
            return stored
        }

        let wrapperURL = rootURL.appendingPathComponent(bridgeWorkerFileName)
        guard let wrapper = try? String(contentsOf: wrapperURL, encoding: .utf8),
              let recovered = isModule
                ? originalModuleWorker(from: wrapper)
                : originalClassicWorker(from: wrapper)
        else {
            throw PreparationError.invalidManifest
        }
        return recovered
    }

    private static func originalModuleWorker(from wrapper: String) -> String? {
        let shimNames = Set([
            OraMozillaCompatibilityScript.fileName,
            OraMozillaNativeNamespaceScript.fileName
        ])
        for rawLine in wrapper.split(whereSeparator: { $0.isNewline }).reversed() {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("import "), line.hasSuffix(";") else { continue }
            let literal = String(line.dropFirst("import ".count).dropLast())
            guard let path = decodeJSONString(literal) else { continue }
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            if !shimNames.contains(fileName), fileName != bridgeWorkerFileName {
                return path
            }
        }
        return nil
    }

    private static func originalClassicWorker(from wrapper: String) -> String? {
        guard let start = wrapper.range(of: "importScripts(", options: .backwards) else { return nil }
        let suffix = wrapper[start.upperBound...]
        guard let end = suffix.firstIndex(of: ")") else { return nil }
        let literal = String(suffix[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return decodeJSONString(literal)
    }

    private static func decodeJSONString(_ literal: String) -> String? {
        guard let data = literal.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }

    private static func patchContentScripts(in manifest: inout [String: Any]) {
        guard var contentScripts = manifest["content_scripts"] as? [[String: Any]] else { return }
        for index in contentScripts.indices {
            var scripts = contentScripts[index]["js"] as? [String] ?? []
            scripts.removeAll {
                $0 == OraMozillaCompatibilityScript.fileName ||
                    $0 == OraMozillaNativeNamespaceScript.fileName
            }
            scripts.insert(OraMozillaNativeNamespaceScript.fileName, at: 0)
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

        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "html" {
            guard var html = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            var tags = ""
            if !html.contains(OraMozillaCompatibilityScript.fileName) {
                tags += "<script src=\"/\(OraMozillaCompatibilityScript.fileName)\"></script>"
            }
            if !html.contains(OraMozillaNativeNamespaceScript.fileName) {
                tags += "<script src=\"/\(OraMozillaNativeNamespaceScript.fileName)\"></script>"
            }
            guard !tags.isEmpty else { continue }

            if let headRange = html.range(of: "</head>", options: [.caseInsensitive]) {
                html.insert(contentsOf: tags, at: headRange.lowerBound)
            } else {
                html = tags + html
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
