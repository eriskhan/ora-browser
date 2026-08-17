import AppKit
import Foundation
@preconcurrency import WebKit

@MainActor
final class OraDeclarativeContentManager {
    struct ActionState {
        var enabled: Bool?
        var iconPath: String?
    }

    private struct CacheKey: Hashable {
        let runtimeIdentifier: String
        let tabID: UUID
    }

    static let shared = OraDeclarativeContentManager()
    private let defaultsKey = "webExtensions.declarativeContent.rules.v1"
    private var actionStates: [CacheKey: ActionState] = [:]
    private var executedContentScripts: Set<String> = []

    private init() {}

    func handle(
        method: String,
        args: [Any],
        spaceID: UUID,
        context: WKWebExtensionContext
    ) throws -> Any? {
        try requirePermission(context)
        guard let installedExtension = WebExtensionManager.shared.installedExtension(for: context) else {
            throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("The extension is no longer installed.")
        }
        let runtimeIdentifier = installedExtension.runtimeIdentifier
        var store = loadStore()
        let key = storeKey(runtimeIdentifier: runtimeIdentifier, spaceID: spaceID)

        switch method {
        case "addRules":
            guard var incoming = args.first as? [[String: Any]] else {
                throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("declarativeContent.addRules requires an array of rules.")
            }
            var existing = store[key] ?? []
            let existingIDs = Set(existing.compactMap { $0["id"] as? String })
            for index in incoming.indices {
                if incoming[index]["id"] == nil {
                    incoming[index]["id"] = UUID().uuidString
                }
                guard let ruleID = incoming[index]["id"] as? String, !ruleID.isEmpty else {
                    throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("Declarative rules require non-empty IDs.")
                }
                if existingIDs.contains(ruleID) || incoming[..<index].contains(where: { $0["id"] as? String == ruleID }) {
                    throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("A declarative rule with ID \(ruleID) already exists.")
                }
                try validateRule(incoming[index])
            }
            existing.append(contentsOf: incoming)
            store[key] = existing
            saveStore(store)
            scheduleEvaluation(spaceID: spaceID)
            return nil

        case "removeRules":
            let identifiers = args.first as? [String]
            if let identifiers {
                let identifierSet = Set(identifiers)
                store[key] = (store[key] ?? []).filter { rule in
                    guard let ruleID = rule["id"] as? String else { return false }
                    return !identifierSet.contains(ruleID)
                }
            } else {
                store[key] = []
            }
            saveStore(store)
            clearCache(runtimeIdentifier: runtimeIdentifier)
            scheduleEvaluation(spaceID: spaceID)
            return nil

        case "getRules":
            let identifiers = args.first as? [String]
            let rules = store[key] ?? []
            if let identifiers {
                let identifierSet = Set(identifiers)
                return rules.filter { rule in
                    guard let ruleID = rule["id"] as? String else { return false }
                    return identifierSet.contains(ruleID)
                }
            }
            return rules

        default:
            throw OraChromeExtensionAPIHost.BridgeError.unsupportedMethod("declarativeContent", method)
        }
    }

    func evaluate(tab: Tab) async {
        guard !tab.isPrivate, let page = tab.browserPage else { return }
        let spaceID = tab.container.id
        let store = loadStore()
        let installedExtensions = WebExtensionManager.shared.installedExtensions.filter { $0.isEnabled(in: spaceID) }

        for installedExtension in installedExtensions {
            let runtimeIdentifier = installedExtension.runtimeIdentifier
            let rules = store[storeKey(runtimeIdentifier: runtimeIdentifier, spaceID: spaceID)] ?? []
            guard !rules.isEmpty else {
                actionStates[CacheKey(runtimeIdentifier: runtimeIdentifier, tabID: tab.id)] = nil
                continue
            }

            let hasShowActionRules = rules.contains { rule in
                (rule["actions"] as? [[String: Any]] ?? []).contains { action in
                    let type = action["__oraType"] as? String
                    return type == "ShowAction" || type == "ShowPageAction"
                }
            }
            var matchedShowAction = false
            var matchedIconPath: String?

            for rule in rules {
                guard await ruleMatches(rule, tab: tab, page: page) else { continue }
                let actions = rule["actions"] as? [[String: Any]] ?? []
                for action in actions {
                    switch action["__oraType"] as? String {
                    case "ShowAction", "ShowPageAction":
                        matchedShowAction = true
                    case "SetIcon":
                        matchedIconPath = iconPath(from: action) ?? matchedIconPath
                    case "RequestContentScript":
                        await executeRequestedContentScript(
                            action,
                            ruleID: rule["id"] as? String ?? "",
                            installedExtension: installedExtension,
                            tab: tab,
                            page: page
                        )
                    default:
                        continue
                    }
                }
            }

            actionStates[CacheKey(runtimeIdentifier: runtimeIdentifier, tabID: tab.id)] = ActionState(
                enabled: hasShowActionRules ? matchedShowAction : nil,
                iconPath: matchedIconPath
            )
        }
    }

