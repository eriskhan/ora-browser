import AppKit
import Combine
import Foundation
import os.log
@preconcurrency import WebKit

/// Bridges Ora's browser model to WebKit's WebExtensions runtime.
///
/// WebKit implements the JavaScript WebExtensions surface. Ora is responsible for
/// attaching this controller to every browsing WKWebView and exposing the host's
/// tabs/windows through WKWebExtensionTab and WKWebExtensionWindow.
@MainActor
final class ExtensionCompatibilityManager: NSObject, ObservableObject {
    static let shared = ExtensionCompatibilityManager()

    let controller: WKWebExtensionController

    @Published private(set) var installedExtensions: [WKWebExtension] = []

    private let logger = Logger(subsystem: "com.orabrowser.app", category: "WebExtensions")
    private var contextsByURL: [URL: WKWebExtensionContext] = [:]
    private var tabsByPage: [ObjectIdentifier: ExtensionTabAdapter] = [:]
    private var nextTabID = 1
    private var windowAdapter: ExtensionWindowAdapter?
    private weak var activeAdapter: ExtensionTabAdapter?

    override private init() {
        let configuration = WKWebExtensionController.Configuration(identifier: UUID())
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        controller.delegate = self
    }

    func register(_ page: BrowserPage) {
        let key = ObjectIdentifier(page)
        if tabsByPage[key] == nil {
            let adapter = ExtensionTabAdapter(id: nextTabID, page: page, manager: self)
            nextTabID += 1
            tabsByPage[key] = adapter
            ensureWindow()
            controller.didOpenTab(adapter)
        }
        syncActiveTab(using: page)
    }

    func unregister(_ page: BrowserPage) {
        let key = ObjectIdentifier(page)
        guard let adapter = tabsByPage.removeValue(forKey: key) else { return }
        if activeAdapter === adapter {
            activeAdapter = nil
        }
        controller.didCloseTab(adapter, windowIsClosing: false)
    }

    func adapter(for page: BrowserPage) -> ExtensionTabAdapter? {
        tabsByPage[ObjectIdentifier(page)]
    }

    var openTabs: [ExtensionTabAdapter] {
        tabsByPage.values.sorted { lhs, rhs in
            let left = lhs.nativeTab?.order ?? lhs.id
            let right = rhs.nativeTab?.order ?? rhs.id
            return left < right
        }
    }

    var focusedWindow: ExtensionWindowAdapter? {
        ensureWindow()
        return windowAdapter
    }

    func installExtension(from url: URL) async throws {
        if contextsByURL[url] != nil {
            return
        }

        let webExtension = try await WKWebExtension(resourceBaseURL: url)
        let context = WKWebExtensionContext(for: webExtension)
        context.isInspectable = true
        try controller.load(context)

        contextsByURL[url] = context
        installedExtensions.append(webExtension)

        context.loadBackgroundContent { [weak self] error in
            guard let error else { return }
            self?.logger.error("Extension background load failed: \(error.localizedDescription)")
        }
    }

    func uninstallExtension(at url: URL) throws {
        guard let context = contextsByURL.removeValue(forKey: url) else { return }
        try controller.unload(context)
        installedExtensions.removeAll { $0 === context.webExtension }
    }

    func loadInstalledExtensions() async {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("extensions", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        for url in urls {
            do {
                try await installExtension(from: url)
            } catch {
                logger.error("Failed to load extension at \(url.path): \(error.localizedDescription)")
            }
        }
    }

    func notifyPropertiesChanged(for adapter: ExtensionTabAdapter) {
        controller.didChangeTabProperties([.title, .url, .loading], for: adapter)
    }

    private func ensureWindow() {
        guard windowAdapter == nil else { return }
        let adapter = ExtensionWindowAdapter(manager: self)
        windowAdapter = adapter
        controller.didOpenWindow(adapter)
        controller.didFocusWindow(adapter)
    }

    private func syncActiveTab(using page: BrowserPage) {
        guard let adapter = adapter(for: page),
              let tab = adapter.nativeTab,
              tab.tabManager?.activeTab?.id == tab.id,
              activeAdapter !== adapter
        else { return }

        let previous = activeAdapter
        activeAdapter = adapter
        controller.didActivateTab(adapter, previousActiveTab: previous)
    }
}

extension ExtensionCompatibilityManager: WKWebExtensionControllerDelegate {
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        focusedWindow.map { [$0] } ?? []
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        focusedWindow
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        // Keep permission semantics centralized. A proper product prompt can replace
        // this without changing the WebExtensions bridge.
        completionHandler(permissions, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns patterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        completionHandler(patterns, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        completionHandler(urls, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        guard let source = openTabs.first(where: { $0.nativeTab?.tabManager != nil }),
              let tab = source.nativeTab,
              let tabManager = tab.tabManager,
              let historyManager = tab.historyManager
        else {
            completionHandler(nil, CompatibilityError.noBrowserContext)
            return
        }

        let url = configuration.url ?? URL(string: "about:blank")!
        guard let created = tabManager.openTab(
            url: url,
            historyManager: historyManager,
            downloadManager: tab.downloadManager,
            focusAfterOpening: true,
            isPrivate: tab.isPrivate,
            loadSilently: true
        ), let page = created.browserPage else {
            completionHandler(nil, CompatibilityError.tabCreationFailed)
            return
        }

        register(page)
        completionHandler(adapter(for: page), nil)
    }
}

enum CompatibilityError: LocalizedError {
    case noBrowserContext
    case tabCreationFailed
    case tabClosed

    var errorDescription: String? {
        switch self {
        case .noBrowserContext: "No Ora browser window is available"
        case .tabCreationFailed: "Ora could not create the requested tab"
        case .tabClosed: "The requested tab is no longer available"
        }
    }
}
