@testable import Ora
import Testing

struct ChromeExtensionAPICatalogTests {
    @Test func catalogMatchesCurrentChromeReferenceNamespaces() {
        let expected: Set<String> = [
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

        #expect(Set(ChromeExtensionAPICatalog.allNamespaceNames) == expected)
    }

    @Test func everyNamespaceHasExactlyOneSupportRoute() {
        #expect(ChromeExtensionAPICatalog.namespaces.count == Set(ChromeExtensionAPICatalog.allNamespaceNames).count)
        #expect(ChromeExtensionAPICatalog.namespaces.allSatisfy { !$0.name.isEmpty })
    }

    @Test func knownPlatformSpecificAPIsAreExplicit() {
        #expect(ChromeExtensionAPICatalog.support(for: "audio") == .unavailableOnMacOS)
        #expect(ChromeExtensionAPICatalog.support(for: "printing") == .unavailableOnMacOS)
        #expect(ChromeExtensionAPICatalog.support(for: "debugger") == .requiresChromiumProtocol)
        #expect(ChromeExtensionAPICatalog.support(for: "enterprise.hardwarePlatform") == .oraNativeBridge)
        #expect(ChromeExtensionAPICatalog.support(for: "tabs") == .webKitNative)
    }
}
