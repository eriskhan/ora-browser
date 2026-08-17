import AppKit
import SwiftUI
@preconcurrency import WebKit

extension WebExtensionPermissionPrompter {
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void
    ) {
        guard let spaceID = controller.configuration.identifier else {
            completionHandler(nil, webExtensionWindowError("The extension controller has no Ora space identifier."))
            return
        }
        guard !configuration.shouldBePrivate else {
            completionHandler(
                nil,
                webExtensionWindowError("Private extension windows require Ora's private extension profile support, which is not enabled yet.")
            )
            return
        }

        let requestedFrame = configuration.frame
        let hasRequestedFrame = requestedFrame.origin.x.isFinite &&
            requestedFrame.origin.y.isFinite &&
            requestedFrame.width.isFinite &&
            requestedFrame.height.isFinite &&
            requestedFrame.width > 0 && requestedFrame.height > 0
        let size = hasRequestedFrame ? requestedFrame.size : CGSize(width: 1100, height: 760)
        let browserWindow = WindowFactory.makeMainWindow(rootView: OraRoot(), size: size)
        if hasRequestedFrame {
            browserWindow.setFrame(requestedFrame, display: true, animate: false)
        }
        if !configuration.shouldBeFocused {
            browserWindow.orderBack(nil)
        }

        resolveTabManager(for: browserWindow, spaceID: spaceID, attempt: 0) { [weak self] tabManager in
            guard let self else {
                completionHandler(
                    nil,
                    NSError(
                        domain: "Ora.WebExtension.WindowDelegate",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "The extension window host was released."]
                    )
                )
                return
            }
            guard let tabManager else {
                browserWindow.close()
                completionHandler(nil, self.webExtensionWindowError("Ora could not initialize the new browser window."))
                return
            }
            guard let targetContainer = tabManager.containers.first(where: { $0.id == spaceID }) else {
                browserWindow.close()
                completionHandler(nil, self.webExtensionWindowError("The requested Ora space is unavailable in the new window."))
                return
            }

            tabManager.activateContainer(targetContainer, activateLastAccessedTab: false)
            let historyManager = HistoryManager(
                modelContainer: tabManager.modelContainer,
                modelContext: tabManager.modelContext
            )
            var openedTab: Tab?

            for existingTab in configuration.tabs.compactMap({ $0 as? OraWebExtensionTab }) {
                if let tab = existingTab.tab, tab.container.id == spaceID {
                    tabManager.activateTab(tab)
                    openedTab = tab
                }
            }

            for url in configuration.tabURLs {
                if url.scheme == extensionContext.baseURL.scheme, url.host == extensionContext.baseURL.host {
                    continue
                }
                openedTab = tabManager.openTab(
                    url: url,
                    historyManager: historyManager,
                    focusAfterOpening: true,
                    isPrivate: false,
                    loadSilently: true
                ) ?? openedTab
            }

            if configuration.tabURLs.isEmpty, configuration.tabs.isEmpty, tabManager.activeTab == nil {
                openedTab = tabManager.openTab(
                    url: URL(string: "about:blank")!,
                    historyManager: historyManager,
                    focusAfterOpening: true,
                    isPrivate: false,
                    loadSilently: true
                )
            }

            if let openedTab, openedTab.browserPage == nil {
                openedTab.restoreTransientState(
                    historyManager: historyManager,
                    downloadManager: DownloadManager(
                        modelContainer: tabManager.modelContainer,
                        modelContext: tabManager.modelContext
                    ),
                    tabManager: tabManager,
                    isPrivate: false
                )
            }

            let adapter = self.windowAdapter(for: tabManager, spaceID: spaceID)
            adapter.declaredWindowType = configuration.windowType
            controller.didOpenWindow(adapter)

            adapter.setWindowState(configuration.windowState, for: extensionContext) { _ in
                if configuration.shouldBeFocused {
                    browserWindow.makeKeyAndOrderFront(nil)
                    controller.didFocusWindow(adapter)
                }
                completionHandler(adapter, nil)
            }
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let url = extensionContext.optionsPageURL else {
            completionHandler(webExtensionWindowError("This extension does not provide an options page."))
            return
        }

        do {
            try WebExtensionPagePresenter.shared.present(
                url: url,
                context: extensionContext,
                title: "\(extensionContext.webExtension.displayName ?? "Extension") Options"
            )
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    private func resolveTabManager(
        for browserWindow: NSWindow,
        spaceID: UUID,
        attempt: Int,
        completion: @escaping (TabManager?) -> Void
    ) {
        if let manager = tabManager(for: spaceID) {
            let activeWindowMatches = manager.activeTab?.pageWindow.map { $0 === browserWindow } ?? false
            let anyWindowMatches = manager.containers
                .flatMap(\.tabs)
                .contains { tab in
                    guard let pageWindow = tab.pageWindow else { return false }
                    return pageWindow === browserWindow
                }
            if activeWindowMatches || anyWindowMatches {
                completion(manager)
                return
            }
        }

        guard attempt < 40 else {
            completion(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else {
                completion(nil)
                return
            }
            self.resolveTabManager(
                for: browserWindow,
                spaceID: spaceID,
                attempt: attempt + 1,
                completion: completion
            )
        }
    }

    private func webExtensionWindowError(_ message: String) -> NSError {
        NSError(
            domain: "Ora.WebExtension.WindowDelegate",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
