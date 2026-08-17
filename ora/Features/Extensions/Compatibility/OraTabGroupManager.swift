import Foundation

@MainActor
final class OraTabGroupManager {
    private struct Group: Codable {
        let id: Int
        let spaceID: UUID
        var title: String?
        var color: String
        var collapsed: Bool
        var shared: Bool
        var windowID: Int
        var tabIDs: [UUID]
    }

    static let shared = OraTabGroupManager()

    private let defaultsKey = "webExtensions.tabGroups.v1"
    private var groups: [Int: Group] = [:]
    private var nextGroupID = 1

    private init() {
        restore()
    }

    func handleTabs(method: String, args: [Any], spaceID: UUID) throws -> Any? {
        switch method {
        case "group":
            let options = args.first as? [String: Any] ?? [:]
            let tabs = try resolveTabs(from: options["__oraTabs"], spaceID: spaceID)
            guard !tabs.isEmpty else {
                throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("tabs.group requires at least one Ora tab.")
            }

            let groupID: Int
            let isNewGroup: Bool
            if let requested = (options["groupId"] as? NSNumber)?.intValue {
                guard let existing = groups[requested], existing.spaceID == spaceID else {
                    throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("The requested tab group does not exist.")
                }
                groupID = requested
                isNewGroup = false
            } else {
                groupID = nextGroupID
                nextGroupID += 1
                let metadata = (options["__oraTabs"] as? [[String: Any]])?.first
                let windowID = (metadata?["windowId"] as? NSNumber)?.intValue ?? tabs.first?.pageWindow?.windowNumber ?? -1
                groups[groupID] = Group(
                    id: groupID,
                    spaceID: spaceID,
                    title: nil,
                    color: "grey",
                    collapsed: false,
                    shared: false,
                    windowID: windowID,
                    tabIDs: []
                )
                isNewGroup = true
            }

            removeTabsFromOtherGroups(tabs, except: groupID)
            guard var group = groups[groupID] else {
                throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("The tab group no longer exists.")
            }
            for tab in tabs where !group.tabIDs.contains(tab.id) {
                group.tabIDs.append(tab.id)
            }
            groups[groupID] = group
            cleanupEmptyGroups(spaceID: spaceID)
            persist()

            if isNewGroup {
                OraChromeExtensionAPIHost.shared.emit(
                    namespace: "tabGroups",
                    event: "onCreated",
                    args: [groupDictionary(group, spaceID: spaceID)],
                    spaceID: spaceID
                )
            }
            return groupID

        case "ungroup":
            let details = args.first as? [String: Any] ?? [:]
            let tabs = try resolveTabs(from: details["__oraTabs"], spaceID: spaceID)
            for tab in tabs {
                for groupID in groups.keys {
                    guard var group = groups[groupID], group.spaceID == spaceID else { continue }
                    group.tabIDs.removeAll { $0 == tab.id }
                    groups[groupID] = group
                }
            }
            cleanupEmptyGroups(spaceID: spaceID)
            persist()
            return nil

        case "__oraGetGroupId":
            let details = args.first as? [String: Any] ?? [:]
            guard let tab = try OraChromeExtensionAPIHost.shared.resolveOraTab(
                from: details["__oraTab"],
                spaceID: spaceID
            ) else {
                return -1
            }
            return groupID(for: tab.id, spaceID: spaceID) ?? -1

        default:
            throw OraChromeExtensionAPIHost.BridgeError.unsupportedMethod("tabs", method)
        }
    }

    func handleTabGroups(method: String, args: [Any], spaceID: UUID) throws -> Any? {
        switch method {
        case "get":
            guard let groupID = (args.first as? NSNumber)?.intValue,
                  let group = groups[groupID], group.spaceID == spaceID
            else {
                throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("tabGroups.get requires an existing group ID.")
            }
            return groupDictionary(group, spaceID: spaceID)

        case "query":
            let query = args.first as? [String: Any] ?? [:]
            cleanupOrphanedTabs(spaceID: spaceID)
            return groups.values
                .filter { $0.spaceID == spaceID }
                .filter { groupMatchesQuery($0, query: query) }
                .sorted { $0.id < $1.id }
                .map { groupDictionary($0, spaceID: spaceID) }

        case "update":
            guard let groupID = (args.first as? NSNumber)?.intValue,
                  var group = groups[groupID], group.spaceID == spaceID
            else {
                throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("tabGroups.update requires an existing group ID.")
            }
            let properties = args.count > 1 ? (args[1] as? [String: Any] ?? [:]) : [:]
            if let collapsed = properties["collapsed"] as? Bool { group.collapsed = collapsed }
            if let title = properties["title"] as? String { group.title = title }
            if let color = properties["color"] as? String {
                guard Self.validColors.contains(color) else {
                    throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("Unknown tab group color: \(color).")
                }
                group.color = color
            }
            groups[groupID] = group
            persist()
            let value = groupDictionary(group, spaceID: spaceID)
            OraChromeExtensionAPIHost.shared.emit(
                namespace: "tabGroups",
                event: "onUpdated",
                args: [value],
                spaceID: spaceID
            )
            return value

        case "move":
            guard let groupID = (args.first as? NSNumber)?.intValue,
                  var group = groups[groupID], group.spaceID == spaceID
            else {
                throw OraChromeExtensionAPIHost.BridgeError.invalidArguments("tabGroups.move requires an existing group ID.")
            }
            let properties = args.count > 1 ? (args[1] as? [String: Any] ?? [:]) : [:]
            if let requestedWindowID = (properties["windowId"] as? NSNumber)?.intValue,
               requestedWindowID != -2,
               requestedWindowID != group.windowID
            {
                throw OraChromeExtensionAPIHost.BridgeError.unsupportedMethod(
                    "tabGroups",
                    "move across Ora windows"
                )
            }

            let manager = try OraChromeExtensionAPIHost.shared.tabManager(for: spaceID)
            guard let container = manager.containers.first(where: { $0.id == spaceID }) else { return nil }
            let allTabs = container.tabs.sorted { $0.order < $1.order }
            let groupedTabs = allTabs.filter { group.tabIDs.contains($0.id) }
            var remaining = allTabs.filter { !group.tabIDs.contains($0.id) }
            let requestedIndex = (properties["index"] as? NSNumber)?.intValue ?? -1
            let insertionIndex = requestedIndex < 0 ? remaining.count : min(max(requestedIndex, 0), remaining.count)
            remaining.insert(contentsOf: groupedTabs, at: insertionIndex)
            for (index, tab) in remaining.enumerated() { tab.order = index }
            try? manager.modelContext.save()
            group.tabIDs = groupedTabs.map(\.id)
            groups[groupID] = group
            persist()

            let value = groupDictionary(group, spaceID: spaceID)
            OraChromeExtensionAPIHost.shared.emit(
                namespace: "tabGroups",
                event: "onMoved",
                args: [value],
                spaceID: spaceID
            )
            return value

        default:
            throw OraChromeExtensionAPIHost.BridgeError.unsupportedMethod("tabGroups", method)
        }
    }

