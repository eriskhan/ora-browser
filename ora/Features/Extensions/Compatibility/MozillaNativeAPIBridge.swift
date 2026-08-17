import AppKit
import CryptoKit
import Darwin
import Foundation
import SwiftData
@preconcurrency import WebKit

@MainActor
final class MozillaNativeAPIBridge {
    static let shared = MozillaNativeAPIBridge()
    static let applicationIdentifier = "com.orabrowser.ora.mozilla"

    enum BridgeError: LocalizedError {
        case invalidMessage
        case permissionDenied(String)
        case unsupportedNamespace(String)
        case unsupportedMethod(String, String)
        case unavailableBrowserWindow
        case invalidArguments(String)
        case itemNotFound(String)

        var errorDescription: String? {
            switch self {
            case .invalidMessage:
                return "Ora received an invalid Mozilla compatibility bridge message."
            case let .permissionDenied(permission):
                return "The extension does not have the \(permission) permission."
            case let .unsupportedNamespace(namespace):
                return "Ora does not implement browser.\(namespace) through the native compatibility bridge."
            case let .unsupportedMethod(namespace, method):
                return "Ora does not implement browser.\(namespace).\(method) through the native compatibility bridge."
            case .unavailableBrowserWindow:
                return "No Ora browser window is available for this extension request."
            case let .invalidArguments(message):
                return message
            case let .itemNotFound(message):
                return message
            }
        }
    }

    private struct PortRegistration {
        let port: WKWebExtension.MessagePort
        let context: WKWebExtensionContext
    }

    private struct TopSiteSnapshot {
        let url: URL
        let title: String
        let faviconLocalFile: URL?
        let visitCount: Int
        let lastAccessedAt: Date
    }

    private var ports: [ObjectIdentifier: PortRegistration] = [:]
    private let searchEngineService = SearchEngineService()

    private init() {}

    func connect(port: WKWebExtension.MessagePort, context: WKWebExtensionContext) throws {
        guard port.applicationIdentifier == Self.applicationIdentifier else {
            throw BridgeError.invalidMessage
        }

        let key = ObjectIdentifier(port)
        ports[key] = PortRegistration(port: port, context: context)
        port.disconnectHandler = { [weak self, weak port] _ in
            guard let self, let port else { return }
            self.ports.removeValue(forKey: ObjectIdentifier(port))
        }
    }

    func emit(namespace: String, event: String, arguments: [Any]) {
        let message: [String: Any] = [
            "ora": "mozilla-event",
            "namespace": namespace,
            "event": event,
            "args": arguments
        ]

        for (key, registration) in ports {
            let port = registration.port
            guard !port.isDisconnected else {
                ports.removeValue(forKey: key)
                continue
            }
            guard ExtensionManager.shared.hasBridgeAccess(to: namespace, for: registration.context) else {
                continue
            }
            port.sendMessage(message) { [weak self, weak port] error in
                guard error != nil, let self, let port else { return }
                self.ports.removeValue(forKey: ObjectIdentifier(port))
            }
        }
    }

    func handleMessage(
        _ message: Any,
        for extensionContext: WKWebExtensionContext,
        manager: ExtensionManager
    ) async throws -> Any {
        guard let payload = message as? [String: Any],
              payload["ora"] as? String == "mozilla-api",
              let namespace = payload["namespace"] as? String,
              let method = payload["method"] as? String
        else {
            throw BridgeError.invalidMessage
        }

        if let permission = requiredPermission(for: namespace),
           !manager.hasBridgeAccess(to: permission, for: extensionContext)
        {
            throw BridgeError.permissionDenied(permission)
        }

        let arguments = payload["args"] as? [Any] ?? []
        switch namespace {
        case "history":
            return try handleHistory(method: method, arguments: arguments, context: extensionContext)
        case "topSites":
            return try handleTopSites(method: method, arguments: arguments, context: extensionContext)
        case "search":
            return try handleSearch(method: method, arguments: arguments, context: extensionContext)
        default:
            throw BridgeError.unsupportedNamespace(namespace)
        }
    }

    private func requiredPermission(for namespace: String) -> String? {
        switch namespace {
        case "history", "topSites", "search":
            return namespace
        default:
            return nil
        }
    }

