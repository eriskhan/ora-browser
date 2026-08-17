import AppKit
@preconcurrency import WebKit

@MainActor
final class OraWebExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var tabManager: TabManager?
    let spaceID: UUID
    var declaredWindowType: WKWebExtension.WindowType = .normal

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

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        declaredWindowType
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = browserWindow else { return .normal }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        if window.isMiniaturized { return .minimized }
        if window.isZoomed { return .maximized }
        return .normal
    }

    func setWindowState(
        _ state: WKWebExtension.WindowState,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let window = browserWindow else {
            completionHandler(windowError("The Ora window is no longer available."))
            return
        }

        switch state {
        case .normal:
            if window.isMiniaturized { window.deminiaturize(nil) }
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            if window.isZoomed { window.zoom(nil) }
        case .minimized:
            window.miniaturize(nil)
        case .maximized:
            if window.isMiniaturized { window.deminiaturize(nil) }
            if !window.isZoomed { window.zoom(nil) }
        case .fullscreen:
            if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        @unknown default:
            completionHandler(windowError("The requested window state is not supported."))
            return
        }
        completionHandler(nil)
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        false
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        browserWindow?.screen?.frame ?? .null
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        browserWindow?.frame ?? .null
    }

    func setFrame(
        _ frame: CGRect,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let window = browserWindow,
              frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0
        else {
            completionHandler(windowError("A finite positive window frame is required."))
            return
        }
        window.setFrame(frame, display: true, animate: false)
        completionHandler(nil)
    }

    func focus(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let window = browserWindow else {
            completionHandler(windowError("The Ora window is no longer available."))
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        context.webExtensionController?.didFocusWindow(self)
        completionHandler(nil)
    }

    func close(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let window = browserWindow else {
            completionHandler(windowError("The Ora window is no longer available."))
            return
        }
        context.webExtensionController?.didCloseWindow(self)
        window.close()
        completionHandler(nil)
    }

    private func windowError(_ message: String) -> NSError {
        NSError(
            domain: "Ora.WebExtension.Window",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
