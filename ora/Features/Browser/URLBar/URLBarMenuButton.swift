import AppKit
import SwiftUI
@preconcurrency import WebKit

struct URLBarMenuButton: View {
    @EnvironmentObject private var tabManager: TabManager
    @StateObject private var extensionManager = ExtensionManager.shared

    let foregroundColor: Color
    let onShare: (NSView, NSRect) -> Void

    @State private var isHovering = false
    @State private var isExtensionsHovering = false
    @State private var menuSourceView: NSView?
    @State private var extensionsMenuSourceView: NSView?

    private var cornerRadius: CGFloat {
        if #available(macOS 26, *) {
            return 10
        } else {
            return 6
        }
    }

    private var hasEnabledExtensions: Bool {
        extensionManager.installedExtensions.contains { $0.isEnabled }
    }

    var body: some View {
        HStack(spacing: 0) {
            if hasEnabledExtensions {
                Button {
                    showExtensionsMenu()
                } label: {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(
                            isExtensionsHovering ? foregroundColor : foregroundColor.opacity(0.7)
                        )
                        .frame(width: 30, height: 30)
                        .background(
                            ConditionallyConcentricRectangle(cornerRadius: cornerRadius)
                                .fill(isExtensionsHovering ? foregroundColor.opacity(0.1) : Color.clear)
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .onHover { hovering in
                    isExtensionsHovering = hovering
                }
                .help("Extensions")
                .accessibilityLabel(Text("Extensions"))
                .background(
                    MenuSourceView { nsView in
                        extensionsMenuSourceView = nsView
                    }
                )
            }

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
    }

    private func showExtensionsMenu() {
        guard let sourceView = extensionsMenuSourceView,
              let activeTab = tabManager.activeTab
        else { return }

        let menu = NSMenu()
        let actions = extensionActions(for: activeTab)

        if actions.isEmpty {
            let emptyItem = NSMenuItem(
                title: "No extension actions on this page",
                action: nil,
                keyEquivalent: ""
            )
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for entry in actions {
                let item = NSMenuItem(
                    title: entry.menuTitle,
                    action: #selector(MenuActions.performAction(_:)),
                    keyEquivalent: ""
                )
                item.image = entry.action.icon(for: CGSize(width: 16, height: 16))
                item.isEnabled = entry.action.isEnabled
                item.toolTip = entry.extensionName

                let delegate = MenuActions {
                    entry.context.performAction(for: entry.tab)
                }
                item.target = delegate
                item.representedObject = delegate
                menu.addItem(item)
            }
        }

        let point = NSPoint(x: 0, y: sourceView.bounds.height + 4)
        menu.popUp(positioning: nil, at: point, in: sourceView)
    }

    private func extensionActions(for activeTab: Tab) -> [ExtensionActionEntry] {
        extensionManager.controller.extensionContexts.compactMap { context in
            guard let tab = context.openTabs
                .compactMap({ $0.base as? OraWebExtensionTab })
                .first(where: { $0.tab?.id == activeTab.id }),
                let action = context.action(for: tab)
            else {
                return nil
            }

            return ExtensionActionEntry(
                context: context,
                tab: tab,
                action: action,
                extensionName: context.webExtension.displayName ?? "Extension"
            )
        }
        .sorted { lhs, rhs in
            lhs.menuTitle.localizedCaseInsensitiveCompare(rhs.menuTitle) == .orderedAscending
        }
    }

    private func showMenu() {
        guard let sourceView = menuSourceView else { return }

        let menu = NSMenu()

        let shareItem = NSMenuItem(
            title: "Share link",
            action: #selector(MenuActions.shareAction(_:)),
            keyEquivalent: ""
        )
        let delegate = MenuActions { [sourceView] in
            let rect = sourceView.bounds
            onShare(sourceView, rect)
        }
        shareItem.target = delegate
        shareItem.representedObject = delegate // prevent deallocation
        menu.addItem(shareItem)

        let point = NSPoint(x: 0, y: sourceView.bounds.height + 4)
        menu.popUp(positioning: nil, at: point, in: sourceView)
    }
}

private struct ExtensionActionEntry {
    let context: WKWebExtensionContext
    let tab: OraWebExtensionTab
    let action: WKWebExtension.Action
    let extensionName: String

    var menuTitle: String {
        let label = action.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = label.isEmpty ? extensionName : label
        let badge = action.badgeText.trimmingCharacters(in: .whitespacesAndNewlines)
        return badge.isEmpty ? title : "\(title)  \(badge)"
    }
}

private class MenuActions: NSObject {
    let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func shareAction(_ sender: Any?) {
        handler()
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
