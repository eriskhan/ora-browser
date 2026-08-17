import Foundation
@preconcurrency import WebKit

@MainActor
final class OraUserScriptsManager {
    struct ScriptSource: Codable, Equatable {
        var code: String?
        var file: String?
        var resolvedCode: String

        func apiDictionary() -> [String: Any] {
            if let code { return ["code": code] }
            if let file { return ["file": file] }
            return ["code": resolvedCode]
        }
    }

    struct Registration: Codable, Equatable {
        let runtimeIdentifier: String
        let spaceID: UUID
        var id: String
        var js: [ScriptSource]
        var matches: [String]
        var excludeMatches: [String]
        var includeGlobs: [String]
        var excludeGlobs: [String]
        var allFrames: Bool
        var runAt: String
        var world: String
        var worldId: String?
        var persistAcrossSessions: Bool
        var sessionIdentifier: String

        func apiDictionary() -> [String: Any] {
            var value: [String: Any] = [
                "id": id,
                "js": js.map { $0.apiDictionary() },
                "matches": matches,
                "excludeMatches": excludeMatches,
                "includeGlobs": includeGlobs,
                "excludeGlobs": excludeGlobs,
                "allFrames": allFrames,
                "runAt": runAt,
                "world": world,
                "persistAcrossSessions": persistAcrossSessions
            ]
            if let worldId { value["worldId"] = worldId }
            return value
        }
    }

    struct WorldConfiguration: Codable, Equatable {
        let runtimeIdentifier: String
        let spaceID: UUID
        let worldId: String
        var csp: String?
        var messaging: Bool

        func apiDictionary() -> [String: Any] {
            var value: [String: Any] = ["worldId": worldId, "messaging": messaging]
            if let csp { value["csp"] = csp }
            return value
        }
    }

    static let shared = OraUserScriptsManager()
    private static let registrationsKey = "webExtensions.userScripts.registrations.v1"
    private static let worldsKey = "webExtensions.userScripts.worlds.v1"
    private static let processSessionIdentifier = UUID().uuidString

    private var attachedWebViews: Set<ObjectIdentifier> = []

    private init() {}

