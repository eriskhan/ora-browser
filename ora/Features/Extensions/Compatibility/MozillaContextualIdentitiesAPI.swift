import AppKit
import Foundation
import SwiftData
@preconcurrency import WebKit

@MainActor
enum MozillaContextualIdentitiesAPI {
    private static let colorCodes: [String: String] = [
        "blue": "#37adff",
        "cyan": "#00c79a",
        "gray": "#7c7c7d",
        "green": "#51cd00",
        "orange": "#ff9f00",
        "pink": "#ff4bda",
        "purple": "#af51f5",
        "red": "#ff613d",
        "violet": "#7542e5",
        "yellow": "#ffcb00"
    ]

    private static let iconSymbols: [String: String] = [
        "briefcase": "briefcase.fill",
        "cart": "cart.fill",
        "chill": "snowflake",
        "circle": "circle.fill",
        "dollar": "dollarsign.circle.fill",
        "fence": "rectangle.split.3x1.fill",
        "fingerprint": "touchid",
        "food": "fork.knife",
        "fruit": "leaf.fill",
        "gift": "gift.fill",
        "pet": "pawprint.fill",
        "tree": "tree.fill",
        "vacation": "airplane"
    ]

    static func handle(
        method: String,
        arguments: [Any],
        context: WKWebExtensionContext,
        manager: ExtensionManager
    ) async throws -> Any {
        guard manager.hasBridgeAccess(to: "contextualIdentities", for: context),
              manager.hasBridgeAccess(to: "cookies", for: context)
        else {
            throw MozillaNativeAPIBridge.BridgeError.permissionDenied("contextualIdentities and cookies")
        }

        let tabManager = try tabManager(for: context)
        try normalizeOrder(in: tabManager)

        switch method {
        case "get":
            guard let cookieStoreID = arguments.first as? String,
                  let container = container(for: cookieStoreID, in: tabManager)
            else {
                throw MozillaNativeAPIBridge.BridgeError.itemNotFound("The requested contextual identity does not exist.")
            }
            return identity(for: container)

        case "query":
            let details = arguments.first as? [String: Any] ?? [:]
            let requestedName = details["name"] as? String
            return orderedContainers(in: tabManager)
                .filter { requestedName == nil || $0.name == requestedName }
                .map(identity(for:))

        case "create":
            guard let details = arguments.first as? [String: Any],
                  let name = details["name"] as? String,
                  let colorValue = details["color"] as? String,
                  let icon = details["icon"] as? String
            else {
                throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                    "browser.contextualIdentities.create requires name, color, and icon."
                )
            }
            let color = try normalizedColor(colorValue)
            try validateIcon(icon)
            let nextOrder = (orderedContainers(in: tabManager).last?.contextualOrder ?? -1) + 1
            let container = TabContainer(
                name: name,
                emoji: emoji(for: icon),
                contextualColor: color,
                contextualIcon: icon,
                contextualOrder: nextOrder
            )
            tabManager.modelContext.insert(container)
            try tabManager.modelContext.save()
            let value = identity(for: container)
            MozillaNativeAPIBridge.shared.emit(
                namespace: "contextualIdentities",
                event: "onCreated",
                arguments: [["contextualIdentity": value]]
            )
            return value

        case "update":
            guard arguments.count >= 2,
                  let cookieStoreID = arguments[0] as? String,
                  let details = arguments[1] as? [String: Any],
                  let container = container(for: cookieStoreID, in: tabManager)
            else {
                throw MozillaNativeAPIBridge.BridgeError.itemNotFound("The requested contextual identity does not exist.")
            }

            if let name = details["name"] as? String {
                container.name = name
            }
            if let color = details["color"] as? String {
                container.contextualColor = try normalizedColor(color)
            }
            if let icon = details["icon"] as? String {
                try validateIcon(icon)
                container.contextualIcon = icon
                container.emoji = emoji(for: icon)
            }
            try tabManager.modelContext.save()
            let value = identity(for: container)
            MozillaNativeAPIBridge.shared.emit(
                namespace: "contextualIdentities",
                event: "onUpdated",
                arguments: [["contextualIdentity": value]]
            )
            return value

        case "move":
            guard arguments.count >= 2,
                  let position = integer(arguments[1])
            else {
                throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                    "browser.contextualIdentities.move requires cookieStoreIds and a position."
                )
            }
            let identifiers: [String]
            if let single = arguments[0] as? String {
                identifiers = [single]
            } else if let multiple = arguments[0] as? [String] {
                identifiers = multiple
            } else {
                throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                    "browser.contextualIdentities.move requires a cookie store ID or an array of IDs."
                )
            }
            try move(identifiers: identifiers, position: position, tabManager: tabManager)
            return NSNull()

        case "remove":
            guard let cookieStoreID = arguments.first as? String,
                  let container = container(for: cookieStoreID, in: tabManager)
            else {
                throw MozillaNativeAPIBridge.BridgeError.itemNotFound("The requested contextual identity does not exist.")
            }
            let removedIdentity = identity(for: container)
            let containerID = container.id
            tabManager.deleteContainer(container)
            try await waitUntilContainerIsDeleted(containerID, tabManager: tabManager)
            try normalizeOrder(in: tabManager)
            MozillaNativeAPIBridge.shared.emit(
                namespace: "contextualIdentities",
                event: "onRemoved",
                arguments: [["contextualIdentity": removedIdentity]]
            )
            return removedIdentity

        case "getSupportedColors":
            return colorCodes.keys.sorted().map { color in
                ["color": color, "colorCode": colorCodes[color] ?? "#7c7c7d"]
            }

        case "getSupportedIcons":
            return iconSymbols.keys.sorted().map { icon in
                ["icon": icon, "iconUrl": iconURL(for: icon)]
            }

        default:
            throw MozillaNativeAPIBridge.BridgeError.unsupportedMethod("contextualIdentities", method)
        }
    }

    private static func orderedContainers(in tabManager: TabManager) -> [TabContainer] {
        tabManager.containers.sorted {
            if $0.contextualOrder != $1.contextualOrder {
                return $0.contextualOrder < $1.contextualOrder
            }
            return $0.createdAt < $1.createdAt
        }
    }

    private static func normalizeOrder(in tabManager: TabManager) throws {
        let ordered = orderedContainers(in: tabManager)
        var changed = false
        for (index, container) in ordered.enumerated() where container.contextualOrder != index {
            container.contextualOrder = index
            changed = true
        }
        if changed {
            try tabManager.modelContext.save()
        }
    }

    private static func move(
        identifiers: [String],
        position: Int,
        tabManager: TabManager
    ) throws {
        guard !identifiers.isEmpty, Set(identifiers).count == identifiers.count else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "Contextual identity IDs must be unique and non-empty."
            )
        }

        var ordered = orderedContainers(in: tabManager)
        var moving: [TabContainer] = []
        for identifier in identifiers {
            guard let match = container(for: identifier, in: tabManager) else {
                throw MozillaNativeAPIBridge.BridgeError.itemNotFound(
                    "No Ora space matches cookieStoreId \(identifier)."
                )
            }
            moving.append(match)
        }

        let movingIDs = Set(moving.map(\.id))
        ordered.removeAll { movingIDs.contains($0.id) }
        let insertionIndex: Int
        if position == -1 {
            insertionIndex = ordered.count
        } else {
            guard position >= 0, position <= ordered.count else {
                throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                    "The requested contextual identity position is outside the available range."
                )
            }
            insertionIndex = position
        }
        ordered.insert(contentsOf: moving, at: insertionIndex)
        for (index, container) in ordered.enumerated() {
            container.contextualOrder = index
        }
        try tabManager.modelContext.save()
    }

    private static func container(for cookieStoreID: String, in tabManager: TabManager) -> TabContainer? {
        guard let id = try? MozillaBrowsingDataAPI.containerID(
            from: cookieStoreID,
            tabManager: tabManager
        ) else {
            return nil
        }
        return tabManager.containers.first { $0.id == id }
    }

    private static func identity(for container: TabContainer) -> [String: Any] {
        let color = (try? normalizedColor(container.contextualColor)) ?? "blue"
        let icon = iconSymbols[container.contextualIcon] == nil ? "circle" : container.contextualIcon
        return [
            "cookieStoreId": MozillaBrowsingDataAPI.cookieStoreID(for: container.id),
            "name": container.name,
            "color": color,
            "colorCode": colorCodes[color] ?? colorCodes["blue"]!,
            "icon": icon,
            "iconUrl": iconURL(for: icon)
        ]
    }

    private static func normalizedColor(_ value: String) throws -> String {
        let normalized: String
        switch value {
        case "turquoise":
            normalized = "cyan"
        case "toolbar":
            normalized = "gray"
        default:
            normalized = value
        }
        guard colorCodes[normalized] != nil else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "Unsupported contextual identity color: \(value)."
            )
        }
        return normalized
    }

    private static func validateIcon(_ icon: String) throws {
        guard iconSymbols[icon] != nil else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "Unsupported contextual identity icon: \(icon)."
            )
        }
    }

    private static func iconURL(for icon: String) -> String {
        guard let symbol = iconSymbols[icon],
              let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            return "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Ccircle cx='8' cy='8' r='6'/%3E%3C/svg%3E"
        }
        return "data:image/png;base64,\(png.base64EncodedString())"
    }

    private static func emoji(for icon: String) -> String {
        switch icon {
        case "briefcase": "💼"
        case "cart": "🛒"
        case "chill": "❄️"
        case "dollar": "💵"
        case "fence": "🚧"
        case "fingerprint": "🆔"
        case "food": "🍴"
        case "fruit": "🍎"
        case "gift": "🎁"
        case "pet": "🐾"
        case "tree": "🌳"
        case "vacation": "✈️"
        default: "●"
        }
    }

    private static func integer(_ value: Any) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        return value as? Int
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

    private static func waitUntilContainerIsDeleted(
        _ containerID: UUID,
        tabManager: TabManager
    ) async throws {
        for _ in 0..<200 {
            let descriptor = FetchDescriptor<TabContainer>(
                predicate: #Predicate { $0.id == containerID }
            )
            if try tabManager.modelContext.fetch(descriptor).isEmpty {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
            "Ora did not finish removing the contextual identity."
        )
    }
}
