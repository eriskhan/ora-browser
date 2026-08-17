import AppKit
import Foundation
@preconcurrency import WebKit

extension ExtensionManager {
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void
    ) {
        guard configuration.tabs.isEmpty else {
            completionHandler(
                nil,
                windowCreationError(
                    "Ora cannot move an existing tab into a newly created window yet."
                )
            )
            return
        }
        guard !configuration.shouldBePrivate || extensionContext.hasAccessToPrivateData else {
            completionHandler(
                nil,
                windowCreationError(
                    "This extension does not have access to private Ora windows."
                )
            )
            return
        }

        let previousKeyWindow = NSApp.keyWindow
        let requestedFrame = configuration.frame
        let requestedSize = valid(frame: requestedFrame)
            ? requestedFrame.size
            : CGSize(width: 1440, height: 900)
        let newWindow = WindowFactory.makeMainWindow(
            rootView: OraRoot(isPrivate: configuration.shouldBePrivate),
            size: requestedSize
        )

        if valid(frame: requestedFrame) {
            newWindow.setFrame(requestedFrame, display: true, animate: false)
        }
        if configuration.windowType == .popup {
            newWindow.styleMask.remove(.miniaturizable)
        }

        Task { @MainActor in
            guard let wrapper = await waitForExtensionWindow(
                newWindow,
                context: extensionContext
            ) else {
                newWindow.close()
                completionHandler(
                    nil,
                    windowCreationError("Ora could not register the new extension window.")
                )
                return
            }

            wrapper.extensionWindowType = configuration.windowType
            configureInitialTabs(
                configuration.tabURLs,
                in: wrapper
            )
            wrapper.setWindowState(
                configuration.windowState,
                for: extensionContext
            ) { _ in }

            if configuration.shouldBeFocused {
                newWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                newWindow.orderBack(nil)
                previousKeyWindow?.makeKeyAndOrderFront(nil)
            }
            completionHandler(wrapper, nil)
        }
    }

    private func configureInitialTabs(
        _ urls: [URL],
        in window: OraWebExtensionWindow
    ) {
        guard let tabManager = window.tabManager else { return }
        let historyManager = HistoryManager(
            modelContainer: tabManager.modelContainer,
            modelContext: tabManager.modelContext
        )
        let downloadManager = DownloadManager(
            modelContainer: tabManager.modelContainer,
            modelContext: tabManager.modelContext
        )
        let requestedURLs = urls.isEmpty ? [URL(string: "about:blank")!] : urls

        for (index, url) in requestedURLs.enumerated() {
            if url.host != nil {
                _ = tabManager.openTab(
                    url: url,
                    historyManager: historyManager,
                    downloadManager: downloadManager,
                    focusAfterOpening: index == 0,
                    isPrivate: window.isPrivateWindow,
                    loadSilently: true
                )
            } else {
                let container = tabManager.activeContainer ?? tabManager.createContainer()
                let tab = tabManager.addTab(
                    url: url,
                    container: container,
                    historyManager: historyManager,
                    downloadManager: downloadManager,
                    isPrivate: window.isPrivateWindow
                )
                if index != 0, let first = container.tabs.first {
                    tabManager.activateTab(first)
                    tab.maybeIsActive = false
                }
            }
        }
    }

    private func waitForExtensionWindow(
        _ window: NSWindow,
        context: WKWebExtensionContext
    ) async -> OraWebExtensionWindow? {
        for _ in 0..<200 {
            if let wrapper = context.openWindows
                .compactMap({ $0 as? OraWebExtensionWindow })
                .first(where: { $0.window === window })
            {
                return wrapper
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    private func valid(frame: CGRect) -> Bool {
        frame.width.isFinite && frame.height.isFinite &&
            frame.origin.x.isFinite && frame.origin.y.isFinite &&
            frame.width > 0 && frame.height > 0
    }

    private func windowCreationError(_ message: String) -> NSError {
        NSError(
            domain: "Ora.WebExtension.WindowCreation",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
