import Foundation
import SwiftData
@preconcurrency import WebKit

@MainActor
enum MozillaTopSitesAPI {
    private struct Snapshot {
        let url: URL
        let title: String
        let faviconLocalFile: URL?
        let visitCount: Int
        let lastAccessedAt: Date
    }

    static func handle(
        method: String,
        arguments: [Any],
        context: WKWebExtensionContext
    ) throws -> Any {
        guard method == "get" else {
            throw MozillaNativeAPIBridge.BridgeError.unsupportedMethod("topSites", method)
        }

        let options = arguments.first as? [String: Any] ?? [:]
        if options["newtab"] as? Bool == true {
            return [Any]()
        }

        let limit = min(100, max(1, integer(options["limit"]) ?? 12))
        let includeFavicon = options["includeFavicon"] as? Bool ?? false
        let onePerDomain = options["onePerDomain"] as? Bool ?? true
        let tabManager = try tabManager(for: context)
        let descriptor = FetchDescriptor<History>(
            sortBy: [SortDescriptor(\.visitCount, order: .reverse)]
        )
        let snapshots = topSiteSnapshots(try tabManager.modelContext.fetch(descriptor)).sorted {
            if $0.visitCount != $1.visitCount {
                return $0.visitCount > $1.visitCount
            }
            return $0.lastAccessedAt > $1.lastAccessedAt
        }
        return makeResults(
            snapshots: snapshots,
            limit: limit,
            onePerDomain: onePerDomain,
            includeFavicon: includeFavicon
        )
    }

    private static func makeResults(
        snapshots: [Snapshot],
        limit: Int,
        onePerDomain: Bool,
        includeFavicon: Bool
    ) -> [[String: Any]] {
        var seenDomains = Set<String>()
        var results: [[String: Any]] = []
        for snapshot in snapshots {
            if onePerDomain, let host = snapshot.url.host?.lowercased() {
                guard seenDomains.insert(host).inserted else { continue }
            }

            var item: [String: Any] = [
                "url": snapshot.url.absoluteString,
                "title": snapshot.title,
                "type": "url"
            ]
            if includeFavicon,
               let faviconLocalFile = snapshot.faviconLocalFile,
               let data = try? Data(contentsOf: faviconLocalFile)
            {
                item["favicon"] = "data:image/png;base64,\(data.base64EncodedString())"
            }
            results.append(item)
            if results.count == limit { break }
        }
        return results
    }

    private static func topSiteSnapshots(_ histories: [History]) -> [Snapshot] {
        Dictionary(grouping: histories, by: \.urlString).values.compactMap { entries in
            guard let latest = entries.max(by: { $0.lastAccessedAt < $1.lastAccessedAt }) else { return nil }
            return Snapshot(
                url: latest.url,
                title: latest.title,
                faviconLocalFile: latest.faviconLocalFile,
                visitCount: entries.reduce(0) { $0 + $1.visitCount },
                lastAccessedAt: latest.lastAccessedAt
            )
        }
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

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        return value as? Int
    }
}
