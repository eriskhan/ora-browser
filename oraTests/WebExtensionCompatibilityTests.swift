import Foundation
@testable import Ora
import Testing

struct WebExtensionCompatibilityTests {
    @Test func mozillaCatalogHasUniqueNamespaces() {
        let names = MozillaExtensionAPICatalog.allNamespaceNames

        #expect(names.count >= 50)
        #expect(Set(names).count == names.count)
    }

    @Test func unsupportedPathsMatchUnsupportedCatalogEntries() {
        let expected = Set(
            MozillaExtensionAPICatalog.namespaces
                .filter { $0.support == .unsupported }
                .map { "browser.\($0.name)" }
        )

        #expect(MozillaExtensionAPICatalog.unsupportedAPIPaths == expected)
    }

    @Test func firefoxCompatibilityAliasesRemainFeatureDetectable() {
        #expect(MozillaExtensionAPICatalog.support(for: "browserAction")?.support == .compatibilityLayer)
        #expect(MozillaExtensionAPICatalog.support(for: "contentScripts")?.support == .compatibilityLayer)
        #expect(MozillaExtensionAPICatalog.support(for: "pageAction")?.support == .compatibilityLayer)
        #expect(MozillaExtensionAPICatalog.support(for: "runtime")?.support == .compatibilityLayer)

        #expect(!MozillaExtensionAPICatalog.unsupportedAPIPaths.contains("browser.browserAction"))
        #expect(!MozillaExtensionAPICatalog.unsupportedAPIPaths.contains("browser.contentScripts"))
        #expect(!MozillaExtensionAPICatalog.unsupportedAPIPaths.contains("browser.pageAction"))
        #expect(!MozillaExtensionAPICatalog.unsupportedAPIPaths.contains("browser.runtime"))
    }

