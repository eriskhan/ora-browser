import AppKit
import Foundation
@preconcurrency import WebKit

@MainActor
final class OraWebExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var tabManager: TabManager?
    weak var window: NSWindow?
    weak var owner: ExtensionManager?
    let isPrivateWindow: Bool
    var extensionWindowType: WKWebExtension.WindowType = .normal

    init(tabManager: TabManager, window: NSWindow?, isPrivate: Bool, owner: ExtensionManager) {
        self.tabManager = tabManager
        self.window = window
        self.owner = owner
        self.isPrivateWindow = isPrivate
        super.init()
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        owner?.tabs(in: self) ?? []
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        owner?.activeTab(in: self)
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        isPrivateWindow
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        window?.screen?.frame ?? .null
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        window?.frame ?? .null
    }

    func setFrame(
        _ frame: CGRect,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let window else {
            completionHandler(extensionError("The Ora window is no longer available."))
            return
        }
        window.setFrame(frame, display: true, animate: false)
        completionHandler(nil)
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        extensionWindowType
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window else { return .normal }
        if window.styleMask.contains(.fullScreen) {
            return .fullscreen
        }
        if window.isMiniaturized {
            return .minimized
        }
        if window.isZoomed {
            return .maximized
        }
        return .normal
    }

    func setWindowState(
        _ state: WKWebExtension.WindowState,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let window else {
            completionHandler(extensionError("The Ora window is no longer available."))
            return
        }

        switch state {
        case .fullscreen:
            if !window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
        case .maximized:
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
            if !window.isZoomed {
                window.zoom(nil)
            }
        case .minimized:
            if !window.isMiniaturized {
                window.miniaturize(nil)
            }
        case .normal:
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
            if window.isZoomed {
                window.zoom(nil)
            }
        @unknown default:
            completionHandler(extensionError("Ora does not recognize the requested window state."))
            return
        }
        completionHandler(nil)
    }

    func focus(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let window else {
            completionHandler(extensionError("The Ora window is no longer available."))
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        completionHandler(nil)
    }

    func close(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let window else {
            completionHandler(extensionError("The Ora window is no longer available."))
            return
        }
        window.performClose(nil)
        completionHandler(nil)
    }

    private func extensionError(_ message: String) -> NSError {
        NSError(
            domain: "Ora.WebExtension.Window",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