    func actionEnabled(runtimeIdentifier: String, tab: Tab) -> Bool? {
        actionStates[CacheKey(runtimeIdentifier: runtimeIdentifier, tabID: tab.id)]?.enabled
    }

    func actionIcon(runtimeIdentifier: String, tab: Tab, size: CGSize) -> NSImage? {
        guard let path = actionStates[CacheKey(runtimeIdentifier: runtimeIdentifier, tabID: tab.id)]?.iconPath,
              let installedExtension = WebExtensionManager.shared.installedExtensions.first(where: {
                  $0.runtimeIdentifier == runtimeIdentifier
              })
        else { return nil }
        let url = safeResourceURL(path, installedExtension: installedExtension)
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        image.size = size
        return image
    }

    func removeExtension(runtimeIdentifier: String) {
        var store = loadStore()
        let prefix = runtimeIdentifier + "|"
        store.keys.filter { $0.hasPrefix(prefix) }.forEach { store[$0] = nil }
        saveStore(store)
        clearCache(runtimeIdentifier: runtimeIdentifier)
    }

    private func ruleMatches(_ rule: [String: Any], tab: Tab, page: BrowserPage) async -> Bool {
        let conditions = rule["conditions"] as? [[String: Any]] ?? []
        guard !conditions.isEmpty else { return false }
        for condition in conditions where await conditionMatches(condition, tab: tab, page: page) {
            return true
        }
        return false
    }

    private func conditionMatches(_ condition: [String: Any], tab: Tab, page: BrowserPage) async -> Bool {
        guard condition["__oraType"] as? String == "PageStateMatcher" else { return false }
        if let pageURL = condition["pageUrl"] as? [String: Any], !matchesURLFilter(tab.url, filter: pageURL) {
            return false
        }
        if let bookmarked = condition["isBookmarked"] as? Bool, bookmarked != (tab.type == .fav) {
            return false
        }
        if let selectors = condition["css"] as? [String], !selectors.isEmpty {
            let encoded = json(selectors)
            let script = """
            (() => {
              const selectors = \(encoded);
              const visible = (element) => {
                for (let node = element; node && node.nodeType === 1; node = node.parentElement) {
                  if (getComputedStyle(node).display === 'none') return false;
                }
                return true;
              };
              return selectors.every((selector) => {
                try { return Array.from(document.querySelectorAll(selector)).some(visible); }
                catch (_) { return false; }
              });
            })();
            """
            do {
                let result = try await page.webExtensionWebView.evaluateJavaScript(script)
                guard (result as? Bool) == true else { return false }
            } catch {
                return false
            }
        }
        return true
    }

    private func matchesURLFilter(_ url: URL, filter: [String: Any]) -> Bool {
        let absolute = url.absoluteString
        let host = url.host ?? ""
        let path = url.path
        let query = url.query ?? ""
        let scheme = url.scheme ?? ""
        let values: [(String, String)] = [
            ("host", host), ("path", path), ("query", query), ("url", absolute)
        ]
        for (prefix, value) in values {
            if let expected = filter["\(prefix)Contains"] as? String, !value.contains(expected) { return false }
            if let expected = filter["\(prefix)Equals"] as? String, value != expected { return false }
            if let expected = filter["\(prefix)Prefix"] as? String, !value.hasPrefix(expected) { return false }
            if let expected = filter["\(prefix)Suffix"] as? String, !value.hasSuffix(expected) { return false }
        }
        if let schemes = filter["schemes"] as? [String], !schemes.isEmpty, !schemes.contains(scheme) { return false }
        if let ports = filter["ports"] as? [Any], !ports.isEmpty {
            let port = url.port ?? defaultPort(for: scheme)
            guard let port else { return false }
            let matched = ports.contains { raw in
                if let number = raw as? NSNumber { return number.intValue == port }
                if let range = raw as? [NSNumber], range.count == 2 {
                    return port >= range[0].intValue && port <= range[1].intValue
                }
                return false
            }
            if !matched { return false }
        }
        return true
    }

