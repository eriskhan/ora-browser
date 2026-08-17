import CryptoKit
import Foundation
import SwiftData
@preconcurrency import WebKit

@MainActor
enum MozillaHistoryAPI {
    static func handle(
        method: String,
        arguments: [Any],
        context: WKWebExtensionContext
    ) throws -> Any {
        let tabManager = try tabManager(for: context)
        switch method {
        case "search":
            return try search(arguments: arguments, modelContext: tabManager.modelContext)
        case "getVisits":
            return try getVisits(arguments: arguments, modelContext: tabManager.modelContext)
        case "addUrl":
            return try addURL(arguments: arguments, tabManager: tabManager)
        case "deleteUrl":
            return try deleteURL(arguments: arguments, modelContext: tabManager.modelContext)
        case "deleteRange":
            return try deleteRange(arguments: arguments, modelContext: tabManager.modelContext)
        case "deleteAll":
            return try deleteAll(modelContext: tabManager.modelContext)
        default:
            throw MozillaNativeAPIBridge.BridgeError.unsupportedMethod("history", method)
        }
    }

    private static func search(
        arguments: [Any],
        modelContext: ModelContext
    ) throws -> [[String: Any]] {
        let query = arguments.first as? [String: Any] ?? [:]
        let text = (query["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let startTime = date(milliseconds: query["startTime"]) ?? Date().addingTimeInterval(-24 * 60 * 60)
        let endTime = date(milliseconds: query["endTime"]) ?? .distantFuture
        let maxResults = max(1, integer(query["maxResults"]) ?? 100)

        let descriptor = FetchDescriptor<History>(
            sortBy: [SortDescriptor(\.lastAccessedAt, order: .reverse)]
        )
        let records = try modelContext.fetch(descriptor).filter { history in
            history.lastAccessedAt >= startTime && history.lastAccessedAt <= endTime &&
                (text.isEmpty || history.urlString.localizedStandardContains(text) ||
                    history.title.localizedStandardContains(text))
        }
        return Array(mergeHistoryItems(records).prefix(maxResults))
    }

    private static func getVisits(
        arguments: [Any],
        modelContext: ModelContext
    ) throws -> [[String: Any]] {
        guard let details = arguments.first as? [String: Any],
              let urlString = details["url"] as? String
        else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "browser.history.getVisits requires a URL."
            )
        }

        let descriptor = FetchDescriptor<History>(
            sortBy: [SortDescriptor(\.lastAccessedAt, order: .forward)]
        )
        return try modelContext.fetch(descriptor)
            .filter { $0.urlString == urlString }
            .flatMap(\.visitRecords)
            .sorted { $0.visitedAt < $1.visitedAt }
            .map { visit in
                [
                    "id": historyItemIdentifier(for: urlString),
                    "visitId": visit.id.uuidString,
                    "visitTime": milliseconds(visit.visitedAt),
                    "referringVisitId": visit.referringVisitID?.uuidString ?? "0",
                    "transition": visit.transition
                ]
            }
    }

