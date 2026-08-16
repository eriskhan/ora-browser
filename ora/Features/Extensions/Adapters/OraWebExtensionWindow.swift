import AppKit
@preconcurrency import WebKit

@MainActor
final class OraWebExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var tabManager: TabManager?
    let spaceID: UUID

    init(tabManager: TabManager, spaceID: UUID) {
        self.tabManager = tabManager
        self.spaceID = spaceID
        super.init()
    }

    var browserWindow: NSWindow? {
        guard let tabManager else { return nil }
        if let window = tabManager.activeTab?.pageWindow {
            return window
        }

        for container in tabManager.containers {
            for tab in container.tabs {
                if let window = tab.pageWindow {
                    return window
                }
            }
        }
        return nil
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let container = tabManager?.containers.first(where: { $0.id == spaceID }) else {
            return []
        }

        return container.tabs
            .sorted { $0.order < $1.order }
            .map { OraWebExtensionTabCache.shared.adapter(for: $0) }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let activeTab = tabManager?.activeTab, activeTab.container.id == spaceID else {
            return nil
        }
        return OraWebExtensionTabCache.shared.adapter(for: activeTab)
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        false
    }
}
