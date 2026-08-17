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
        .init("browserAction", .compatibilityLayer, notes: "Aliases Firefox Manifest V2 browserAction to action."),
        .init("browserSettings", .unsupported, notes: "Ora does not expose Firefox global BrowserSetting preferences."),
        .init("browsingData", .unsupported, notes: "WebKit does not expose the Mozilla browsingData namespace."),
        .init("captivePortal", .unsupported, notes: "Ora does not expose captive portal state to extensions."),
        .init("clipboard", .compatibilityLayer, notes: "Implements clipboard.setImageData using the Web Clipboard API."),
        .init("commands", .nativeWebKit),
        .init("contentScripts", .compatibilityLayer, notes: "File-backed registrations map to scripting.registerContentScripts."),
        .init("contextualIdentities", .unsupported, notes: "Ora spaces are not Firefox container identities."),
        .init("cookies", .nativeWebKit),
        .init("declarativeNetRequest", .nativeWebKit),
        .init("devtools", .nativeWebKit),
        .init("dns", .unsupported, notes: "WebKit does not expose the Mozilla dns namespace."),
        .init("dom", .nativeWebKit),
        .init("downloads", .unsupported, notes: "WebKit does not expose the Mozilla downloads namespace to WebExtensions."),
        .init("events", .nativeWebKit),
        .init("extension", .nativeWebKit),
        .init("extensionTypes", .partial, notes: "Types exported by WebKit are available; Firefox-only constants are not synthesized."),
        .init("find", .unsupported, notes: "Ora's native find UI does not expose Firefox browser.find ranges and result events."),
        .init("history", .unsupported, notes: "WebKit does not expose the Mozilla history namespace."),
        .init("i18n", .nativeWebKit),
        .init("identity", .unsupported, notes: "WebKit does not expose the Mozilla identity namespace."),
        .init("idle", .unsupported, notes: "WebKit does not expose the Mozilla idle namespace."),
        .init("management", .unsupported, notes: "WebKit does not expose extension management APIs to extensions."),
        .init("menus", .nativeWebKit),
        .init("notifications", .nativeWebKit),
        .init("omnibox", .unsupported, notes: "Ora does not expose its URL bar as the Mozilla omnibox API."),
        .init("pageAction", .compatibilityLayer, notes: "Common pageAction operations map to action."),
        .init("permissions", .nativeWebKit),
        .init("pkcs11", .unsupported, notes: "Ora does not install or manage PKCS #11 modules."),
        .init("privacy", .unsupported, notes: "Ora privacy settings are not exposed as Firefox BrowserSetting values."),
        .init("proxy", .unsupported, notes: "Ora does not expose Firefox proxy script registration or BrowserSetting semantics."),
        .init("publicSuffix", .unsupported, notes: "Ora does not expose Firefox's public suffix service."),
        .init("runtime", .compatibilityLayer, notes: "WebKit provides runtime; Ora adds Firefox runtime.getBrowserInfo when absent."),
        .init("scripting", .nativeWebKit),
        .init("search", .unsupported, notes: "Ora search providers are not exposed through the Mozilla search API."),
        .init("sessions", .unsupported, notes: "Ora does not expose recently closed sessions through the Mozilla API."),
        .init("sidebarAction", .nativeWebKit),
        .init("storage", .nativeWebKit),
        .init("tabGroups", .unsupported, notes: "Ora spaces and tab sections are not Firefox tab groups."),
        .init("tabs", .nativeWebKit),
        .init("theme", .unsupported, notes: "Extensions cannot currently restyle Ora browser chrome."),
        .init("topSites", .unsupported, notes: "Ora does not expose frequently visited sites through this API."),
        .init("types", .partial, notes: "WebKit-backed types are available; Firefox BrowserSetting is not synthesized."),
        .init("userScripts", .partial, notes: "File-backed registration maps to scripting; Firefox USER_SCRIPT worlds are not emulated."),
        .init("webNavigation", .nativeWebKit),
        .init("webRequest", .nativeWebKit),
        .init("windows", .partial, notes: "Existing Ora windows are bridged; creating a new native Ora window is not exposed yet.")
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