    private static func addURL(
        arguments: [Any],
        tabManager: TabManager
    ) throws -> Any {
        guard let details = arguments.first as? [String: Any],
              let urlString = details["url"] as? String,
              let url = URL(string: urlString)
        else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "browser.history.addUrl requires a valid URL."
            )
        }
        guard let container = tabManager.activeContainer else {
            throw MozillaNativeAPIBridge.BridgeError.unavailableBrowserWindow
        }

        let title = details["title"] as? String ?? url.host ?? url.absoluteString
        let transition = details["transition"] as? String ?? "link"
        let visitDate = date(milliseconds: details["visitTime"]) ?? Date()
        let existing = try historyEntry(
            for: url,
            container: container,
            modelContext: tabManager.modelContext
        )
        let visitCount = try appendVisit(
            to: existing,
            url: url,
            title: title,
            transition: transition,
            visitDate: visitDate,
            container: container,
            modelContext: tabManager.modelContext
        )
        try tabManager.modelContext.save()

        let item = historyItem(
            id: historyItemIdentifier(for: urlString),
            url: urlString,
            title: title,
            lastVisitTime: visitDate,
            visitCount: visitCount
        )
        MozillaNativeAPIBridge.shared.emit(
            namespace: "history",
            event: "onVisited",
            arguments: [item]
        )
        return NSNull()
    }

    private static func appendVisit(
        to history: History?,
        url: URL,
        title: String,
        transition: String,
        visitDate: Date,
        container: TabContainer,
        modelContext: ModelContext
    ) throws -> Int {
        if let history {
            history.title = title
            _ = history.appendVisit(
                at: visitDate,
                transition: transition,
                referringVisitID: nil
            )
            return history.visitCount
        }

        let faviconURL = FaviconService.shared.faviconURL(for: url.host ?? "") ?? url
        let visit = HistoryVisitRecord(
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
        return 1
    }

    private static func deleteURL(
        arguments: [Any],
        modelContext: ModelContext
    ) throws -> Any {
        guard let details = arguments.first as? [String: Any],
              let urlString = details["url"] as? String
        else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "browser.history.deleteUrl requires a URL."
            )
        }
        let descriptor = FetchDescriptor<History>()
        let matches = try modelContext.fetch(descriptor).filter { $0.urlString == urlString }
        for history in matches {
            modelContext.delete(history)
        }
        try modelContext.save()
        if !matches.isEmpty {
            emitRemoval(allHistory: false, urls: [urlString])
        }
        return NSNull()
    }

    private static func deleteRange(
        arguments: [Any],
        modelContext: ModelContext
    ) throws -> Any {
        guard let range = arguments.first as? [String: Any],
              let startTime = date(milliseconds: range["startTime"]),
              let endTime = date(milliseconds: range["endTime"])
        else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "browser.history.deleteRange requires startTime and endTime."
            )
        }

        let descriptor = FetchDescriptor<History>()
        var removedURLs: [String] = []
        for history in try modelContext.fetch(descriptor) {
            if removeVisits(in: history, from: startTime, through: endTime) {
                removedURLs.append(history.urlString)
                modelContext.delete(history)
            }
        }
        try modelContext.save()
        if !removedURLs.isEmpty {
            emitRemoval(allHistory: false, urls: Array(Set(removedURLs)))
        }
        return NSNull()
    }

    private static func removeVisits(
        in history: History,
        from startTime: Date,
        through endTime: Date
    ) -> Bool {
        let originalRecords = history.visitRecords
        let retained = originalRecords.filter { visit in
            visit.visitedAt < startTime || visit.visitedAt > endTime
        }
        let removedCount = originalRecords.count - retained.count
        guard removedCount > 0 else { return false }

        history.visitRecords = retained
        history.visitCount = max(0, history.visitCount - removedCount)
        guard history.visitCount > 0 else { return true }
        if let latest = retained.max(by: { $0.visitedAt < $1.visitedAt }) {
            history.lastAccessedAt = latest.visitedAt
        }
        return false
    }

    private static func deleteAll(modelContext: ModelContext) throws -> Any {
        let descriptor = FetchDescriptor<History>()
        for history in try modelContext.fetch(descriptor) {
            modelContext.delete(history)
        }
        try modelContext.save()
        emitRemoval(allHistory: true, urls: [])
        return NSNull()
    }

    private static func emitRemoval(allHistory: Bool, urls: [String]) {
        MozillaNativeAPIBridge.shared.emit(
            namespace: "history",
            event: "onVisitRemoved",
            arguments: [["allHistory": allHistory, "urls": urls]]
        )
    }

    private static func tabManager(for context: WKWebExtensionContext) throws -> TabManager {
        if let focused = context.focusedWindow as? OraWebExtensionWindow,
           let tabManager = focused.tabManager
        {
            return tabManager
        }
        for window in context.openWindows {
            if let window = window as? OraWebExtensionWindow,
               let tabManager = window.tabManager
            {
                return tabManager
            }
        }
        throw MozillaNativeAPIBridge.BridgeError.unavailableBrowserWindow
    }

    private static func historyEntry(
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

    private static func mergeHistoryItems(_ histories: [History]) -> [[String: Any]] {
        Dictionary(grouping: histories, by: \.urlString).values.compactMap { entries in
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

    private static func historyItem(
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

    private static func historyItemIdentifier(for url: String) -> String {
        let digest = SHA256.hash(data: Data(url.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func milliseconds(_ date: Date) -> Double {
        date.timeIntervalSince1970 * 1_000
    }

    private static func date(milliseconds value: Any?) -> Date? {
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue / 1_000)
        }
        if let value = value as? Double {
            return Date(timeIntervalSince1970: value / 1_000)
        }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        return value as? Int
    }
}