    func handle(
        method: String,
        args: [Any],
        spaceID: UUID,
        context: WKWebExtensionContext
    ) async throws -> Any? {
        try requireUserScriptsPermission(context)
        guard let installedExtension = WebExtensionManager.shared.installedExtension(for: context) else {
            throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("The extension is no longer installed.")
        }
        let runtimeIdentifier = installedExtension.runtimeIdentifier

        switch method {
        case "register":
            guard let values = args.first as? [[String: Any]] else {
                throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("userScripts.register requires an array of scripts.")
            }
            var registrations = loadRegistrations()
            let existingIDs = Set(registrations.filter {
                $0.runtimeIdentifier == runtimeIdentifier && $0.spaceID == spaceID && isCurrent($0)
            }.map(\.id))
            let parsed = try values.map {
                try parseRegistration(
                    $0,
                    runtimeIdentifier: runtimeIdentifier,
                    spaceID: spaceID,
                    installedExtension: installedExtension,
                    context: context,
                    existing: nil
                )
            }
            let newIDs = parsed.map(\.id)
            guard Set(newIDs).count == newIDs.count else {
                throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("User script IDs must be unique.")
            }
            if let duplicate = newIDs.first(where: { existingIDs.contains($0) }) {
                throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("A user script with ID \(duplicate) is already registered.")
            }
            registrations.append(contentsOf: parsed)
            saveRegistrations(registrations)
            refreshTabs(in: spaceID)
            return nil

        case "getScripts":
            let filter = args.first as? [String: Any] ?? [:]
            let ids = Set(filter["ids"] as? [String] ?? [])
            return currentRegistrations(runtimeIdentifier: runtimeIdentifier, spaceID: spaceID)
                .filter { ids.isEmpty || ids.contains($0.id) }
                .map { $0.apiDictionary() }

        case "update":
            guard let updates = args.first as? [[String: Any]] else {
                throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("userScripts.update requires an array of scripts.")
            }
            var registrations = loadRegistrations()
            for update in updates {
                guard let id = update["id"] as? String,
                      let index = registrations.firstIndex(where: {
                          $0.runtimeIdentifier == runtimeIdentifier && $0.spaceID == spaceID && $0.id == id && isCurrent($0)
                      })
                else {
                    throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("userScripts.update references an unknown script ID.")
                }
                registrations[index] = try parseRegistration(
                    update,
                    runtimeIdentifier: runtimeIdentifier,
                    spaceID: spaceID,
                    installedExtension: installedExtension,
                    context: context,
                    existing: registrations[index]
                )
            }
            saveRegistrations(registrations)
            refreshTabs(in: spaceID)
            return nil

        case "unregister":
            let filter = args.first as? [String: Any] ?? [:]
            let ids = Set(filter["ids"] as? [String] ?? [])
            var registrations = loadRegistrations()
            registrations.removeAll { registration in
                guard registration.runtimeIdentifier == runtimeIdentifier,
                      registration.spaceID == spaceID,
                      isCurrent(registration)
                else { return false }
                return ids.isEmpty || ids.contains(registration.id)
            }
            saveRegistrations(registrations)
            refreshTabs(in: spaceID)
            return nil

        case "configureWorld":
            let properties = args.first as? [String: Any] ?? [:]
            guard let worldId = properties["worldId"] as? String else {
                throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("configureWorld requires worldId.")
            }
            try validateIdentifier(worldId, label: "worldId")
            let messaging = properties["messaging"] as? Bool ?? false
            if messaging {
                throw OraChromeExtensionAPIHost.BridgeError.unsupportedMethod(
                    "userScripts",
                    "configureWorld messaging=true on WebKit 15.4"
                )
            }
            if let csp = properties["csp"] as? String, !csp.isEmpty {
                throw OraChromeExtensionAPIHost.BridgeError.unsupportedMethod(
                    "userScripts",
                    "custom world CSP on WebKit 15.4"
                )
            }
            var worlds = loadWorlds()
            worlds.removeAll {
                $0.runtimeIdentifier == runtimeIdentifier && $0.spaceID == spaceID && $0.worldId == worldId
            }
            worlds.append(WorldConfiguration(
                runtimeIdentifier: runtimeIdentifier,
                spaceID: spaceID,
                worldId: worldId,
                csp: nil,
                messaging: false
            ))
            saveWorlds(worlds)
            return nil

        case "getWorldConfigurations":
            return loadWorlds()
                .filter { $0.runtimeIdentifier == runtimeIdentifier && $0.spaceID == spaceID }
                .map { $0.apiDictionary() }

        case "resetWorldConfiguration":
            let worldId: String? = if let value = args.first as? String {
                value
            } else if let properties = args.first as? [String: Any] {
                properties["worldId"] as? String
            } else {
                nil
            }
            var worlds = loadWorlds()
            worlds.removeAll { world in
                guard world.runtimeIdentifier == runtimeIdentifier && world.spaceID == spaceID else { return false }
                return worldId == nil || world.worldId == worldId
            }
            saveWorlds(worlds)
            refreshTabs(in: spaceID)
            return nil

        case "execute":
            let injection = args.first as? [String: Any] ?? [:]
            return try await execute(
                injection: injection,
                spaceID: spaceID,
                installedExtension: installedExtension,
                context: context
            )

        default:
            throw OraChromeExtensionAPIHost.BridgeError.unsupportedMethod("userScripts", method)
        }
    }

    func attachRegisteredScripts(to tab: Tab, spaceID: UUID) {
        guard !tab.isPrivate, let page = tab.browserPage else { return }
        let webView = page.webExtensionWebView
        let webViewIdentifier = ObjectIdentifier(webView)
        guard attachedWebViews.insert(webViewIdentifier).inserted else { return }

        let enabledRuntimeIdentifiers = Set(WebExtensionManager.shared.installedExtensions
            .filter { $0.isEnabled(in: spaceID) }
            .map(\.runtimeIdentifier))
        let contentController = webView.configuration.userContentController
        for registration in loadRegistrations() where
            registration.spaceID == spaceID &&
            enabledRuntimeIdentifiers.contains(registration.runtimeIdentifier) &&
            isCurrent(registration)
        {
            let world = contentWorld(for: registration)
            let script = WKUserScript(
                source: guardedSource(for: registration),
                injectionTime: registration.runAt == "document_start" ? .atDocumentStart : .atDocumentEnd,
                forMainFrameOnly: !registration.allFrames,
                in: world
            )
            contentController.addUserScript(script)
        }
    }

