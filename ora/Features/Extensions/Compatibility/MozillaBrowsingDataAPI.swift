import Foundation
import SwiftData

@MainActor
enum MozillaBrowsingDataAPI {
    static func handle(
        method: String,
        arguments: [Any],
        context: WKWebExtensionContext
    ) async throws -> Any {
        let tabManager = try tabManager(for: context)

        switch method {
        case "settings":
            return settingsResult()
        case "remove":
            let options = arguments.first as? [String: Any] ?? [:]
            let dataTypes = arguments.dropFirst().first as? [String: Any] ?? [:]
            try await remove(dataTypes: dataTypes, options: options, tabManager: tabManager)
            return NSNull()
        case "removeCache":
            try await remove(dataTypes: ["cache": true], options: firstOptions(arguments), tabManager: tabManager)
            return NSNull()
        case "removeCookies":
            try await remove(dataTypes: ["cookies": true], options: firstOptions(arguments), tabManager: tabManager)
            return NSNull()
        case "removeDownloads":
            try await remove(dataTypes: ["downloads": true], options: firstOptions(arguments), tabManager: tabManager)
            return NSNull()
        case "removeFormData":
            // Ora does not persist a general-purpose form-autofill database. There is
            // therefore no form data to remove beyond passwords, which Firefox exposes
            // separately through removePasswords.
            return NSNull()
        case "removeHistory":
            try await remove(dataTypes: ["history": true], options: firstOptions(arguments), tabManager: tabManager)
            return NSNull()
        case "removeLocalStorage":
            try await remove(dataTypes: ["localStorage": true], options: firstOptions(arguments), tabManager: tabManager)
            return NSNull()
        case "removePluginData":
            // Ora has no NPAPI/plugin data store.
            return NSNull()
        case "removePasswords":
            try await remove(dataTypes: ["passwords": true], options: firstOptions(arguments), tabManager: tabManager)
            return NSNull()
        default:
            throw MozillaNativeAPIBridge.BridgeError.unsupportedMethod("browsingData", method)
        }
    }

    private static func firstOptions(_ arguments: [Any]) -> [String: Any] {
        arguments.first as? [String: Any] ?? [:]
    }

    private static func settingsResult() -> [String: Any] {
        let supported = dataTypeSet(defaultValue: true)
        let selected = dataTypeSet(defaultValue: false)
        return [
            "options": ["since": 0.0],
            "dataToRemove": selected,
            "dataRemovalPermitted": supported
        ]
    }

    private static func dataTypeSet(defaultValue: Bool) -> [String: Bool] {
        [
            "cache": defaultValue,
            "cookies": defaultValue,
            "downloads": defaultValue,
            "formData": defaultValue,
            "history": defaultValue,
            "indexedDB": defaultValue,
            "localStorage": defaultValue,
            "serverBoundCertificates": false,
            "passwords": defaultValue,
            "pluginData": defaultValue,
            "serviceWorkers": defaultValue
        ]
    }

    private static func remove(
        dataTypes: [String: Any],
        options: [String: Any],
        tabManager: TabManager
    ) async throws {
        let since = date(milliseconds: options["since"]) ?? .distantPast
        let hostnames = options["hostnames"] as? [String] ?? []
        let selectedContainerID = try containerID(from: options["cookieStoreId"] as? String, tabManager: tabManager)

        let websiteTypes = websiteDataTypes(from: dataTypes)
        if !websiteTypes.isEmpty {
            try await clearWebsiteData(
                types: websiteTypes,
                since: since,
                hostnames: hostnames,
                selectedContainerID: selectedContainerID,
                tabManager: tabManager
            )
        }

        if dataTypes["history"] as? Bool == true {
            try clearHistory(since: since, containerID: selectedContainerID, tabManager: tabManager)
        }
        if dataTypes["downloads"] as? Bool == true {
            try clearDownloads(since: since, containerID: selectedContainerID, tabManager: tabManager)
        }
        if dataTypes["passwords"] as? Bool == true {
            try clearPasswords(since: since, containerID: selectedContainerID)
        }

        // Ora does not persist generic form autofill or browser plug-in data. A true
        // value for those types is therefore already satisfied without deleting data
        // from an unrelated store.
    }

    private static func websiteDataTypes(from dataTypes: [String: Any]) -> Set<BrowserWebsiteDataType> {
        var result: Set<BrowserWebsiteDataType> = []
        if dataTypes["cache"] as? Bool == true {
            result.insert(.cache)
        }
        if dataTypes["cookies"] as? Bool == true {
            result.insert(.cookies)
        }
        if dataTypes["localStorage"] as? Bool == true {
            result.insert(.localStorage)
        }
        if dataTypes["indexedDB"] as? Bool == true {
            result.insert(.indexedDB)
        }
        if dataTypes["serviceWorkers"] as? Bool == true {
            result.insert(.serviceWorkers)
        }
        return result
    }

