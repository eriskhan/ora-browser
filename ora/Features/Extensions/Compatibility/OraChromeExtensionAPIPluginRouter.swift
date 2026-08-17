import Foundation
@preconcurrency import WebKit

@MainActor
enum OraChromeExtensionAPIPluginRouter {
    struct RoutedValue {
        let value: Any?
    }

    static func route(
        namespace: String,
        method: String,
        args: [Any],
        spaceID: UUID,
        context: WKWebExtensionContext
    ) async throws -> RoutedValue? {
        switch namespace {
        case "tabs":
            return RoutedValue(
                value: try OraTabGroupManager.shared.handleTabs(
                    method: method,
                    args: args,
                    spaceID: spaceID
                )
            )
        case "tabGroups":
            return RoutedValue(
                value: try OraTabGroupManager.shared.handleTabGroups(
                    method: method,
                    args: args,
                    spaceID: spaceID
                )
            )
        default:
            return nil
        }
    }
}