    func removeExtension(runtimeIdentifier: String) {
        var registrations = loadRegistrations()
        registrations.removeAll { $0.runtimeIdentifier == runtimeIdentifier }
        saveRegistrations(registrations)
        var worlds = loadWorlds()
        worlds.removeAll { $0.runtimeIdentifier == runtimeIdentifier }
        saveWorlds(worlds)
    }

    private func execute(
        injection: [String: Any],
        spaceID: UUID,
        installedExtension: InstalledWebExtension,
        context: WKWebExtensionContext
    ) async throws -> [[String: Any]] {
        let target = injection["target"] as? [String: Any] ?? [:]
        guard let tab = try OraChromeExtensionAPIHost.shared.resolveOraTab(from: target["__oraTab"], spaceID: spaceID),
              let webView = tab.browserPage?.webExtensionWebView
        else {
            throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("userScripts.execute could not resolve the requested tab.")
        }
        let adapter = OraWebExtensionTabCache.shared.adapter(for: tab)
        guard context.hasAccess(to: tab.url, in: adapter) else {
            throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("The extension does not have access to the target tab URL.")
        }

        let sources = try parseSources(
            injection["js"] as? [[String: Any]] ?? [],
            installedExtension: installedExtension
        )
        guard !sources.isEmpty else {
            throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("userScripts.execute requires JavaScript source.")
        }
        if target["allFrames"] as? Bool == true || !(target["frameIds"] as? [NSNumber] ?? []).isEmpty {
            throw OraChromeExtensionAPIHost.BridgeError.unsupportedMethod(
                "userScripts",
                "execute targeting subframes with public WKWebView frame APIs"
            )
        }

        let worldName = injection["world"] as? String ?? "USER_SCRIPT"
        let worldId = injection["worldId"] as? String
        let contentWorld = contentWorld(
            runtimeIdentifier: installedExtension.runtimeIdentifier,
            world: worldName,
            worldId: worldId
        )
        let body = sources.map(\.resolvedCode).joined(separator: "\n")
        let result = try await webView.callAsyncJavaScript(
            "return await (async () => {\n\(body)\n})();",
            arguments: [:],
            in: nil,
            contentWorld: contentWorld
        )
        return [[
            "frameId": 0,
            "documentId": "",
            "result": result ?? NSNull()
        ]]
    }

    private func parseRegistration(
        _ value: [String: Any],
        runtimeIdentifier: String,
        spaceID: UUID,
        installedExtension: InstalledWebExtension,
        context: WKWebExtensionContext,
        existing: Registration?
    ) throws -> Registration {
        guard let id = value["id"] as? String ?? existing?.id else {
            throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("Registered user scripts require an id.")
        }
        try validateIdentifier(id, label: "script id")

        let matches = value["matches"] as? [String] ?? existing?.matches ?? []
        guard !matches.isEmpty else {
            throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("Registered user scripts require at least one match pattern.")
        }
        try validateHostAccess(matches: matches, context: context)

        let js: [ScriptSource]
        if let rawSources = value["js"] as? [[String: Any]] {
            js = try parseSources(rawSources, installedExtension: installedExtension)
        } else if let existing {
            js = existing.js
        } else {
            js = []
        }
        guard !js.isEmpty else {
            throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("Registered user scripts require JavaScript source.")
        }

        let world = (value["world"] as? String ?? existing?.world ?? "USER_SCRIPT").uppercased()
        guard world == "MAIN" || world == "USER_SCRIPT" else {
            throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("userScripts world must be MAIN or USER_SCRIPT.")
        }
        let worldId = value["worldId"] as? String ?? existing?.worldId
        if let worldId { try validateIdentifier(worldId, label: "worldId") }
        if world == "MAIN", worldId != nil {
            throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("worldId is only valid for USER_SCRIPT worlds.")
        }

        let runAt = value["runAt"] as? String ?? existing?.runAt ?? "document_idle"
        guard ["document_start", "document_end", "document_idle"].contains(runAt) else {
            throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("Unknown userScripts runAt value: \(runAt).")
        }

        return Registration(
            runtimeIdentifier: runtimeIdentifier,
            spaceID: spaceID,
            id: id,
            js: js,
            matches: matches,
            excludeMatches: value["excludeMatches"] as? [String] ?? existing?.excludeMatches ?? [],
            includeGlobs: value["includeGlobs"] as? [String] ?? existing?.includeGlobs ?? [],
            excludeGlobs: value["excludeGlobs"] as? [String] ?? existing?.excludeGlobs ?? [],
            allFrames: value["allFrames"] as? Bool ?? existing?.allFrames ?? false,
            runAt: runAt,
            world: world,
            worldId: worldId,
            persistAcrossSessions: value["persistAcrossSessions"] as? Bool ?? existing?.persistAcrossSessions ?? true,
            sessionIdentifier: existing?.sessionIdentifier ?? Self.processSessionIdentifier
        )
    }

