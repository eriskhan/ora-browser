import Foundation

enum ChromeExtensionAPISupport: String, Codable {
    case webKitNative
    case oraNativeBridge
    case unavailableOnMacOS
    case requiresChromiumProtocol
}

struct ChromeExtensionAPINamespace: Hashable {
    let name: String
    let support: ChromeExtensionAPISupport
}

enum ChromeExtensionAPICatalog {
    static let namespaces: [ChromeExtensionAPINamespace] = {
        let webKitNative: Set<String> = [
            "action", "alarms", "bookmarks", "commands", "contextMenus", "cookies", "declarativeNetRequest",
            "devtools.inspectedWindow", "devtools.network", "devtools.panels", "dom", "events", "extension", "i18n",
            "notifications", "offscreen", "permissions", "runtime", "scripting", "sidePanel", "storage", "tabs",
            "webNavigation", "webRequest", "windows"
        ]

        let unavailableOnMacOS: Set<String> = [
            "audio", "certificateProvider", "documentScan", "enterprise.deviceAttributes", "enterprise.login",
            "enterprise.networkingAttributes", "enterprise.platformKeys", "fileBrowserHandler", "fileSystemProvider", "input.ime",
            "loginState", "platformKeys", "printing", "printingMetrics", "vpnProvider", "wallpaper"
        ]

        let requiresChromiumProtocol: Set<String> = ["debugger"]

        let all = [
            "accessibilityFeatures", "action", "alarms", "audio", "bookmarks", "browsingData", "certificateProvider",
            "commands", "contentSettings", "contextMenus", "cookies", "debugger", "declarativeContent",
            "declarativeNetRequest", "desktopCapture", "devtools.inspectedWindow", "devtools.network", "devtools.panels",
            "devtools.performance", "devtools.recorder", "dns", "documentScan", "dom", "downloads",
            "enterprise.deviceAttributes", "enterprise.hardwarePlatform", "enterprise.login",
            "enterprise.networkingAttributes", "enterprise.platformKeys", "events", "extension", "extensionTypes",
            "fileBrowserHandler", "fileSystemProvider", "fontSettings", "gcm", "history", "i18n", "identity", "idle",
            "input.ime", "instanceID", "loginState", "management", "mimeHandler", "notifications", "offscreen", "omnibox",
            "pageCapture", "permissions", "platformKeys", "power", "printerProvider", "printing", "printingMetrics",
            "privacy", "processes", "proxy", "readingList", "runtime", "scripting", "search", "sessions", "sidePanel",
            "storage", "system.cpu", "system.display", "system.memory", "system.storage", "systemLog", "tabCapture",
            "tabGroups", "tabs", "topSites", "tts", "ttsEngine", "types", "userScripts", "vpnProvider", "wallpaper",
            "webAuthenticationProxy", "webNavigation", "webRequest", "windows"
        ]

        return all.map { name in
            let support: ChromeExtensionAPISupport
            if webKitNative.contains(name) {
                support = .webKitNative
            } else if unavailableOnMacOS.contains(name) {
                support = .unavailableOnMacOS
            } else if requiresChromiumProtocol.contains(name) {
                support = .requiresChromiumProtocol
            } else {
                support = .oraNativeBridge
            }
            return ChromeExtensionAPINamespace(name: name, support: support)
        }
    }()

    static let allNamespaceNames: [String] = namespaces.map(\.name)

    static let bridgeNamespaceNames: [String] = namespaces
        .filter { $0.support != .webKitNative }
        .map(\.name)

    static func support(for namespace: String) -> ChromeExtensionAPISupport? {
        namespaces.first(where: { $0.name == namespace })?.support
    }
}