    private func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "http": 80
        case "https": 443
        case "ftp": 21
        default: nil
        }
    }

    private func validateRule(_ rule: [String: Any]) throws {
        let conditions = rule["conditions"] as? [[String: Any]] ?? []
        let actions = rule["actions"] as? [[String: Any]] ?? []
        guard !conditions.isEmpty, !actions.isEmpty else {
            throw OraChromeExtensionAPIHost.BridgeError.invalidArguments(
                "Declarative content rules require conditions and actions."
            )
        }
        for condition in conditions {
            guard condition["__oraType"] as? String == "PageStateMatcher" else {
                throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("Unsupported declarative content condition.")
            }
        }
        let supported = Set(["ShowAction", "ShowPageAction", "SetIcon", "RequestContentScript"])
        for action in actions {
            guard let type = action["__oraType"] as? String, supported.contains(type) else {
                throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("Unsupported declarative content action.")
            }
        }
    }

    private func requirePermission(_ context: WKWebExtensionContext) throws {
        let status = context.permissionStatus(for: WKWebExtension.Permission(rawValue: "declarativeContent"))
        guard status == .grantedExplicitly || status == .grantedImplicitly else {
            throw OraChromeExtensionAPIHost.BridgeError.invalidArguments(
                "The declarativeContent permission has not been granted in this Ora space."
            )
        }
    }

    private func iconPath(from action: [String: Any]) -> String? {
        if let path = action["path"] as? String { return path }
        if let paths = action["path"] as? [String: String] {
            return paths["16"] ?? paths["19"] ?? paths["32"] ?? paths.values.first
        }
        return nil
    }

    private func executeRequestedContentScript(
        _ action: [String: Any],
        ruleID: String,
        installedExtension: InstalledWebExtension,
        tab: Tab,
        page: BrowserPage
    ) async {
        let executionKey = "\(installedExtension.runtimeIdentifier)|\(tab.id.uuidString)|\(ruleID)|\(tab.url.absoluteString)"
        guard executedContentScripts.insert(executionKey).inserted else { return }

        if let cssFiles = action["css"] as? [String] {
            for file in cssFiles {
                guard let url = safeResourceURL(file, installedExtension: installedExtension),
                      let css = try? String(contentsOf: url, encoding: .utf8)
                else { continue }
                let encodedCSS = json(css)
                let js = """
                (() => {
                  const style = document.createElement('style');
                  style.dataset.oraDeclarativeContent = \(json(ruleID));
                  style.textContent = \(encodedCSS);
                  (document.head || document.documentElement).appendChild(style);
                })();
                """
                _ = try? await page.webExtensionWebView.evaluateJavaScript(js)
            }
        }
        if let jsFiles = action["js"] as? [String] {
            for file in jsFiles {
                guard let url = safeResourceURL(file, installedExtension: installedExtension),
                      let source = try? String(contentsOf: url, encoding: .utf8)
                else { continue }
                _ = try? await page.webExtensionWebView.evaluateJavaScript(source)
            }
        }
    }

    private func scheduleEvaluation(spaceID: UUID) {
        guard let manager = WebExtensionPermissionPrompter.shared.tabManager(for: spaceID),
              let container = manager.containers.first(where: { $0.id == spaceID })
        else { return }
        for tab in container.tabs where tab.browserPage != nil {
            Task { @MainActor in await self.evaluate(tab: tab) }
        }
    }

    private func safeResourceURL(_ path: String, installedExtension: InstalledWebExtension) -> URL? {
        let root = extensionResourceURL(installedExtension).standardizedFileURL
        let candidate = root.appendingPathComponent(path).standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else { return nil }
        return candidate
    }

    private func extensionResourceURL(_ installedExtension: InstalledWebExtension) -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("Ora", isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true)
            .appendingPathComponent(installedExtension.resourceRelativePath)
    }

    private func storeKey(runtimeIdentifier: String, spaceID: UUID) -> String {
        runtimeIdentifier + "|" + spaceID.uuidString
    }

    private func clearCache(runtimeIdentifier: String) {
        actionStates = actionStates.filter { $0.key.runtimeIdentifier != runtimeIdentifier }
    }

    private func loadStore() -> [String: [[String: Any]]] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let object = try? JSONSerialization.jsonObject(with: data),
              let store = object as? [String: [[String: Any]]]
        else { return [:] }
        return store
    }

    private func saveStore(_ store: [String: [[String: Any]]]) {
        guard JSONSerialization.isValidJSONObject(store),
              let data = try? JSONSerialization.data(withJSONObject: store)
        else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8)
        else { return "null" }
        return string
    }
}
