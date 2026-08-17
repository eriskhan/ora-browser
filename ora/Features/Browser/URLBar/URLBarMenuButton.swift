import AppKit
import SwiftUI
@preconcurrency import WebKit

struct URLBarMenuButton: View {
    @EnvironmentObject private var tabManager: TabManager

    let foregroundColor: Color
    let onShare: (NSView, NSRect) -> Void

    @State private var isHovering = false
    @State private var menuSourceView: NSView?

    private var cornerRadius: CGFloat {
        if #available(macOS 26, *) {
            return 10
        } else {
            return 6
        }
    }

    var body: some View {
        Button {
            showMenu()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isHovering ? foregroundColor : foregroundColor.opacity(0.7))
                .frame(width: 30, height: 30)
                .background(
                    ConditionallyConcentricRectangle(cornerRadius: cornerRadius)
                        .fill(isHovering ? foregroundColor.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            isHovering = hovering
        }
        .background(
            MenuSourceView { nsView in
                menuSourceView = nsView
            }
        )
    }

    private func showMenu() {
        guard let sourceView = menuSourceView else { return }

        let menu = NSMenu()
        addExtensionItems(to: menu, sourceView: sourceView)

        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }

        let shareItem = NSMenuItem(
            title: "Share link",
            action: #selector(MenuActions.performAction(_:)),
            keyEquivalent: ""
        )
        let delegate = MenuActions { [sourceView] in
            let rect = sourceView.bounds
            onShare(sourceView, rect)
        }
        shareItem.target = delegate
        shareItem.representedObject = delegate
        menu.addItem(shareItem)

        let point = NSPoint(x: 0, y: sourceView.bounds.height + 4)
        menu.popUp(positioning: nil, at: point, in: sourceView)
    }

    private func addExtensionItems(to menu: NSMenu, sourceView: NSView) {
        guard let activeTab = tabManager.activeTab, !activeTab.isPrivate else { return }

        Task { @MainActor in
            await OraDeclarativeContentManager.shared.evaluate(tab: activeTab)
        }

        let tabAdapter = OraWebExtensionTabCache.shared.adapter(for: activeTab)
        let loadedExtensions = WebExtensionManager.shared.loadedExtensions(in: activeTab.container.id)
        let actionEntries = loadedExtensions.compactMap { entry -> (
            InstalledWebExtension,
            WKWebExtensionContext,
            WKWebExtension.Action
        )? in
            let (installedExtension, context) = entry
            guard let action = context.action(for: tabAdapter) else { return nil }
            return (installedExtension, context, action)
        }

        guard !actionEntries.isEmpty else { return }

        let extensionsItem = NSMenuItem(title: "Extensions", action: nil, keyEquivalent: "")
        let extensionsMenu = NSMenu(title: "Extensions")

        for (installedExtension, context, action) in actionEntries {
            let label = action.label.isEmpty ? installedExtension.name : action.label
            let item = NSMenuItem(
                title: label,
                action: #selector(MenuActions.performAction(_:)),
                keyEquivalent: ""
            )
            let declarativeEnabled = OraDeclarativeContentManager.shared.actionEnabled(
                runtimeIdentifier: installedExtension.runtimeIdentifier,
                tab: activeTab
            )
            item.isEnabled = action.isEnabled && (declarativeEnabled ?? true)
            item.image = OraDeclarativeContentManager.shared.actionIcon(
                runtimeIdentifier: installedExtension.runtimeIdentifier,
                tab: activeTab,
                size: CGSize(width: 16, height: 16)
            ) ?? action.icon(for: CGSize(width: 16, height: 16))

            let delegate = MenuActions { [sourceView] in
                WebExtensionPermissionPrompter.shared.performAction(
                    for: context,
                    tab: tabAdapter,
                    sourceView: sourceView
                )
            }
            item.target = delegate
            item.representedObject = delegate
            extensionsMenu.addItem(item)
        }

        extensionsItem.submenu = extensionsMenu
        menu.addItem(extensionsItem)
    }
}

private class MenuActions: NSObject {
    let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func performAction(_ sender: Any?) {
        handler()
    }
}

private struct MenuSourceView: NSViewRepresentable {
    let onViewCreated: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        DispatchQueue.main.async {
            onViewCreated(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
