import AppKit
import Foundation
@preconcurrency import WebKit

@MainActor
final class WebExtensionPermissionPrompter: NSObject, WKWebExtensionControllerDelegate {
    static let shared = WebExtensionPermissionPrompter()

    struct InitialAccessDecision {
        let permissions: Set<WKWebExtension.Permission>
        let matchPatterns: Set<WKWebExtension.MatchPattern>
    }

    func requestInitialAccess(for webExtension: WKWebExtension) -> InitialAccessDecision {
        let permissions = webExtension.requestedPermissions
        let matchPatterns = webExtension.requestedPermissionMatchPatterns
        guard !permissions.isEmpty || !matchPatterns.isEmpty else {
            return InitialAccessDecision(permissions: [], matchPatterns: [])
        }

        let details = permissionDescription(permissions: permissions, matchPatterns: matchPatterns)
        let allowed = showPrompt(
            extensionName: webExtension.displayName ?? "This extension",
            message: "Requests access when enabled in this Ora space:\n\n\(details)"
        )
        return InitialAccessDecision(
            permissions: allowed ? permissions : [],
            matchPatterns: allowed ? matchPatterns : []
        )
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        let allowed = showPrompt(
            extensionName: extensionContext.webExtension.displayName ?? "This extension",
            message: "Requests additional permissions:\n\n\(permissionDescription(permissions: permissions, matchPatterns: []))"
        )
        let granted = allowed ? permissions : []
        if allowed {
            WebExtensionManager.shared.recordGrantedPermissions(granted, for: extensionContext)
        }
        completionHandler(granted, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        let allowed = showPrompt(
            extensionName: extensionContext.webExtension.displayName ?? "This extension",
            message: "Requests access to these websites:\n\n\(permissionDescription(permissions: [], matchPatterns: matchPatterns))"
        )
        let granted = allowed ? matchPatterns : []
        if allowed {
            WebExtensionManager.shared.recordGrantedMatchPatterns(granted, for: extensionContext)
        }
        completionHandler(granted, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        let displayURLs = urls
            .map(\.absoluteString)
            .sorted()
            .prefix(12)
            .joined(separator: "\n")
        let allowed = showPrompt(
            extensionName: extensionContext.webExtension.displayName ?? "This extension",
            message: "Requests access to:\n\n\(displayURLs)"
        )
        completionHandler(allowed ? urls : [], nil)
    }

    private func showPrompt(extensionName: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow \(extensionName)?"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func permissionDescription(
        permissions: Set<WKWebExtension.Permission>,
        matchPatterns: Set<WKWebExtension.MatchPattern>
    ) -> String {
        var lines = permissions.map(\.rawValue).sorted()
        lines.append(contentsOf: matchPatterns.map(\.string).sorted())
        if lines.count > 12 {
            let remaining = lines.count - 12
            lines = Array(lines.prefix(12)) + ["…and \(remaining) more"]
        }
        return lines.joined(separator: "\n")
    }
}
