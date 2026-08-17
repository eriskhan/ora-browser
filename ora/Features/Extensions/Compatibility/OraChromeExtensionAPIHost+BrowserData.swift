import AppKit
import Foundation
import SwiftData
@preconcurrency import WebKit

extension OraChromeExtensionAPIHost {
    func handleHistory(method: String, args: [Any], spaceID: UUID) throws -> Any? {
        let manager = try tabManager(for: spaceID)
        let context = manager.modelContext
        let histories = try historyEntries(in: context, spaceID: spaceID)

        switch method {
        case "search":
            let query = dictionaryArgument(args)
            let text = (query["text"] as? String ?? "").lowercased()
            let startTime = millisecondsDate(query["startTime"])
            let endTime = millisecondsDate(query["endTime"])
            let maxResults = (query["maxResults"] as? NSNumber)?.intValue ?? 100
            return histories
                .filter { history in
                    (text.isEmpty || history.title.lowercased().contains(text) || history.urlString.lowercased().contains(text)) &&
                        (startTime == nil || history.lastAccessedAt >= startTime!) &&
                        (endTime == nil || history.lastAccessedAt <= endTime!)
                }
                .prefix(max(0, maxResults))
                .map(historyDictionary)

        case "getVisits":
            let details = dictionaryArgument(args)
            guard let url = details["url"] as? String else {
                throw BridgeError.invalidArguments("history.getVisits requires a URL.")
            }
            return histories.filter { $0.urlString == url }.map { history in
                [
                    "id": history.id.uuidString,
                    "visitId": history.id.uuidString,
                    "visitTime": milliseconds(history.lastAccessedAt),
                    "referringVisitId": "0",
                    "transition": "link",
                    "isLocal": true
                ] as [String: Any]
            }

        case "addUrl":
            let details = dictionaryArgument(args)
            guard let rawURL = details["url"] as? String, let url = URL(string: rawURL),
                  let container = manager.containers.first(where: { $0.id == spaceID })
            else {
                throw BridgeError.invalidArguments("history.addUrl requires a valid URL.")
            }
            let historyManager = HistoryManager(modelContainer: manager.modelContainer, modelContext: context)
            historyManager.record(title: url.host ?? rawURL, url: url, container: container)
            if let created = try historyEntries(in: context, spaceID: spaceID).first(where: { $0.urlString == rawURL }) {
                emit(namespace: "history", event: "onVisited", args: [historyDictionary(created)], spaceID: spaceID)
            }
            return nil

        case "deleteUrl":
            let details = dictionaryArgument(args)
            guard let rawURL = details["url"] as? String else {
                throw BridgeError.invalidArguments("history.deleteUrl requires a URL.")
            }
            for history in histories where history.urlString == rawURL {
                context.delete(history)
            }
            try context.save()
            emit(namespace: "history", event: "onVisitRemoved", args: [["allHistory": false, "urls": [rawURL]]], spaceID: spaceID)
            return nil

        case "deleteRange":
            let details = dictionaryArgument(args)
            guard let start = millisecondsDate(details["startTime"]),
                  let end = millisecondsDate(details["endTime"])
            else {
                throw BridgeError.invalidArguments("history.deleteRange requires startTime and endTime.")
            }
            let removed = histories.filter { $0.lastAccessedAt >= start && $0.lastAccessedAt <= end }
            for history in removed { context.delete(history) }
            try context.save()
            let urls = removed.map(\.urlString)
            if !urls.isEmpty {
                emit(namespace: "history", event: "onVisitRemoved", args: [["allHistory": false, "urls": urls]], spaceID: spaceID)
            }
            return nil

        case "deleteAll":
            guard let container = manager.containers.first(where: { $0.id == spaceID }) else { return nil }
            HistoryManager(modelContainer: manager.modelContainer, modelContext: context).clearContainerHistory(container)
            emit(namespace: "history", event: "onVisitRemoved", args: [["allHistory": true, "urls": []]], spaceID: spaceID)
            return nil

        default:
            throw BridgeError.unsupportedMethod("history", method)
        }
    }

