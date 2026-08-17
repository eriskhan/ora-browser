import Foundation
@preconcurrency import WebKit

@MainActor
enum MozillaSearchAPI {
    private static let searchEngineService = SearchEngineService()

    static func handle(
        method: String,
        arguments: [Any],
        context: WKWebExtensionContext
    ) throws -> Any {
        let tabManager = try tabManager(for: context)
        switch method {
        case "get":
            return searchEngines(tabManager: tabManager)
        case "buildURL":
            return try buildURL(arguments: arguments, tabManager: tabManager)
        default:
            throw MozillaNativeAPIBridge.BridgeError.unsupportedMethod("search", method)
        }
    }

    private static func searchEngines(tabManager: TabManager) -> [[String: Any]] {
        let defaultName = searchEngineService
            .getDefaultSearchEngine(for: tabManager.activeContainer?.id)?.name
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
    }

    private static func buildURL(
        arguments: [Any],
        tabManager: TabManager
    ) throws -> String {
        guard let properties = arguments.first as? [String: Any],
              let query = properties["query"] as? String
        else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "browser.search requires a query."
            )
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
            throw MozillaNativeAPIBridge.BridgeError.itemNotFound(
                "The requested Ora search engine is not available."
            )
        }
        return url.absoluteString
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
}