    func groupID(for tabID: UUID, spaceID: UUID) -> Int? {
        groups.values.first(where: { $0.spaceID == spaceID && $0.tabIDs.contains(tabID) })?.id
    }

    private func resolveTabs(from rawValue: Any?, spaceID: UUID) throws -> [Tab] {
        let metadataValues = rawValue as? [[String: Any]] ?? []
        var result: [Tab] = []
        for metadata in metadataValues {
            if let tab = try OraChromeExtensionAPIHost.shared.resolveOraTab(from: metadata, spaceID: spaceID),
               !result.contains(where: { $0.id == tab.id })
            {
                result.append(tab)
            }
        }
        return result
    }

    private func removeTabsFromOtherGroups(_ tabs: [Tab], except targetGroupID: Int) {
        let tabIDs = Set(tabs.map(\.id))
        for groupID in groups.keys where groupID != targetGroupID {
            guard var group = groups[groupID] else { continue }
            group.tabIDs.removeAll { tabIDs.contains($0) }
            groups[groupID] = group
        }
    }

    private func cleanupEmptyGroups(spaceID: UUID) {
        let emptyIDs = groups.values.filter { $0.spaceID == spaceID && $0.tabIDs.isEmpty }.map(\.id)
        for groupID in emptyIDs {
            guard let group = groups.removeValue(forKey: groupID) else { continue }
            OraChromeExtensionAPIHost.shared.emit(
                namespace: "tabGroups",
                event: "onRemoved",
                args: [groupDictionary(group, spaceID: spaceID)],
                spaceID: spaceID
            )
        }
    }

    private func cleanupOrphanedTabs(spaceID: UUID) {
        guard let manager = try? OraChromeExtensionAPIHost.shared.tabManager(for: spaceID),
              let container = manager.containers.first(where: { $0.id == spaceID })
        else { return }
        let validIDs = Set(container.tabs.map(\.id))
        for groupID in groups.keys {
            guard var group = groups[groupID], group.spaceID == spaceID else { continue }
            group.tabIDs.removeAll { !validIDs.contains($0) }
            groups[groupID] = group
        }
        cleanupEmptyGroups(spaceID: spaceID)
        persist()
    }

    private func groupDictionary(_ group: Group, spaceID: UUID) -> [String: Any] {
        [
            "id": group.id,
            "collapsed": group.collapsed,
            "color": group.color,
            "title": group.title ?? NSNull(),
            "windowId": group.windowID,
            "shared": group.shared
        ]
    }

    private func groupMatchesQuery(_ group: Group, query: [String: Any]) -> Bool {
        if let collapsed = query["collapsed"] as? Bool, collapsed != group.collapsed { return false }
        if let color = query["color"] as? String, color != group.color { return false }
        if let shared = query["shared"] as? Bool, shared != group.shared { return false }
        if let windowID = (query["windowId"] as? NSNumber)?.intValue,
           windowID != -2, windowID != group.windowID
        {
            return false
        }
        if let titlePattern = query["title"] as? String,
           !matchesPattern(group.title ?? "", pattern: titlePattern)
        {
            return false
        }
        return true
    }

    private func matchesPattern(_ value: String, pattern: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        guard let regex = try? NSRegularExpression(pattern: "^\(escaped)$", options: [.caseInsensitive]) else {
            return value.localizedCaseInsensitiveContains(pattern)
        }
        let range = NSRange(value.startIndex ..< value.endIndex, in: value)
        return regex.firstMatch(in: value, range: range) != nil
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Int: Group].self, from: data)
        else { return }
        groups = decoded
        nextGroupID = max((groups.keys.max() ?? 0) + 1, 1)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private static let validColors: Set<String> = [
        "grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"
    ]
}