    func handleBrowsingData(method: String, args: [Any], spaceID: UUID) async throws -> Any? {
        let options = dictionaryArgument(args)
        let since = millisecondsDate(options["since"]) ?? .distantPast
        var requestedTypes: Set<String> = []

        if method == "settings" {
            let supported = [
                "appcache", "cache", "cacheStorage", "cookies", "downloads", "fileSystems", "formData", "history",
                "indexedDB", "localStorage", "passwords", "serviceWorkers", "webSQL"
            ]
            return [
                "options": ["since": 0, "originTypes": ["unprotectedWeb": true, "protectedWeb": true, "extension": false]],
                "dataToRemove": Dictionary(uniqueKeysWithValues: supported.map { ($0, true) }),
                "dataRemovalPermitted": Dictionary(uniqueKeysWithValues: supported.map { ($0, true) })
            ] as [String: Any]
        }

        if method == "remove" {
            let dataToRemove = dictionaryArgument(args, at: 1)
            requestedTypes = Set(dataToRemove.compactMap { key, value in
                (value as? Bool) == true ? key : nil
            })
        } else if method.hasPrefix("remove") {
            let suffix = String(method.dropFirst("remove".count))
            let key = suffix.prefix(1).lowercased() + suffix.dropFirst()
            requestedTypes = [key]
        } else {
            throw BridgeError.unsupportedMethod("browsingData", method)
        }

        let profile = BrowserEngine.shared.makeProfile(identifier: spaceID, isPrivate: false)
        let websiteTypes = websiteDataTypes(for: requestedTypes)
        if !websiteTypes.isEmpty {
            await withCheckedContinuation { continuation in
                profile.dataStore.removeData(ofTypes: websiteTypes, modifiedSince: since) {
                    continuation.resume()
                }
            }
        }

        if requestedTypes.contains("history") {
            let manager = try tabManager(for: spaceID)
            let entries = try historyEntries(in: manager.modelContext, spaceID: spaceID)
            for history in entries where history.lastAccessedAt >= since {
                manager.modelContext.delete(history)
            }
            try manager.modelContext.save()
            emit(namespace: "history", event: "onVisitRemoved", args: [["allHistory": since == .distantPast, "urls": []]], spaceID: spaceID)
        }
        return nil
    }

    func handleManagement(
        method: String,
        args: [Any],
        spaceID: UUID,
        context: WKWebExtensionContext
    ) async throws -> Any? {
        let extensionManager = WebExtensionManager.shared

        switch method {
        case "getAll":
            return extensionManager.installedExtensions.map { managementDictionary($0, spaceID: spaceID) }
        case "getSelf":
            guard let current = extensionManager.installedExtension(for: context) else { return NSNull() }
            return managementDictionary(current, spaceID: spaceID)
        case "get":
            guard let identifier = stringArgument(args, at: 0),
                  let target = managedExtension(identifier: identifier)
            else {
                throw BridgeError.invalidArguments("management.get requires an installed extension ID.")
            }
            return managementDictionary(target, spaceID: spaceID)
        case "setEnabled":
            guard let identifier = stringArgument(args, at: 0),
                  let enabled = numberArgument(args, at: 1)?.boolValue,
                  let target = managedExtension(identifier: identifier)
            else {
                throw BridgeError.invalidArguments("management.setEnabled requires an extension ID and enabled state.")
            }
            try await extensionManager.setEnabled(enabled, extensionID: target.id, in: spaceID)
            emit(
                namespace: "management",
                event: enabled ? "onEnabled" : "onDisabled",
                args: [managementDictionary(target, spaceID: spaceID)],
                spaceID: spaceID
            )
            return nil
        case "uninstall":
            guard let identifier = stringArgument(args, at: 0), let target = managedExtension(identifier: identifier) else {
                throw BridgeError.invalidArguments("management.uninstall requires an extension ID.")
            }
            let eventValue = managementDictionary(target, spaceID: spaceID)
            extensionManager.removeExtension(target.id)
            emit(namespace: "management", event: "onUninstalled", args: [target.runtimeIdentifier], spaceID: spaceID)
            _ = eventValue
            return nil
        case "uninstallSelf":
            guard let current = extensionManager.installedExtension(for: context) else { return nil }
            extensionManager.removeExtension(current.id)
            emit(namespace: "management", event: "onUninstalled", args: [current.runtimeIdentifier], spaceID: spaceID)
            return nil
        case "getPermissionWarningsById", "getPermissionWarningsByManifest":
            return []
        default:
            throw BridgeError.unsupportedMethod("management", method)
        }
    }