    private func parseSources(
        _ values: [[String: Any]],
        installedExtension: InstalledWebExtension
    ) throws -> [ScriptSource] {
        try values.map { value in
            let code = value["code"] as? String
            let file = value["file"] as? String
            guard (code != nil) != (file != nil) else {
                throw OraChromeExtensionAPIHost.BridgeError.invalidArguments(
                    "Each user script source must contain exactly one of code or file."
                )
            }
            if let code {
                return ScriptSource(code: code, file: nil, resolvedCode: code)
            }
            let resolvedCode = try scriptFileContents(
                file ?? "",
                installedExtension: installedExtension
            )
            return ScriptSource(code: nil, file: file, resolvedCode: resolvedCode)
        }
    }

    private func scriptFileContents(
        _ path: String,
        installedExtension: InstalledWebExtension
    ) throws -> String {
        let root = extensionResourceURL(installedExtension)
        let candidate = root.appendingPathComponent(path).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard candidate.path == rootPath || candidate.path.hasPrefix(rootPath + "/") else {
            throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("User script files must stay inside the extension package.")
        }
        do {
            return try String(contentsOf: candidate, encoding: .utf8)
        } catch {
            throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("Could not load user script file: \(path).")
        }
    }

    private func validateHostAccess(matches: [String], context: WKWebExtensionContext) throws {
        for rawPattern in matches {
            guard let pattern = try? WKWebExtension.MatchPattern(string: rawPattern) else {
                throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("Invalid user script match pattern: \(rawPattern).")
            }
            let status = context.permissionStatus(for: pattern)
            guard status == .grantedExplicitly || status == .grantedImplicitly else {
                throw OraChromeExtensionAPIHost.BridgeError.invalidArguments(
                    "The extension does not have host access for \(rawPattern)."
                )
            }
        }
    }

    private func requireUserScriptsPermission(_ context: WKWebExtensionContext) throws {
        let status = context.permissionStatus(for: WKWebExtension.Permission(rawValue: "userScripts"))
        guard status == .grantedExplicitly || status == .grantedImplicitly else {
            throw OraChromeExtensionAPIHost.BridgeError.invalidArguments(
                "The userScripts permission has not been granted in this Ora space."
            )
        }
    }

    private func validateIdentifier(_ identifier: String, label: String) throws {
        guard !identifier.isEmpty, !identifier.hasPrefix("_"), !identifier.contains("__") else {
            throw OraChromeExtensionAPIHost.BridgeError.invalidArguments(
                "The \(label) must be non-empty and may not use reserved underscore identifiers."
            )
        }
    }

    private func currentRegistrations(runtimeIdentifier: String, spaceID: UUID) -> [Registration] {
        loadRegistrations().filter {
            $0.runtimeIdentifier == runtimeIdentifier && $0.spaceID == spaceID && isCurrent($0)
        }
    }

    private func isCurrent(_ registration: Registration) -> Bool {
        registration.persistAcrossSessions || registration.sessionIdentifier == Self.processSessionIdentifier
    }

    private func contentWorld(for registration: Registration) -> WKContentWorld {
        contentWorld(
            runtimeIdentifier: registration.runtimeIdentifier,
            world: registration.world,
            worldId: registration.worldId
        )
    }