    @Test func jsonCommentRemovalPreservesCommentLikeTextInsideStrings() {
        let source = #"""
        {
          // line comment
          "match": "https://example.com/*",
          "literal": "not // a comment",
          /* block comment */
          "value": 1
        }
        """#

        let stripped = WebExtensionPackagePreparer.removingJSONComments(from: source)

        #expect(stripped.contains("https://example.com/*"))
        #expect(stripped.contains("not // a comment"))
        #expect(!stripped.contains("line comment"))
        #expect(!stripped.contains("block comment"))
    }

    @Test func manifestV2BackgroundAndContentScriptsReceiveBothCompatibilityShimsFirst() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let installDirectory = root.appendingPathComponent("install", isDirectory: true)
        let resourceDirectory = installDirectory.appendingPathComponent("resource", isDirectory: true)
        try FileManager.default.createDirectory(at: resourceDirectory, withIntermediateDirectories: true)

        try "console.log('background');".write(
            to: resourceDirectory.appendingPathComponent("background.js"),
            atomically: true,
            encoding: .utf8
        )
        try "console.log('content');".write(
            to: resourceDirectory.appendingPathComponent("content.js"),
            atomically: true,
            encoding: .utf8
        )

        try writeManifest(
            [
                "manifest_version": 2,
                "name": "Legacy Extension",
                "version": "1.0",
                "background": ["scripts": ["background.js"]],
                "content_scripts": [
                    [
                        "matches": ["<all_urls>"],
                        "js": ["content.js"]
                    ]
                ]
            ],
            to: resourceDirectory
        )

        let prepared = try WebExtensionPackagePreparer.prepare(
            resourceURL: resourceDirectory,
            installDirectory: installDirectory
        )
        let manifest = try readManifest(from: prepared.resourceURL)

        let background = try #require(manifest["background"] as? [String: Any])
        let backgroundScripts = try #require(background["scripts"] as? [String])
        #expect(
            backgroundScripts == [
                OraMozillaCompatibilityScript.fileName,
                OraMozillaNativeNamespaceScript.fileName,
                "background.js"
            ]
        )

        let contentScripts = try #require(manifest["content_scripts"] as? [[String: Any]])
        let firstContentScript = try #require(contentScripts.first)
        let contentJavaScript = try #require(firstContentScript["js"] as? [String])
        #expect(
            contentJavaScript == [
                OraMozillaCompatibilityScript.fileName,
                OraMozillaNativeNamespaceScript.fileName,
                "content.js"
            ]
        )

        #expect(
            FileManager.default.fileExists(
                atPath: prepared.resourceURL.appendingPathComponent(OraMozillaCompatibilityScript.fileName).path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: prepared.resourceURL.appendingPathComponent(OraMozillaNativeNamespaceScript.fileName).path
            )
        )
        #expect(prepared.compatibilityRevision == WebExtensionPackagePreparer.currentCompatibilityRevision)
    }

    @Test func manifestV3ModuleWorkerImportsBothCompatibilityShimsBeforeOriginalWorker() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let installDirectory = root.appendingPathComponent("install", isDirectory: true)
        let resourceDirectory = installDirectory.appendingPathComponent("resource", isDirectory: true)
        try FileManager.default.createDirectory(at: resourceDirectory, withIntermediateDirectories: true)

        try "export const ready = true;".write(
            to: resourceDirectory.appendingPathComponent("worker.js"),
            atomically: true,
            encoding: .utf8
        )
        try writeManifest(
            [
                "manifest_version": 3,
                "name": "Module Worker Extension",
                "version": "1.0",
                "background": [
                    "service_worker": "worker.js",
                    "type": "module"
                ]
            ],
            to: resourceDirectory
        )

        let prepared = try WebExtensionPackagePreparer.prepare(
            resourceURL: resourceDirectory,
            installDirectory: installDirectory
        )
        let manifest = try readManifest(from: prepared.resourceURL)
        let background = try #require(manifest["background"] as? [String: Any])
        #expect(background["service_worker"] as? String == "__ora_mozilla_background.js")

        let wrapperURL = prepared.resourceURL.appendingPathComponent("__ora_mozilla_background.js")
        let wrapper = try String(contentsOf: wrapperURL, encoding: .utf8)
        let compatibilityImport = "import \"./\(OraMozillaCompatibilityScript.fileName)\";"
        let nativeImport = "import \"./\(OraMozillaNativeNamespaceScript.fileName)\";"
        let workerImport = "import \"./worker.js\";"
        let lines = wrapper
            .split(whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespaces) }

        #expect(lines == [compatibilityImport, nativeImport, workerImport])
    }

    @Test func refreshingPreparedModuleWorkerKeepsOriginalWorkerTarget() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let installDirectory = root.appendingPathComponent("install", isDirectory: true)
        let resourceDirectory = installDirectory.appendingPathComponent("resource", isDirectory: true)
        try FileManager.default.createDirectory(at: resourceDirectory, withIntermediateDirectories: true)
        try "export const ready = true;".write(
            to: resourceDirectory.appendingPathComponent("worker.js"),
            atomically: true,
            encoding: .utf8
        )
        try writeManifest(
            [
                "manifest_version": 3,
                "name": "Refreshable Module Worker",
                "version": "1.0",
                "background": [
                    "service_worker": "worker.js",
                    "type": "module"
                ]
            ],
            to: resourceDirectory
        )

        let prepared = try WebExtensionPackagePreparer.prepare(
            resourceURL: resourceDirectory,
            installDirectory: installDirectory
        )
        _ = try WebExtensionPackagePreparer.refreshPreparedResource(
            at: prepared.resourceURL,
            originalPermissions: prepared.originalPermissions
        )

        let manifest = try readManifest(from: prepared.resourceURL)
        let background = try #require(manifest["background"] as? [String: Any])
        #expect(background["service_worker"] as? String == "__ora_mozilla_background.js")

        let wrapperURL = prepared.resourceURL.appendingPathComponent("__ora_mozilla_background.js")
        let wrapper = try String(contentsOf: wrapperURL, encoding: .utf8)
        let workerImport = "import \"./worker.js\";"
        let wrapperImport = "import \"./__ora_mozilla_background.js\";"
        #expect(wrapper.components(separatedBy: workerImport).count - 1 == 1)
        #expect(!wrapper.contains(wrapperImport))

        let targetURL = prepared.resourceURL.appendingPathComponent("__ora_mozilla_background_target.txt")
        #expect(try String(contentsOf: targetURL, encoding: .utf8) == "worker.js")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OraWebExtensionTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeManifest(_ manifest: [String: Any], to directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private func readManifest(from directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