    func handleSearch(method: String, args: [Any], spaceID: UUID) throws -> Any? {
        guard method == "query" else { throw BridgeError.unsupportedMethod("search", method) }
        let info = dictionaryArgument(args)
        guard let text = info["text"] as? String else {
            throw BridgeError.invalidArguments("search.query requires text.")
        }
        let manager = try tabManager(for: spaceID)
        let service = SearchEngineService()
        guard let engine = service.getDefaultSearchEngine(for: spaceID),
              let url = service.createSearchURL(for: engine, query: text)
        else {
            throw BridgeError.invalidArguments("Ora could not resolve the active search engine.")
        }

        let disposition = (info["disposition"] as? String ?? "CURRENT_TAB").uppercased()
        if disposition == "CURRENT_TAB", let activeTab = manager.activeTab {
            activeTab.loadURL(url.absoluteString)
        } else {
            let historyManager = HistoryManager(modelContainer: manager.modelContainer, modelContext: manager.modelContext)
            _ = manager.openTab(url: url, historyManager: historyManager, isPrivate: false)
        }
        return nil
    }

    func handleSessions(method: String, args: [Any], spaceID: UUID) throws -> Any? {
        let manager = try tabManager(for: spaceID)
        switch method {
        case "getRecentlyClosed":
            return []
        case "getDevices":
            let tabs = manager.containers
                .first(where: { $0.id == spaceID })?.tabs
                .sorted { $0.order < $1.order }
                .map { ["sessionId": $0.id.uuidString, "tab": sessionTabDictionary($0)] as [String: Any] } ?? []
            return [[
                "deviceName": Host.current().localizedName ?? "This Mac",
                "sessions": tabs
            ]] as [[String: Any]]
        case "restore":
            throw BridgeError.unsupportedMethod("sessions", method)
        default:
            throw BridgeError.unsupportedMethod("sessions", method)
        }
    }

    func handleTopSites(method: String, spaceID: UUID) throws -> Any? {
        guard method == "get" else { throw BridgeError.unsupportedMethod("topSites", method) }
        let manager = try tabManager(for: spaceID)
        let entries = try historyEntries(in: manager.modelContext, spaceID: spaceID)
        return entries
            .sorted {
                if $0.visitCount == $1.visitCount { return $0.lastAccessedAt > $1.lastAccessedAt }
                return $0.visitCount > $1.visitCount
            }
            .prefix(20)
            .map { ["url": $0.urlString, "title": $0.title] }
    }

    func handleReadingList(method: String, args: [Any]) throws -> Any? {
        var entries = loadReadingList()
        switch method {
        case "addEntry":
            let details = dictionaryArgument(args)
            guard let url = details["url"] as? String else {
                throw BridgeError.invalidArguments("readingList.addEntry requires a URL.")
            }
            let title = details["title"] as? String ?? url
            let hasBeenRead = details["hasBeenRead"] as? Bool ?? false
            entries.removeAll { $0.url == url }
            let entry = ReadingListBridgeEntry(url: url, title: title, hasBeenRead: hasBeenRead, creationTime: Date())
            entries.append(entry)
            saveReadingList(entries)
            emit(namespace: "readingList", event: "onEntryAdded", args: [entry.dictionary()])
            return nil
        case "removeEntry":
            let details = dictionaryArgument(args)
            guard let url = details["url"] as? String else {
                throw BridgeError.invalidArguments("readingList.removeEntry requires a URL.")
            }
            entries.removeAll { $0.url == url }
            saveReadingList(entries)
            emit(namespace: "readingList", event: "onEntryRemoved", args: [["url": url]])
            return nil
        case "updateEntry":
            let details = dictionaryArgument(args)
            guard let url = details["url"] as? String,
                  let index = entries.firstIndex(where: { $0.url == url })
            else {
                throw BridgeError.invalidArguments("readingList.updateEntry requires an existing URL.")
            }
            if let title = details["title"] as? String { entries[index].title = title }
            if let hasBeenRead = details["hasBeenRead"] as? Bool { entries[index].hasBeenRead = hasBeenRead }
            saveReadingList(entries)
            emit(namespace: "readingList", event: "onEntryUpdated", args: [entries[index].dictionary()])
            return nil
        case "query":
            let info = dictionaryArgument(args)
            return entries.filter { entry in
                (info["url"] as? String).map { $0 == entry.url } ?? true &&
                    (info["title"] as? String).map { entry.title.localizedCaseInsensitiveContains($0) } ?? true &&
                    (info["hasBeenRead"] as? Bool).map { $0 == entry.hasBeenRead } ?? true
            }.map { $0.dictionary() }
        default:
            throw BridgeError.unsupportedMethod("readingList", method)
        }
    }

