import Foundation
@preconcurrency import WebKit

@MainActor
final class WebExtensionOmniboxCoordinator {
    struct Match {
        let installedExtension: InstalledWebExtension
        let keyword: String
        let text: String
    }

    struct Suggestion {
        let content: String
        let description: String
        let deletable: Bool
    }

    static let shared = WebExtensionOmniboxCoordinator()

    private var keywordCache: [UUID: String] = [:]
    private var knownWithoutKeyword: Set<UUID> = []
    private var defaultDescriptions: [String: String] = [:]
    private var activeRuntimeIdentifierBySpace: [UUID: String] = [:]

    private init() {}

    func match(input: String, spaceID: UUID) -> Match? {
        let candidates = WebExtensionManager.shared.installedExtensions
            .filter { $0.isEnabled(in: spaceID) }
            .compactMap { installedExtension -> (InstalledWebExtension, String)? in
                guard let keyword = keyword(for: installedExtension) else { return nil }
                return (installedExtension, keyword)
            }
            .sorted { lhs, rhs in lhs.1.count > rhs.1.count }

        for (installedExtension, keyword) in candidates {
            if input == keyword {
                return Match(installedExtension: installedExtension, keyword: keyword, text: "")
            }
            let prefix = keyword + " "
            if input.hasPrefix(prefix) {
                return Match(
                    installedExtension: installedExtension,
                    keyword: keyword,
                    text: String(input.dropFirst(prefix.count))
                )
            }
        }
        return nil
    }

    func defaultTitle(for match: Match) -> String {
        if let description = defaultDescriptions[match.installedExtension.runtimeIdentifier], !description.isEmpty {
            return plainText(description)
        }
        if match.text.isEmpty {
            return "Search \(match.installedExtension.name)"
        }
        return "\(match.text) — \(match.installedExtension.name)"
    }

    func suggestions(for match: Match, spaceID: UUID) async -> [Suggestion] {
        activate(match, spaceID: spaceID)
        do {
            let result = try await OraChromeExtensionAPIHost.shared.requestEvent(
                namespace: "omnibox",
                event: "onInputChanged",
                args: [match.text],
                spaceID: spaceID,
                runtimeIdentifier: match.installedExtension.runtimeIdentifier,
                timeout: 2
            )
            guard let values = result as? [[String: Any]] else { return [] }
            return values.compactMap { value in
                guard let content = value["content"] as? String, !content.isEmpty else { return nil }
                let description = value["description"] as? String ?? content
                return Suggestion(
                    content: content,
                    description: plainText(description),
                    deletable: value["deletable"] as? Bool ?? false
                )
            }
        } catch {
            return []
        }
    }

    func submit(match: Match, content: String, disposition: String, spaceID: UUID) {
        activate(match, spaceID: spaceID)
        OraChromeExtensionAPIHost.shared.emit(
            namespace: "omnibox",
            event: "onInputEntered",
            args: [content, disposition],
            spaceID: spaceID,
            runtimeIdentifier: match.installedExtension.runtimeIdentifier
        )
        activeRuntimeIdentifierBySpace[spaceID] = nil
    }

    func deleteSuggestion(_ suggestion: Suggestion, match: Match, spaceID: UUID) {
        guard suggestion.deletable else { return }
        OraChromeExtensionAPIHost.shared.emit(
            namespace: "omnibox",
            event: "onDeleteSuggestion",
            args: [suggestion.content],
            spaceID: spaceID,
            runtimeIdentifier: match.installedExtension.runtimeIdentifier
        )
    }

    func cancelIfActive(spaceID: UUID?) {
        guard let spaceID, let runtimeIdentifier = activeRuntimeIdentifierBySpace.removeValue(forKey: spaceID) else {
            return
        }
        OraChromeExtensionAPIHost.shared.emit(
            namespace: "omnibox",
            event: "onInputCancelled",
            args: [],
            spaceID: spaceID,
            runtimeIdentifier: runtimeIdentifier
        )
    }

    func handle(method: String, args: [Any], context: WKWebExtensionContext) throws -> Any? {
        guard method == "setDefaultSuggestion" else {
            throw OraChromeExtensionAPIHost.BridgeError.unsupportedMethod("omnibox", method)
        }
        guard let installedExtension = WebExtensionManager.shared.installedExtension(for: context) else {
            throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("The extension is no longer installed.")
        }
        let details = args.first as? [String: Any] ?? [:]
        guard let description = details["description"] as? String else {
            throw OraChromeExtensionAPIHost.BridgeError.invalidArguments(
                "omnibox.setDefaultSuggestion requires a description."
            )
        }
        defaultDescriptions[installedExtension.runtimeIdentifier] = description
        return nil
    }

    private func activate(_ match: Match, spaceID: UUID) {
        let runtimeIdentifier = match.installedExtension.runtimeIdentifier
        guard activeRuntimeIdentifierBySpace[spaceID] != runtimeIdentifier else { return }

        if let previous = activeRuntimeIdentifierBySpace[spaceID] {
            OraChromeExtensionAPIHost.shared.emit(
                namespace: "omnibox",
                event: "onInputCancelled",
                args: [],
                spaceID: spaceID,
                runtimeIdentifier: previous
            )
        }
        activeRuntimeIdentifierBySpace[spaceID] = runtimeIdentifier
        OraChromeExtensionAPIHost.shared.emit(
            namespace: "omnibox",
            event: "onInputStarted",
            args: [],
            spaceID: spaceID,
            runtimeIdentifier: runtimeIdentifier
        )
    }

    private func keyword(for installedExtension: InstalledWebExtension) -> String? {
        if let cached = keywordCache[installedExtension.id] { return cached }
        if knownWithoutKeyword.contains(installedExtension.id) { return nil }

        let manifestURL = resourceURL(for: installedExtension).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let omnibox = manifest["omnibox"] as? [String: Any],
              let rawKeyword = omnibox["keyword"] as? String
        else {
            knownWithoutKeyword.insert(installedExtension.id)
            return nil
        }

        let keyword = rawKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            knownWithoutKeyword.insert(installedExtension.id)
            return nil
        }
        keywordCache[installedExtension.id] = keyword
        return keyword
    }

    private func resourceURL(for installedExtension: InstalledWebExtension) -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("Ora", isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true)
            .appendingPathComponent(installedExtension.resourceRelativePath)
    }

    private func plainText(_ description: String) -> String {
        description
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}