    private func contentWorld(runtimeIdentifier: String, world: String, worldId: String?) -> WKContentWorld {
        if world.uppercased() == "MAIN" {
            return .page
        }
        let suffix = worldId ?? "default"
        return .world(name: "Ora.UserScripts.\(runtimeIdentifier).\(suffix)")
    }

    private func guardedSource(for registration: Registration) -> String {
        let matches = json(registration.matches)
        let excludeMatches = json(registration.excludeMatches)
        let includeGlobs = json(registration.includeGlobs)
        let excludeGlobs = json(registration.excludeGlobs)
        let code = registration.js.map(\.resolvedCode).joined(separator: "\n")
        return """
        (() => {
          const __oraURL = String(location.href);
          const __oraPatterns = \(matches);
          const __oraExcludePatterns = \(excludeMatches);
          const __oraIncludeGlobs = \(includeGlobs);
          const __oraExcludeGlobs = \(excludeGlobs);
          const __oraWildcard = (value, pattern) => {
            const escaped = pattern.replace(/[.+^${}()|[\\]\\]/g, '\\$&').replace(/\\*/g, '.*').replace(/\\?/g, '.');
            return new RegExp('^' + escaped + '$').test(value);
          };
          const __oraMatchPattern = (pattern, rawURL) => {
            if (pattern === '<all_urls>') return /^(https?|file|ftp):/.test(rawURL);
            let parsed;
            try { parsed = new URL(rawURL); } catch (_) { return false; }
            const match = pattern.match(/^([^:]+):\\/\\/([^/]+)(\/.*)$/);
            if (!match) return false;
            const [, schemePattern, hostPattern, pathPattern] = match;
            if (schemePattern !== '*' && parsed.protocol.slice(0, -1) !== schemePattern) return false;
            if (schemePattern === '*' && !['http:', 'https:'].includes(parsed.protocol)) return false;
            const host = parsed.hostname;
            if (hostPattern !== '*' && !(hostPattern.startsWith('*.')
                ? (host === hostPattern.slice(2) || host.endsWith('.' + hostPattern.slice(2)))
                : host === hostPattern)) return false;
            return __oraWildcard(parsed.pathname + parsed.search, pathPattern);
          };
          if (!__oraPatterns.some((pattern) => __oraMatchPattern(pattern, __oraURL))) return;
          if (__oraExcludePatterns.some((pattern) => __oraMatchPattern(pattern, __oraURL))) return;
          if (__oraIncludeGlobs.length && !__oraIncludeGlobs.some((pattern) => __oraWildcard(__oraURL, pattern))) return;
          if (__oraExcludeGlobs.some((pattern) => __oraWildcard(__oraURL, pattern))) return;
          try {
            \(code)
          } catch (error) {
            console.error('[Ora userScripts] registered script failed', error);
          }
        })();
        """
    }

    private func refreshTabs(in spaceID: UUID) {
        guard let tabManager = WebExtensionPermissionPrompter.shared.tabManager(for: spaceID),
              let container = tabManager.containers.first(where: { $0.id == spaceID })
        else { return }
        for tab in container.tabs where tab.browserPage != nil {
            tab.refreshBrowserPageForPrivacySettings()
        }
    }

    private func extensionResourceURL(_ installedExtension: InstalledWebExtension) -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("Ora", isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true)
            .appendingPathComponent(installedExtension.resourceRelativePath)
    }

    private func loadRegistrations() -> [Registration] {
        guard let data = UserDefaults.standard.data(forKey: Self.registrationsKey),
              let values = try? JSONDecoder().decode([Registration].self, from: data)
        else { return [] }
        return values
    }

    private func saveRegistrations(_ values: [Registration]) {
        if let data = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(data, forKey: Self.registrationsKey)
        }
    }

    private func loadWorlds() -> [WorldConfiguration] {
        guard let data = UserDefaults.standard.data(forKey: Self.worldsKey),
              let values = try? JSONDecoder().decode([WorldConfiguration].self, from: data)
        else { return [] }
        return values
    }

    private func saveWorlds(_ values: [WorldConfiguration]) {
        if let data = try? JSONEncoder().encode(values) {
            UserDefaults.standard.set(data, forKey: Self.worldsKey)
        }
    }

    private func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8)
        else { return "[]" }
        return string
    }
}