    private struct ReadingListBridgeEntry: Codable {
        var url: String
        var title: String
        var hasBeenRead: Bool
        var creationTime: Date

        func dictionary() -> [String: Any] {
            [
                "url": url,
                "title": title,
                "hasBeenRead": hasBeenRead,
                "creationTime": creationTime.timeIntervalSince1970 * 1000
            ]
        }
    }

    private func historyEntries(in context: ModelContext, spaceID: UUID) throws -> [History] {
        let descriptor = FetchDescriptor<History>(sortBy: [SortDescriptor(\.lastAccessedAt, order: .reverse)])
        return try context.fetch(descriptor).filter { $0.container?.id == spaceID }
    }

    private func historyDictionary(_ history: History) -> [String: Any] {
        [
            "id": history.id.uuidString,
            "url": history.urlString,
            "title": history.title,
            "lastVisitTime": milliseconds(history.lastAccessedAt),
            "visitCount": history.visitCount,
            "typedCount": 0
        ]
    }

    private func milliseconds(_ date: Date) -> Double {
        date.timeIntervalSince1970 * 1000
    }

    private func millisecondsDate(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue / 1000)
    }

    private func websiteDataTypes(for requested: Set<String>) -> Set<String> {
        var result: Set<String> = []
        if requested.contains("cache") {
            result.formUnion([WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache])
        }
        if requested.contains("cookies") { result.insert(WKWebsiteDataTypeCookies) }
        if requested.contains("indexedDB") { result.insert(WKWebsiteDataTypeIndexedDBDatabases) }
        if requested.contains("localStorage") { result.insert(WKWebsiteDataTypeLocalStorage) }
        if requested.contains("serviceWorkers") { result.insert(WKWebsiteDataTypeServiceWorkerRegistrations) }
        if requested.contains("webSQL") { result.insert(WKWebsiteDataTypeWebSQLDatabases) }
        return result
    }

    private func managedExtension(identifier: String) -> InstalledWebExtension? {
        WebExtensionManager.shared.installedExtensions.first {
            $0.runtimeIdentifier == identifier || $0.chromeExtensionID == identifier || $0.id.uuidString == identifier
        }
    }

    private func managementDictionary(_ extensionValue: InstalledWebExtension, spaceID: UUID) -> [String: Any] {
        [
            "id": extensionValue.runtimeIdentifier,
            "name": extensionValue.name,
            "shortName": extensionValue.name,
            "description": "",
            "version": extensionValue.version,
            "versionName": extensionValue.version,
            "mayDisable": true,
            "enabled": extensionValue.isEnabled(in: spaceID),
            "disabledReason": extensionValue.isEnabled(in: spaceID) ? "" : "unknown",
            "type": "extension",
            "installType": "normal",
            "isApp": false,
            "launchType": "OPEN_AS_REGULAR_TAB",
            "homepageUrl": "",
            "updateUrl": extensionValue.source == .chromeWebStore ? "https://clients2.google.com/service/update2/crx" : "",
            "offlineEnabled": true,
            "optionsUrl": "",
            "permissions": [],
            "hostPermissions": []
        ]
    }

    private func sessionTabDictionary(_ tab: Tab) -> [String: Any] {
        [
            "id": numericID(for: tab.id),
            "sessionId": tab.id.uuidString,
            "index": tab.order,
            "windowId": tab.pageWindow?.windowNumber ?? -1,
            "highlighted": tab.tabManager?.activeTab?.id == tab.id,
            "active": tab.tabManager?.activeTab?.id == tab.id,
            "pinned": tab.type == .pinned,
            "incognito": tab.isPrivate,
            "url": tab.url.absoluteString,
            "title": tab.title
        ]
    }

    private func numericID(for uuid: UUID) -> Int {
        let prefix = uuid.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return Int(prefix, radix: 16) ?? 0
    }

    private var readingListDefaultsKey: String { "webExtensions.readingList.v1" }

    private func loadReadingList() -> [ReadingListBridgeEntry] {
        guard let data = UserDefaults.standard.data(forKey: readingListDefaultsKey),
              let entries = try? JSONDecoder().decode([ReadingListBridgeEntry].self, from: data)
        else { return [] }
        return entries
    }

    private func saveReadingList(_ entries: [ReadingListBridgeEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: readingListDefaultsKey)
        }
    }
}