    private func handleHistory(
        method: String,
        arguments: [Any],
        context: WKWebExtensionContext
    ) throws -> Any {
        let tabManager = try tabManager(for: context)
        let modelContext = tabManager.modelContext

        switch method {
        case "search":
            let query = arguments.first as? [String: Any] ?? [:]
            let text = (query["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let startTime = date(milliseconds: query["startTime"]) ?? Date().addingTimeInterval(-24 * 60 * 60)
            let endTime = date(milliseconds: query["endTime"]) ?? .distantFuture
            let maxResults = max(1, query["maxResults"] as? Int ?? 100)

            let descriptor = FetchDescriptor<History>(sortBy: [SortDescriptor(\.lastAccessedAt, order: .reverse)])
            let records = try modelContext.fetch(descriptor).filter { history in
                history.lastAccessedAt >= startTime && history.lastAccessedAt <= endTime &&
                    (text.isEmpty || history.urlString.localizedStandardContains(text) ||
                        history.title.localizedStandardContains(text))
            }
            return Array(mergeHistoryItems(records).prefix(maxResults))

        case "getVisits":
            guard let details = arguments.first as? [String: Any],
                  let urlString = details["url"] as? String
            else {
                throw BridgeError.invalidArguments("browser.history.getVisits requires a URL.")
            }
            let descriptor = FetchDescriptor<History>(sortBy: [SortDescriptor(\.lastAccessedAt, order: .forward)])
            let histories = try modelContext.fetch(descriptor).filter { $0.urlString == urlString }
            return histories
                .flatMap(\.visitRecords)
                .sorted { $0.visitedAt < $1.visitedAt }
                .map { visit in
                    [
                        "id": historyItemIdentifier(for: urlString),
                        "visitId": visit.id.uuidString,
                        "visitTime": milliseconds(visit.visitedAt),
                        "referringVisitId": visit.referringVisitID?.uuidString ?? "0",
                        "transition": visit.transition
                    ] as [String: Any]
                }

        case "addUrl":
            guard let details = arguments.first as? [String: Any],
                  let urlString = details["url"] as? String,
                  let url = URL(string: urlString)
            else {
                throw BridgeError.invalidArguments("browser.history.addUrl requires a valid URL.")
            }
            guard let container = tabManager.activeContainer else {
                throw BridgeError.unavailableBrowserWindow
            }

            let title = details["title"] as? String ?? url.host ?? url.absoluteString
            let transition = details["transition"] as? String ?? "link"
            let visitDate = date(milliseconds: details["visitTime"]) ?? Date()
            let history = try historyEntry(for: url, container: container, modelContext: modelContext)
            let visit: HistoryVisitRecord
            if let history {
                history.title = title
                visit = history.appendVisit(at: visitDate, transition: transition, referringVisitID: nil)
            } else {
                let faviconURL = FaviconService.shared.faviconURL(for: url.host ?? "") ?? url
                visit = HistoryVisitRecord(
                    id: UUID(),
                    visitedAt: visitDate,
                    transition: transition,
                    referringVisitID: nil
                )
                modelContext.insert(History(
                    url: url,
                    title: title,
                    faviconURL: faviconURL,
                    createdAt: visitDate,
                    lastAccessedAt: visitDate,
                    visitCount: 1,
                    container: container,
                    initialVisit: visit
                ))
            }
            try modelContext.save()
            let item = historyItem(
                id: historyItemIdentifier(for: urlString),
                url: urlString,
                title: title,
                lastVisitTime: visitDate,
                visitCount: history?.visitCount ?? 1
            )
            emit(namespace: "history", event: "onVisited", arguments: [item])
            return NSNull()

        case "deleteUrl":
            guard let details = arguments.first as? [String: Any],
                  let urlString = details["url"] as? String
            else {
                throw BridgeError.invalidArguments("browser.history.deleteUrl requires a URL.")
            }
            let descriptor = FetchDescriptor<History>()
            let matches = try modelContext.fetch(descriptor).filter { $0.urlString == urlString }
            for history in matches {
                modelContext.delete(history)
            }
            try modelContext.save()
            if !matches.isEmpty {
                emit(
                    namespace: "history",
                    event: "onVisitRemoved",
                    arguments: [["allHistory": false, "urls": [urlString]]]
                )
            }
            return NSNull()

        case "deleteRange":
            guard let range = arguments.first as? [String: Any],
                  let startTime = date(milliseconds: range["startTime"]),
                  let endTime = date(milliseconds: range["endTime"])
            else {
                throw BridgeError.invalidArguments("browser.history.deleteRange requires startTime and endTime.")
            }
            let descriptor = FetchDescriptor<History>()
            let histories = try modelContext.fetch(descriptor)
            var removedURLs: [String] = []

            for history in histories {
                let originalRecords = history.visitRecords
                let retained = originalRecords.filter { visit in
                    visit.visitedAt < startTime || visit.visitedAt > endTime
                }
                let removedCount = originalRecords.count - retained.count
                guard removedCount > 0 else { continue }

                history.visitRecords = retained
                history.visitCount = max(0, history.visitCount - removedCount)
                if history.visitCount == 0 {
                    removedURLs.append(history.urlString)
                    modelContext.delete(history)
                } else if let latest = retained.max(by: { $0.visitedAt < $1.visitedAt }) {
                    history.lastAccessedAt = latest.visitedAt
                }
            }
            try modelContext.save()
            if !removedURLs.isEmpty {
                emit(
                    namespace: "history",
                    event: "onVisitRemoved",
                    arguments: [["allHistory": false, "urls": Array(Set(removedURLs))]]
                )
            }
            return NSNull()

        case "deleteAll":
            let descriptor = FetchDescriptor<History>()
            for history in try modelContext.fetch(descriptor) {
                modelContext.delete(history)
            }
            try modelContext.save()
            emit(
                namespace: "history",
                event: "onVisitRemoved",
                arguments: [["allHistory": true, "urls": [String]()]]
            )
            return NSNull()

        default:
            throw BridgeError.unsupportedMethod("history", method)
        }
    }

    private func handleTopSites(
        method: String,
        arguments: [Any],
        context: WKWebExtensionContext
    ) throws -> Any {
        guard method == "get" else {
            throw BridgeError.unsupportedMethod("topSites", method)
        }

        let options = arguments.first as? [String: Any] ?? [:]
        let limit = min(100, max(1, options["limit"] as? Int ?? 12))
        let includeFavicon = options["includeFavicon"] as? Bool ?? false
        let onePerDomain = options["onePerDomain"] as? Bool ?? true
        let newTab = options["newtab"] as? Bool ?? false

        // Ora currently has no Top Sites grid on the new-tab surface. In Firefox,
        // newtab=true specifically requests that surface, so its truthful result is empty.
        if newTab {
            return [Any]()
        }

        let tabManager = try tabManager(for: context)
        let descriptor = FetchDescriptor<History>(sortBy: [SortDescriptor(\.visitCount, order: .reverse)])
        let histories = try tabManager.modelContext.fetch(descriptor)
        let merged = topSiteSnapshots(histories)
            .sorted { lhs, rhs in
                if lhs.visitCount != rhs.visitCount {
                    return lhs.visitCount > rhs.visitCount
                }
                return lhs.lastAccessedAt > rhs.lastAccessedAt
            }

        var seenDomains = Set<String>()
        var results: [[String: Any]] = []
        for history in merged {
            if onePerDomain, let host = history.url.host?.lowercased() {
                guard seenDomains.insert(host).inserted else { continue }
            }

            var item: [String: Any] = [
                "url": history.url.absoluteString,
                "title": history.title,
                "type": "url"
            ]
            if includeFavicon,
               let faviconLocalFile = history.faviconLocalFile,
               let data = try? Data(contentsOf: faviconLocalFile)
            {
                item["favicon"] = "data:image/png;base64,\(data.base64EncodedString())"
            }
            results.append(item)
            if results.count == limit { break }
        }
        return results
    }

    private func handleSearch(
        method: String,
        arguments: [Any],
        context: WKWebExtensionContext
    ) throws -> Any {
        let tabManager = try tabManager(for: context)
        switch method {
        case "get":
            let defaultName = searchEngineService.getDefaultSearchEngine(for: tabManager.activeContainer?.id)?.name
            return searchEngineService.searchEngines.map { engine in
                var result: [String: Any] = [
                    "name": engine.name,
                    "isDefault": engine.name == defaultName
                ]
                if let alias = engine.aliases.first {
                    result["alias"] = alias
                }
                return result
            }

        case "buildURL":
            guard let properties = arguments.first as? [String: Any],
                  let query = properties["query"] as? String
            else {
                throw BridgeError.invalidArguments("browser.search requires a query.")
            }
            let engine: SearchEngine?
            if let name = properties["engine"] as? String {
                engine = searchEngineService.getSearchEngine(byName: name)
            } else {
                engine = searchEngineService.getDefaultSearchEngine(for: tabManager.activeContainer?.id)
            }
            guard let engine,
                  let url = searchEngineService.createSearchURL(for: engine, query: query)
            else {
                throw BridgeError.itemNotFound("The requested Ora search engine is not available.")
            }
            return url.absoluteString

        default:
            throw BridgeError.unsupportedMethod("search", method)
        }
    }

    private func tabManager(for context: WKWebExtensionContext) throws -> TabManager {
        if let focused = context.focusedWindow as? OraWebExtensionWindow,
           let tabManager = focused.tabManager
        {
            return tabManager
        }
        for window in context.openWindows {
            if let oraWindow = window as? OraWebExtensionWindow,
               let tabManager = oraWindow.tabManager
            {
                return tabManager
            }
        }
        throw BridgeError.unavailableBrowserWindow
    }

    private func historyEntry(
        for url: URL,
        container: TabContainer,
        modelContext: ModelContext
    ) throws -> History? {
        let urlString = url.absoluteString
        let containerID = container.id
        let descriptor = FetchDescriptor<History>(
            predicate: #Predicate { history in
                history.urlString == urlString && history.container?.id == containerID
            },
            sortBy: [SortDescriptor(\.lastAccessedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).first
    }

    private func mergeHistoryItems(_ histories: [History]) -> [[String: Any]] {
        let grouped = Dictionary(grouping: histories, by: \.urlString)
        return grouped.values.compactMap { entries in
            guard let latest = entries.max(by: { $0.lastAccessedAt < $1.lastAccessedAt }) else { return nil }
            return historyItem(
                id: historyItemIdentifier(for: latest.urlString),
                url: latest.urlString,
                title: latest.title,
                lastVisitTime: latest.lastAccessedAt,
                visitCount: entries.reduce(0) { $0 + $1.visitCount }
            )
        }
        .sorted {
            ($0["lastVisitTime"] as? Double ?? 0) > ($1["lastVisitTime"] as? Double ?? 0)
        }
    }

    private func topSiteSnapshots(_ histories: [History]) -> [TopSiteSnapshot] {
        let grouped = Dictionary(grouping: histories, by: \.urlString)
        return grouped.values.compactMap { entries in
            guard let latest = entries.max(by: { $0.lastAccessedAt < $1.lastAccessedAt }) else { return nil }
            return TopSiteSnapshot(
                url: latest.url,
                title: latest.title,
                faviconLocalFile: latest.faviconLocalFile,
                visitCount: entries.reduce(0) { $0 + $1.visitCount },
                lastAccessedAt: latest.lastAccessedAt
            )
        }
    }

    private func historyItem(
        id: String,
        url: String,
        title: String,
        lastVisitTime: Date,
        visitCount: Int
    ) -> [String: Any] {
        [
            "id": id,
            "url": url,
            "title": title,
            "lastVisitTime": milliseconds(lastVisitTime),
            "visitCount": visitCount
        ]
    }

    private func historyItemIdentifier(for url: String) -> String {
        let digest = SHA256.hash(data: Data(url.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func milliseconds(_ date: Date) -> Double {
        date.timeIntervalSince1970 * 1_000
    }

    private func date(milliseconds value: Any?) -> Date? {
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue / 1_000)
        }
        if let value = value as? Double {
            return Date(timeIntervalSince1970: value / 1_000)
        }
        return nil
    }
}
