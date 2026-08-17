import Foundation

enum MozillaExtensionAPISupport: String, Codable {
    case nativeWebKit
    case compatibilityLayer
    case partial
    case unsupported
}

struct MozillaExtensionAPINamespace: Hashable {
    let name: String
    let support: MozillaExtensionAPISupport
    let notes: String

    init(_ name: String, _ support: MozillaExtensionAPISupport, notes: String = "") {
        self.name = name
        self.support = support
        self.notes = notes
    }
}

enum MozillaExtensionAPICatalog {
    static let namespaces: [MozillaExtensionAPINamespace] = [
        .init("action", .nativeWebKit),
        .init("alarms", .nativeWebKit),
        .init("bookmarks", .nativeWebKit),
        .init(
            "browserAction",
            .compatibilityLayer,
            notes: "Aliases Firefox Manifest V2 browserAction to action."
        ),
        .init(
            "browserSettings",
            .partial,
            notes: "Reports Ora's vertical-tab and new-tab-position behavior as read-only BrowserSettings."
        ),
        .init(
            "browsingData",
            .partial,
            notes: "Clears Ora/WebKit browsing data using real website data stores and Ora history/download models."
        ),
        .init(
            "captivePortal",
            .unsupported,
            notes: "Ora does not expose captive portal state to extensions."
        ),
        .init(
            "clipboard",
            .compatibilityLayer,
            notes: "Implements clipboard.setImageData using the Web Clipboard API."
        ),
        .init("commands", .nativeWebKit),
        .init(
            "contentScripts",
            .compatibilityLayer,
            notes: "File-backed registrations map to scripting.registerContentScripts."
        ),
        .init(
            "contextualIdentities",
            .partial,
            notes: "Maps Ora spaces to Firefox-style container identities with persistent color, icon, order, and cookie-store IDs."
        ),
        .init(
            "cookies",
            .partial,
            notes: "Uses Ora space WKHTTPCookieStores and Firefox cookieStoreIds; partitionKey metadata and WebKit-generated tab IDs are unavailable."
        ),
        .init("declarativeNetRequest", .nativeWebKit),
        .init("devtools", .nativeWebKit),
        .init(
            "dns",
            .partial,
            notes: "Uses the macOS resolver; cache-only, cache-bypass, and speculative Firefox resolver flags are rejected."
        ),
        .init("dom", .nativeWebKit),
        .init(
            "downloads",
            .partial,
            notes: "Uses Ora's download history and real URLSession transfers; dangerous-download and private-download semantics are not synthesized."
        ),
        .init("events", .nativeWebKit),
        .init("extension", .nativeWebKit),
        .init(
            "extensionTypes",
            .partial,
            notes: "Types exported by WebKit are available; Firefox-only constants are not synthesized."
        ),
        .init(
            "find",
            .partial,
            notes: "Searches and highlights the active HTTP(S) tab with range/rectangle data; explicit tabId and cross-frame matching are not implemented."
        ),
        .init(
            "history",
            .partial,
            notes: "Maps Firefox history operations and events to Ora's persistent history model."
        ),
        .init("i18n", .nativeWebKit),
        .init("identity", .unsupported, notes: "WebKit does not expose the Mozilla identity namespace."),
        .init(
            "idle",
            .partial,
            notes: "Uses real macOS inactivity and screen-lock state with per-extension detection intervals."
        ),
        .init(
            "management",
            .partial,
            notes: "Exposes Ora-installed extensions, enable/remove operations, permission warnings, events, and constrained AMO theme installation."
        ),
        .init("menus", .nativeWebKit),
        .init("notifications", .nativeWebKit),
        .init(
            "omnibox",
            .unsupported,
            notes: "Ora does not expose its URL bar as the Mozilla omnibox API."
        ),
        .init(
            "pageAction",
            .compatibilityLayer,
            notes: "Common pageAction operations map to action."
        ),
        .init(
            "permissions",
            .partial,
            notes: "Keeps WebKit permission/origin handling and merges Ora prompts for Firefox-only native bridge permissions."
        ),
        .init("pkcs11", .unsupported, notes: "Ora does not install or manage PKCS #11 modules."),
        .init(
            "privacy",
            .partial,
            notes: "Exposes Ora-enforceable cookie, tracking-protection, fingerprinting, and password-save settings as BrowserSettings."
        ),
        .init(
            "proxy",
            .unsupported,
            notes: "Firefox proxy settings affect private browsing too, while Ora keeps extension private-window access disabled."
        ),
        .init(
            "publicSuffix",
            .unsupported,
            notes: "Ora does not expose Firefox's public suffix service."
        ),
        .init(
            "runtime",
            .compatibilityLayer,
            notes: "WebKit provides runtime; Ora adds Firefox runtime.getBrowserInfo when absent."
        ),
        .init("scripting", .nativeWebKit),
        .init(
            "search",
            .partial,
            notes: "Maps Firefox search queries to Ora search engines and opens results through native tabs/windows."
        ),
        .init(
            "sessions",
            .unsupported,
            notes: "Ora does not expose recently closed sessions through the Mozilla API."
        ),
        .init("sidebarAction", .nativeWebKit),
        .init("storage", .nativeWebKit),
        .init(
            "tabGroups",
            .unsupported,
            notes: "Ora spaces and tab sections are not Firefox tab groups."
        ),
        .init("tabs", .nativeWebKit),
        .init(
            "theme",
            .unsupported,
            notes: "Extensions cannot currently restyle Ora browser chrome."
        ),
        .init(
            "topSites",
            .partial,
            notes: "Builds Firefox-style top sites from Ora visit history; Ora has no Firefox new-tab top-sites surface."
        ),
        .init(
            "types",
            .partial,
            notes: "WebKit-backed types are available; Firefox BrowserSetting coverage is limited to Ora-backed settings."
        ),
        .init(
            "userScripts",
            .partial,
            notes: "File-backed registration maps to scripting; Firefox USER_SCRIPT worlds are not emulated."
        ),
        .init("webNavigation", .nativeWebKit),
        .init("webRequest", .nativeWebKit),
        .init(
            "windows",
            .partial,
            notes: "Bridges existing Ora windows and URL-based windows.create with frame, focus, type, and state; moving existing tabs between windows is not supported."
        )
    ]

    static let allNamespaceNames = namespaces.map(\.name)

    static let unsupportedAPIPaths = Set(
        namespaces
            .filter { $0.support == .unsupported }
            .map { "browser.\($0.name)" }
    )

    static func support(for namespace: String) -> MozillaExtensionAPINamespace? {
        namespaces.first { $0.name == namespace }
    }
}
