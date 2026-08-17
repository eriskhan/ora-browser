import Foundation
@preconcurrency import WebKit

@MainActor
enum MozillaCookiesAPI {
    private struct CookieKey: Hashable {
        let name: String
        let domain: String
        let path: String
    }

    private final class ContextBox {
        weak var context: WKWebExtensionContext?

        init(_ context: WKWebExtensionContext) {
            self.context = context
        }
    }

    private final class StoreObserver: NSObject, WKHTTPCookieStoreObserver {
        let containerID: UUID

        init(containerID: UUID) {
            self.containerID = containerID
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            Task { @MainActor in
                await MozillaCookiesAPI.storeDidChange(
                    containerID: containerID,
                    cookieStore: cookieStore
                )
            }
        }
    }

    private static var observers: [UUID: StoreObserver] = [:]
    private static var snapshots: [UUID: [CookieKey: HTTPCookie]] = [:]
    private static var contexts: [String: ContextBox] = [:]

    static func handle(
        method: String,
        arguments: [Any],
        context: WKWebExtensionContext,
        manager: ExtensionManager
    ) async throws -> Any {
        try MozillaNativeAPIRouter.require("cookies", context: context, manager: manager)
        register(context)
        let tabManager = try tabManager(for: context)
        await ensureObservers(tabManager: tabManager)

        switch method {
        case "get":
            return try await get(arguments: arguments, context: context, tabManager: tabManager)
        case "getAll":
            return try await getAll(arguments: arguments, context: context, tabManager: tabManager)
        case "set":
            return try await set(arguments: arguments, context: context, tabManager: tabManager)
        case "remove":
            return try await remove(arguments: arguments, context: context, tabManager: tabManager)
        case "getAllCookieStores":
            return cookieStores(tabManager: tabManager)
        case "__subscribe":
            return NSNull()
        default:
            throw MozillaNativeAPIBridge.BridgeError.unsupportedMethod("cookies", method)
        }
    }

