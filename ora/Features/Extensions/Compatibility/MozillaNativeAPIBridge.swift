import Foundation
@preconcurrency import WebKit

@MainActor
final class MozillaNativeAPIBridge {
    static let shared = MozillaNativeAPIBridge()
    static let applicationIdentifier = "com.orabrowser.ora.mozilla"

    enum BridgeError: LocalizedError {
        case invalidMessage
        case permissionDenied(String)
        case unsupportedNamespace(String)
        case unsupportedMethod(String, String)
        case unavailableBrowserWindow
        case invalidArguments(String)
        case itemNotFound(String)

        var errorDescription: String? {
            switch self {
            case .invalidMessage:
                return "Ora received an invalid Mozilla compatibility bridge message."
            case let .permissionDenied(permission):
                return "The extension does not have the \(permission) permission."
            case let .unsupportedNamespace(namespace):
                return "Ora does not implement browser.\(namespace) through the native compatibility bridge."
            case let .unsupportedMethod(namespace, method):
                return "Ora does not implement browser.\(namespace).\(method) through the native compatibility bridge."
            case .unavailableBrowserWindow:
                return "No Ora browser window is available for this extension request."
            case let .invalidArguments(message):
                return message
            case let .itemNotFound(message):
                return message
            }
        }
    }

    private struct PortRegistration {
        let port: WKWebExtension.MessagePort
        let context: WKWebExtensionContext
    }

    private var ports: [ObjectIdentifier: PortRegistration] = [:]

    private init() {}

    func connect(port: WKWebExtension.MessagePort, context: WKWebExtensionContext) throws {
        guard port.applicationIdentifier == Self.applicationIdentifier else {
            throw BridgeError.invalidMessage
        }

        let key = ObjectIdentifier(port)
        ports[key] = PortRegistration(port: port, context: context)
        port.disconnectHandler = { [weak self, weak port] _ in
            guard let self, let port else { return }
            self.ports.removeValue(forKey: ObjectIdentifier(port))
        }
    }

    func emit(namespace: String, event: String, arguments: [Any]) {
        let message: [String: Any] = [
            "ora": "mozilla-event",
            "namespace": namespace,
            "event": event,
            "args": arguments
        ]

        for (key, registration) in ports {
            let port = registration.port
            guard !port.isDisconnected else {
                ports.removeValue(forKey: key)
                continue
            }
            guard ExtensionManager.shared.hasBridgeAccess(
                to: namespace,
                for: registration.context
            ) else {
                continue
            }
            port.sendMessage(message) { [weak self, weak port] error in
                guard error != nil, let self, let port else { return }
                self.ports.removeValue(forKey: ObjectIdentifier(port))
            }
        }
    }

    func handleMessage(
        _ message: Any,
        for extensionContext: WKWebExtensionContext,
        manager: ExtensionManager
    ) async throws -> Any {
        let request = try bridgeRequest(from: message)
        try requirePermission(
            for: request.namespace,
            context: extensionContext,
            manager: manager
        )

        switch request.namespace {
        case "history":
            return try MozillaHistoryAPI.handle(
                method: request.method,
                arguments: request.arguments,
                context: extensionContext
            )
        case "topSites":
            return try MozillaTopSitesAPI.handle(
                method: request.method,
                arguments: request.arguments,
                context: extensionContext
            )
        case "search":
            return try MozillaSearchAPI.handle(
                method: request.method,
                arguments: request.arguments,
                context: extensionContext
            )
        default:
            throw BridgeError.unsupportedNamespace(request.namespace)
        }
    }

    private func bridgeRequest(from message: Any) throws -> BridgeRequest {
        guard let payload = message as? [String: Any],
              payload["ora"] as? String == "mozilla-api",
              let namespace = payload["namespace"] as? String,
              let method = payload["method"] as? String
        else {
            throw BridgeError.invalidMessage
        }
        return BridgeRequest(
            namespace: namespace,
            method: method,
            arguments: payload["args"] as? [Any] ?? []
        )
    }

    private func requirePermission(
        for namespace: String,
        context: WKWebExtensionContext,
        manager: ExtensionManager
    ) throws {
        guard ["history", "topSites", "search"].contains(namespace) else { return }
        guard manager.hasBridgeAccess(to: namespace, for: context) else {
            throw BridgeError.permissionDenied(namespace)
        }
    }
}

private struct BridgeRequest {
    let namespace: String
    let method: String
    let arguments: [Any]
}