    private static func clearWebsiteData(
        types: Set<BrowserWebsiteDataType>,
        since: Date,
        hostnames: [String],
        selectedContainerID: UUID?,
        tabManager: TabManager
    ) async throws {
        let hasHostScopedType = types.contains(.cookies) || types.contains(.localStorage)
        if !hostnames.isEmpty, hasHostScopedType, since > .distantPast {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "Ora cannot safely combine browsingData hostnames with a since filter for WebKit cookie/local-storage records without deleting older matching data."
            )
        }

        let containers: [TabContainer]
        if let selectedContainerID {
            containers = tabManager.containers.filter { $0.id == selectedContainerID }
        } else {
            containers = tabManager.containers
        }

        for container in containers {
            let profile = BrowserEngine.shared.makeProfile(identifier: container.id, isPrivate: false)
            if hostnames.isEmpty {
                let effectiveSince = types.contains(.cache) ? Date.distantPast : since
                await clear(profile: profile, types: types, since: effectiveSince, host: nil)
            } else {
                let hostScopedTypes = types.intersection([.cookies, .localStorage])
                let unscopedTypes = types.subtracting(hostScopedTypes)
                for hostname in hostnames where !hostScopedTypes.isEmpty {
                    await clear(
                        profile: profile,
                        types: hostScopedTypes,
                        since: .distantPast,
                        host: hostname
                    )
                }
                if !unscopedTypes.isEmpty {
                    let effectiveSince = unscopedTypes.contains(.cache) ? Date.distantPast : since
                    await clear(profile: profile, types: unscopedTypes, since: effectiveSince, host: nil)
                }
            }
        }
    }

    private static func clear(
        profile: BrowserEngineProfile,
        types: Set<BrowserWebsiteDataType>,
        since: Date,
        host: String?
    ) async {
        await withCheckedContinuation { continuation in
            profile.clearData(ofTypes: types, modifiedSince: since, forHost: host) {
                continuation.resume()
            }
        }
    }

    private static func clearHistory(
        since: Date,
        containerID: UUID?,
        tabManager: TabManager
    ) throws {
        let descriptor = FetchDescriptor<History>()
        let histories = try tabManager.modelContext.fetch(descriptor)
        var completelyRemovedURLs = Set<String>()

        for history in histories {
            if let containerID, history.container?.id != containerID {
                continue
            }

            let records = history.visitRecords
            if records.isEmpty {
                if history.lastAccessedAt >= since {
                    completelyRemovedURLs.insert(history.urlString)
                    tabManager.modelContext.delete(history)
                }
                continue
            }

            let kept = records.filter { $0.visitedAt < since }
            let removedCount = records.count - kept.count
            guard removedCount > 0 else { continue }

            history.visitRecords = kept
            history.visitCount = max(0, history.visitCount - removedCount)
            if history.visitCount == 0 || kept.isEmpty {
                completelyRemovedURLs.insert(history.urlString)
                tabManager.modelContext.delete(history)
            } else if let latest = kept.max(by: { $0.visitedAt < $1.visitedAt }) {
                history.lastAccessedAt = latest.visitedAt
            }
        }

        try tabManager.modelContext.save()
        if !completelyRemovedURLs.isEmpty {
            MozillaNativeAPIBridge.shared.emit(
                namespace: "history",
                event: "onVisitRemoved",
                arguments: [["allHistory": since == .distantPast && containerID == nil, "urls": Array(completelyRemovedURLs)]]
            )
        }
    }

    private static func clearDownloads(
        since: Date,
        containerID: UUID?,
        tabManager: TabManager
    ) throws {
        guard containerID == nil else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "Ora's current download records are not space-scoped, so browsingData cannot safely apply cookieStoreId to downloads."
            )
        }

        let descriptor = FetchDescriptor<Download>()
        for download in try tabManager.modelContext.fetch(descriptor) where download.createdAt >= since {
            tabManager.modelContext.delete(download)
        }
        try tabManager.modelContext.save()
    }

    private static func clearPasswords(since: Date, containerID: UUID?) throws {
        let service = PasswordManagerService.shared
        let candidates = service.entries(for: containerID).filter { entry in
            max(entry.createdAt, entry.updatedAt) >= since
        }
        for entry in candidates {
            try service.delete(entry)
        }
    }

    static func cookieStoreID(for containerID: UUID) -> String {
        "firefox-container-\(containerID.uuidString.lowercased())"
    }

    static func containerID(from cookieStoreID: String?, tabManager: TabManager) throws -> UUID? {
        guard let cookieStoreID, !cookieStoreID.isEmpty else { return nil }
        let prefix = "firefox-container-"
        guard cookieStoreID.hasPrefix(prefix),
              let id = UUID(uuidString: String(cookieStoreID.dropFirst(prefix.count))),
              tabManager.containers.contains(where: { $0.id == id })
        else {
            throw MozillaNativeAPIBridge.BridgeError.itemNotFound(
                "No Ora space matches cookieStoreId \(cookieStoreID)."
            )
        }
        return id
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

    private static func date(milliseconds value: Any?) -> Date? {
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue / 1_000)
        }
        if let value = value as? Double {
            return Date(timeIntervalSince1970: value / 1_000)
        }
        return nil
    }
}