    private static func get(
        arguments: [Any],
        context: WKWebExtensionContext,
        tabManager: TabManager
    ) async throws -> Any {
        guard let details = arguments.first as? [String: Any],
              let urlString = details["url"] as? String,
              let url = URL(string: urlString),
              let name = details["name"] as? String
        else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "browser.cookies.get requires a URL and cookie name."
            )
        }
        try rejectUnsupportedPartitioning(details)
        try requireHostAccess(url, context: context)
        let selection = try storeSelection(details: details, tabManager: tabManager)
        let cookies = await allCookies(in: selection.store)
            .filter { $0.name == name && cookie($0, matches: url) }
            .sorted(by: firefoxCookieOrder)
        guard let cookie = cookies.first else { return NSNull() }
        return cookieValue(cookie, storeID: selection.storeID)
    }

    private static func getAll(
        arguments: [Any],
        context: WKWebExtensionContext,
        tabManager: TabManager
    ) async throws -> [[String: Any]] {
        let details = arguments.first as? [String: Any] ?? [:]
        try rejectUnsupportedPartitioning(details)
        let selection = try storeSelection(details: details, tabManager: tabManager)
        let cookies = await allCookies(in: selection.store)
        var results: [[String: Any]] = []

        for cookie in cookies where cookieMatchesFilters(cookie, details: details) {
            guard canAccess(cookie, context: context) else { continue }
            if let urlString = details["url"] as? String,
               let url = URL(string: urlString),
               !cookie(cookie, matches: url)
            {
                continue
            }
            results.append(cookieValue(cookie, storeID: selection.storeID))
        }
        return results.sorted { lhs, rhs in
            let leftPath = lhs["path"] as? String ?? ""
            let rightPath = rhs["path"] as? String ?? ""
            if leftPath.count != rightPath.count {
                return leftPath.count > rightPath.count
            }
            let leftName = lhs["name"] as? String ?? ""
            let rightName = rhs["name"] as? String ?? ""
            return leftName.localizedStandardCompare(rightName) == .orderedAscending
        }
    }

    private static func set(
        arguments: [Any],
        context: WKWebExtensionContext,
        tabManager: TabManager
    ) async throws -> [String: Any] {
        guard let details = arguments.first as? [String: Any],
              let urlString = details["url"] as? String,
              let url = URL(string: urlString),
              let host = url.host,
              !host.isEmpty
        else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "browser.cookies.set requires a valid URL."
            )
        }
        try rejectUnsupportedPartitioning(details)
        try requireHostAccess(url, context: context)
        let selection = try storeSelection(details: details, tabManager: tabManager)
        let cookie = try makeCookie(details: details, url: url)
        guard domainMatches(host: host, cookieDomain: cookie.domain) else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "The cookie domain is not valid for the requested URL."
            )
        }

        await setCookie(cookie, in: selection.store)
        await refreshSnapshot(containerID: selection.container.id, store: selection.store)
        emitChange(
            removed: false,
            cookie: cookie,
            storeID: selection.storeID,
            cause: "explicit",
            context: context
        )
        return cookieValue(cookie, storeID: selection.storeID)
    }

    private static func remove(
        arguments: [Any],
        context: WKWebExtensionContext,
        tabManager: TabManager
    ) async throws -> Any {
        guard let details = arguments.first as? [String: Any],
              let urlString = details["url"] as? String,
              let url = URL(string: urlString),
              let name = details["name"] as? String
        else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "browser.cookies.remove requires a URL and cookie name."
            )
        }
        try rejectUnsupportedPartitioning(details)
        try requireHostAccess(url, context: context)
        let selection = try storeSelection(details: details, tabManager: tabManager)
        let matches = await allCookies(in: selection.store)
            .filter { $0.name == name && cookie($0, matches: url) }
            .sorted(by: firefoxCookieOrder)
        guard let cookie = matches.first else { return NSNull() }

        await deleteCookie(cookie, from: selection.store)
        await refreshSnapshot(containerID: selection.container.id, store: selection.store)
        emitChange(
            removed: true,
            cookie: cookie,
            storeID: selection.storeID,
            cause: "explicit",
            context: context
        )
        return [
            "url": url.absoluteString,
            "name": cookie.name,
            "storeId": selection.storeID
        ]
    }

    private struct StoreSelection {
        let container: TabContainer
        let storeID: String
        let store: WKHTTPCookieStore
    }

    private static func storeSelection(
        details: [String: Any],
        tabManager: TabManager
    ) throws -> StoreSelection {
        let container: TabContainer
        if let storeID = details["storeId"] as? String, !storeID.isEmpty {
            if storeID == "firefox-default", let active = tabManager.activeContainer {
                container = active
            } else {
                guard let id = try MozillaBrowsingDataAPI.containerID(
                    from: storeID,
                    tabManager: tabManager
                ),
                let selected = tabManager.containers.first(where: { $0.id == id })
                else {
                    throw MozillaNativeAPIBridge.BridgeError.itemNotFound(
                        "The requested cookie store does not exist."
                    )
                }
                container = selected
            }
        } else if let active = tabManager.activeContainer {
            container = active
        } else {
            throw MozillaNativeAPIBridge.BridgeError.unavailableBrowserWindow
        }
        return selection(for: container)
    }

    private static func selection(for container: TabContainer) -> StoreSelection {
        let profile = BrowserEngine.shared.makeProfile(identifier: container.id, isPrivate: false)
        return StoreSelection(
            container: container,
            storeID: MozillaBrowsingDataAPI.cookieStoreID(for: container.id),
            store: profile.dataStore.httpCookieStore
        )
    }

    private static func cookieStores(tabManager: TabManager) -> [[String: Any]] {
        tabManager.containers.map { container in
            [
                "id": MozillaBrowsingDataAPI.cookieStoreID(for: container.id),
                "tabIds": [Int]()
            ]
        }
    }

    private static func makeCookie(details: [String: Any], url: URL) throws -> HTTPCookie {
        let name = details["name"] as? String ?? ""
        let value = details["value"] as? String ?? ""
        let domain = details["domain"] as? String
        let path = details["path"] as? String ?? defaultCookiePath(for: url)
        try validateCookieComponent(name, label: "name", allowEmpty: true)
        try validateCookieComponent(value, label: "value", allowEmpty: true)
        try validateCookieComponent(path, label: "path", allowEmpty: false)
        if let domain {
            try validateCookieComponent(domain, label: "domain", allowEmpty: false)
        }

        var header = "\(name)=\(value); Path=\(path)"
        if let domain {
            header += "; Domain=\(domain)"
        }
        if let expirationDate = double(details["expirationDate"]) {
            let date = Date(timeIntervalSince1970: expirationDate)
            header += "; Expires=\(httpDate(date))"
        }
        if details["secure"] as? Bool == true {
            header += "; Secure"
        }
        if details["httpOnly"] as? Bool == true {
            header += "; HttpOnly"
        }
        if let sameSite = details["sameSite"] as? String {
            switch sameSite {
            case "strict":
                header += "; SameSite=Strict"
            case "lax":
                header += "; SameSite=Lax"
            case "no_restriction":
                header += "; SameSite=None"
            case "unspecified":
                break
            default:
                throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                    "Unsupported cookies.SameSiteStatus value: \(sameSite)."
                )
            }
        }

        guard let cookie = HTTPCookie.cookies(
            withResponseHeaderFields: ["Set-Cookie": header],
            for: url
        ).first else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "The requested cookie attributes are invalid."
            )
        }
        return cookie
    }

    private static func cookieValue(_ cookie: HTTPCookie, storeID: String) -> [String: Any] {
        var value: [String: Any] = [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "hostOnly": !cookie.domain.hasPrefix("."),
            "path": cookie.path,
            "secure": cookie.isSecure,
            "httpOnly": cookie.isHTTPOnly,
            "sameSite": sameSiteValue(cookie.sameSitePolicy),
            "session": cookie.isSessionOnly,
            "firstPartyDomain": "",
            "storeId": storeID
        ]
        if let expires = cookie.expiresDate {
            value["expirationDate"] = expires.timeIntervalSince1970
        }
        return value
    }

    private static func cookieMatchesFilters(
        _ cookie: HTTPCookie,
        details: [String: Any]
    ) -> Bool {
        if let name = details["name"] as? String, cookie.name != name { return false }
        if let domain = details["domain"] as? String,
           !domainMatches(host: domain, cookieDomain: cookie.domain)
        {
            return false
        }
        if let path = details["path"] as? String, cookie.path != path { return false }
        if let secure = details["secure"] as? Bool, cookie.isSecure != secure { return false }
        if let session = details["session"] as? Bool, cookie.isSessionOnly != session { return false }
        return cookie.expiresDate.map { $0 > Date() } ?? true
    }

    private static func cookie(_ cookie: HTTPCookie, matches url: URL) -> Bool {
        guard let host = url.host,
              domainMatches(host: host, cookieDomain: cookie.domain)
        else {
            return false
        }
        if cookie.isSecure, url.scheme?.lowercased() != "https" { return false }
        let requestPath = url.path.isEmpty ? "/" : url.path
        return pathMatches(requestPath: requestPath, cookiePath: cookie.path)
    }

    private static func domainMatches(host: String, cookieDomain: String) -> Bool {
        let normalizedHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let normalizedDomain = cookieDomain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalizedHost == normalizedDomain || normalizedHost.hasSuffix(".\(normalizedDomain)")
    }

    private static func pathMatches(requestPath: String, cookiePath: String) -> Bool {
        if requestPath == cookiePath { return true }
        guard requestPath.hasPrefix(cookiePath) else { return false }
        if cookiePath.hasSuffix("/") { return true }
        let index = requestPath.index(requestPath.startIndex, offsetBy: cookiePath.count)
        return index < requestPath.endIndex && requestPath[index] == "/"
    }

    private static func firefoxCookieOrder(_ lhs: HTTPCookie, _ rhs: HTTPCookie) -> Bool {
        if lhs.path.count != rhs.path.count {
            return lhs.path.count > rhs.path.count
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func canAccess(_ cookie: HTTPCookie, context: WKWebExtensionContext) -> Bool {
        let host = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let httpsURL = URL(string: "https://\(host)\(cookie.path)") else { return false }
        if context.hasAccess(to: httpsURL) { return true }
        guard !cookie.isSecure,
              let httpURL = URL(string: "http://\(host)\(cookie.path)")
        else {
            return false
        }
        return context.hasAccess(to: httpURL)
    }

    private static func requireHostAccess(_ url: URL, context: WKWebExtensionContext) throws {
        let activeTab = (context.focusedWindow as? OraWebExtensionWindow)?.activeTab(for: context)
        guard context.hasAccess(to: url, in: activeTab) || context.hasAccess(to: url) else {
            throw MozillaNativeAPIBridge.BridgeError.permissionDenied(
                "host access for \(url.host ?? url.absoluteString)"
            )
        }
    }

    private static func rejectUnsupportedPartitioning(_ details: [String: Any]) throws {
        if details["partitionKey"] != nil {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "Ora's WebKit cookie store does not expose Firefox partitionKey metadata."
            )
        }
        if let firstPartyDomain = details["firstPartyDomain"],
           !(firstPartyDomain is NSNull),
           (firstPartyDomain as? String)?.isEmpty != true
        {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "Ora does not enable Firefox first-party isolation metadata."
            )
        }
    }

    private static func register(_ context: WKWebExtensionContext) {
        contexts[context.uniqueIdentifier] = ContextBox(context)
        contexts = contexts.filter { $0.value.context != nil }
    }

    private static func ensureObservers(tabManager: TabManager) async {
        for container in tabManager.containers where observers[container.id] == nil {
            let selection = selection(for: container)
            let observer = StoreObserver(containerID: container.id)
            observers[container.id] = observer
            selection.store.add(observer)
            snapshots[container.id] = dictionary(await allCookies(in: selection.store))
        }
    }

    private static func storeDidChange(
        containerID: UUID,
        cookieStore: WKHTTPCookieStore
    ) async {
        let newSnapshot = dictionary(await allCookies(in: cookieStore))
        let oldSnapshot = snapshots[containerID] ?? [:]
        snapshots[containerID] = newSnapshot
        let storeID = MozillaBrowsingDataAPI.cookieStoreID(for: containerID)

        for (key, oldCookie) in oldSnapshot {
            guard let newCookie = newSnapshot[key] else {
                emitObservedChange(
                    removed: true,
                    cookie: oldCookie,
                    storeID: storeID,
                    cause: "explicit"
                )
                continue
            }
            if !equivalent(oldCookie, newCookie) {
                emitObservedChange(
                    removed: true,
                    cookie: oldCookie,
                    storeID: storeID,
                    cause: "overwrite"
                )
                emitObservedChange(
                    removed: false,
                    cookie: newCookie,
                    storeID: storeID,
                    cause: "explicit"
                )
            }
        }
        for (key, newCookie) in newSnapshot where oldSnapshot[key] == nil {
            emitObservedChange(
                removed: false,
                cookie: newCookie,
                storeID: storeID,
                cause: "explicit"
            )
        }
    }

    private static func emitObservedChange(
        removed: Bool,
        cookie: HTTPCookie,
        storeID: String,
        cause: String
    ) {
        for (extensionID, box) in contexts {
            guard let context = box.context,
                  canAccess(cookie, context: context)
            else { continue }
            emitChange(
                removed: removed,
                cookie: cookie,
                storeID: storeID,
                cause: cause,
                extensionID: extensionID
            )
        }
    }

    private static func emitChange(
        removed: Bool,
        cookie: HTTPCookie,
        storeID: String,
        cause: String,
        context: WKWebExtensionContext
    ) {
        emitChange(
            removed: removed,
            cookie: cookie,
            storeID: storeID,
            cause: cause,
            extensionID: context.uniqueIdentifier
        )
    }

    private static func emitChange(
        removed: Bool,
        cookie: HTTPCookie,
        storeID: String,
        cause: String,
        extensionID: String
    ) {
        let details: [String: Any] = [
            "removed": removed,
            "cookie": cookieValue(cookie, storeID: storeID),
            "cause": cause
        ]
        MozillaNativeAPIBridge.shared.emit(
            namespace: "cookies",
            event: "__ora_targeted__",
            arguments: [extensionID, "onChanged", [details]]
        )
    }

    private static func refreshSnapshot(
        containerID: UUID,
        store: WKHTTPCookieStore
    ) async {
        snapshots[containerID] = dictionary(await allCookies(in: store))
    }

    private static func dictionary(_ cookies: [HTTPCookie]) -> [CookieKey: HTTPCookie] {
        Dictionary(uniqueKeysWithValues: cookies.map {
            (CookieKey(name: $0.name, domain: $0.domain, path: $0.path), $0)
        })
    }

    private static func equivalent(_ lhs: HTTPCookie, _ rhs: HTTPCookie) -> Bool {
        lhs.value == rhs.value &&
            lhs.expiresDate == rhs.expiresDate &&
            lhs.isSecure == rhs.isSecure &&
            lhs.isHTTPOnly == rhs.isHTTPOnly &&
            lhs.sameSitePolicy == rhs.sameSitePolicy
    }

    private static func allCookies(in store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    private static func setCookie(_ cookie: HTTPCookie, in store: WKHTTPCookieStore) async {
        await withCheckedContinuation { continuation in
            store.setCookie(cookie) { continuation.resume() }
        }
    }

    private static func deleteCookie(_ cookie: HTTPCookie, from store: WKHTTPCookieStore) async {
        await withCheckedContinuation { continuation in
            store.delete(cookie) { continuation.resume() }
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

    private static func sameSiteValue(_ policy: HTTPCookieStringPolicy?) -> String {
        if policy == .sameSiteStrict { return "strict" }
        if policy == .sameSiteLax { return "lax" }
        return "no_restriction"
    }

    private static func defaultCookiePath(for url: URL) -> String {
        let path = url.path
        guard path.hasPrefix("/"), path != "/" else { return "/" }
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    private static func validateCookieComponent(
        _ value: String,
        label: String,
        allowEmpty: Bool
    ) throws {
        if (!allowEmpty && value.isEmpty) || value.contains(";") || value.contains("\r") || value.contains("\n") {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "The cookie \(label) contains an invalid value."
            )
        }
    }

    private static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        return value as? Double
    }
}
