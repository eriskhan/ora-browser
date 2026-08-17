import AppKit
import Foundation
@preconcurrency import WebKit

@MainActor
final class OraChromeExtensionAPIHost {
    enum BridgeError: LocalizedError {
        case invalidHost
        case invalidRequest
        case missingSpace
        case invalidArguments(String)
        case unsupportedMethod(String, String)
        case unavailableOnMacOS(String)
        case requiresChromiumProtocol(String)
        case eventResponseTimedOut(String, String)

        var errorDescription: String? {
            switch self {
            case .invalidHost:
                return "The requested native messaging host is not available."
            case .invalidRequest:
                return "The Ora extension bridge received an invalid request."
            case .missingSpace:
                return "The extension is not associated with an Ora space."
            case let .invalidArguments(message):
                return message
            case let .unsupportedMethod(namespace, method):
                return "Ora does not yet implement chrome.\(namespace).\(method)."
            case let .unavailableOnMacOS(namespace):
                return "chrome.\(namespace) is platform-specific and has no faithful Ora/macOS implementation."
            case let .requiresChromiumProtocol(namespace):
                return "chrome.\(namespace) depends on Chromium-specific protocols that WebKit does not expose."
            case let .eventResponseTimedOut(namespace, event):
                return "The extension did not respond to chrome.\(namespace).\(event) before the timeout."
            }
        }

        var code: String {
            switch self {
            case .invalidHost: "ORA_INVALID_NATIVE_HOST"
            case .invalidRequest: "ORA_INVALID_EXTENSION_REQUEST"
            case .missingSpace: "ORA_EXTENSION_SPACE_UNAVAILABLE"
            case .invalidArguments: "ORA_INVALID_ARGUMENTS"
            case .unsupportedMethod: "ORA_UNSUPPORTED_EXTENSION_METHOD"
            case .unavailableOnMacOS: "ORA_PLATFORM_API_UNAVAILABLE"
            case .requiresChromiumProtocol: "ORA_CHROMIUM_PROTOCOL_REQUIRED"
            case .eventResponseTimedOut: "ORA_EXTENSION_EVENT_TIMEOUT"
            }
        }
    }

    final class BridgeDownload {
        let id: Int
        let spaceID: UUID
        let url: URL
        let startedAt = Date()
        var filename: String
        var destinationURL: URL?
        var endedAt: Date?
        var error: String?
        var state = "in_progress"
        var paused = false
        var task: URLSessionDownloadTask?

        init(id: Int, spaceID: UUID, url: URL, filename: String) {
            self.id = id
            self.spaceID = spaceID
            self.url = url
            self.filename = filename
        }

        func dictionary() -> [String: Any] {
            let bytesReceived = task?.progress.completedUnitCount ?? 0
            let totalBytes = task?.progress.totalUnitCount ?? -1
            var value: [String: Any] = [
                "id": id,
                "url": url.absoluteString,
                "finalUrl": url.absoluteString,
                "filename": destinationURL?.path ?? filename,
                "incognito": false,
                "danger": "safe",
                "mime": "",
                "startTime": ISO8601DateFormatter().string(from: startedAt),
                "endTime": endedAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
                "estimatedEndTime": NSNull(),
                "state": state,
                "paused": paused,
                "canResume": state == "in_progress",
                "error": error ?? NSNull(),
                "bytesReceived": bytesReceived,
                "totalBytes": max(totalBytes, 0),
                "fileSize": max(totalBytes, 0),
                "exists": destinationURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            ]
            if state == "complete" {
                value["canResume"] = false
            }
            return value
        }
    }

    struct ConnectedPort {
        let port: WKWebExtension.MessagePort
        let spaceID: UUID
        let runtimeIdentifier: String
    }

    private struct PendingEventResponse {
        let continuation: CheckedContinuation<Any?, Error>
        let timeoutTask: Task<Void, Never>
    }

    static let shared = OraChromeExtensionAPIHost()
    static let applicationIdentifier = OraChromeAPIBridgeScript.applicationIdentifier

    var eventPorts: [ObjectIdentifier: ConnectedPort] = [:]
    private var pendingEventResponses: [String: PendingEventResponse] = [:]
    var downloads: [Int: BridgeDownload] = [:]
    var nextDownloadID = 1
    var idleDetectionInterval: TimeInterval = 60
    var idleTimer: Timer?
    var lastIdleState: String?
    var powerActivity: NSObjectProtocol?
    let speechSynthesizer = NSSpeechSynthesizer()

    private init() {}

    func handleNativeMessage(
        _ message: Any,
        applicationIdentifier: String?,
        extensionContext: WKWebExtensionContext,
        replyHandler: @escaping (Any?, (any Error)?) -> Void
    ) {
        guard applicationIdentifier == Self.applicationIdentifier else {
            replyHandler(errorResponse(BridgeError.invalidHost), nil)
            return
        }
        guard let request = message as? [String: Any], request["kind"] as? String == "call",
              let namespace = request["namespace"] as? String,
              let method = request["method"] as? String
        else {
            replyHandler(errorResponse(BridgeError.invalidRequest), nil)
            return
        }

        let args = request["args"] as? [Any] ?? []
        Task { @MainActor in
            do {
                let value = try await dispatch(
                    namespace: namespace,
                    method: method,
                    args: args,
                    extensionContext: extensionContext
                )
                replyHandler(["ok": true, "result": value ?? NSNull()], nil)
            } catch let bridgeError as BridgeError {
                replyHandler(errorResponse(bridgeError), nil)
            } catch {
                replyHandler([
                    "ok": false,
                    "error": ["code": "ORA_EXTENSION_API_ERROR", "message": error.localizedDescription]
                ], nil)
            }
        }
    }

    func connectNativePort(
        _ port: WKWebExtension.MessagePort,
        extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard port.applicationIdentifier == Self.applicationIdentifier else {
            completionHandler(BridgeError.invalidHost)
            return
        }
        guard let spaceID = WebExtensionManager.shared.spaceID(for: extensionContext) else {
            completionHandler(BridgeError.missingSpace)
            return
        }

        let identifier = ObjectIdentifier(port)
        let runtimeIdentifier = WebExtensionManager.shared.installedExtension(for: extensionContext)?.runtimeIdentifier
            ?? extensionContext.uniqueIdentifier
        eventPorts[identifier] = ConnectedPort(
            port: port,
            spaceID: spaceID,
            runtimeIdentifier: runtimeIdentifier
        )
        port.messageHandler = { [weak self] message, error in
            Task { @MainActor in
                self?.handlePortMessage(message, error: error)
            }
        }
        port.disconnectHandler = { [weak self] _ in
            Task { @MainActor in
                self?.eventPorts[identifier] = nil
            }
        }
        startIdleMonitoringIfNeeded()
        completionHandler(nil)
    }

    func emit(
        namespace: String,
        event: String,
        args: [Any],
        spaceID: UUID? = nil,
        runtimeIdentifier: String? = nil
    ) {
        let message: [String: Any] = [
            "kind": "event",
            "namespace": namespace,
            "event": event,
            "args": args
        ]
        for connected in eventPorts.values where
            (spaceID == nil || connected.spaceID == spaceID) &&
            (runtimeIdentifier == nil || connected.runtimeIdentifier == runtimeIdentifier)
        {
            connected.port.sendMessage(message, completionHandler: nil)
        }
    }

    func requestEvent(
        namespace: String,
        event: String,
        args: [Any],
        spaceID: UUID? = nil,
        runtimeIdentifier: String? = nil,
        timeout: TimeInterval = 8
    ) async throws -> Any? {
        let matchingPorts = eventPorts.values.filter { connected in
            (spaceID == nil || connected.spaceID == spaceID) &&
                (runtimeIdentifier == nil || connected.runtimeIdentifier == runtimeIdentifier) &&
                !connected.port.isDisconnected
        }
        guard let connected = matchingPorts.first else {
            return nil
        }

        let requestID = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { @MainActor [weak self] in
                let nanoseconds = UInt64(max(timeout, 0.1) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                self?.completeEventResponse(
                    requestID: requestID,
                    result: Swift.Result.failure(BridgeError.eventResponseTimedOut(namespace, event))
                )
            }
            pendingEventResponses[requestID] = PendingEventResponse(
                continuation: continuation,
                timeoutTask: timeoutTask
            )

            connected.port.sendMessage([
                "kind": "event",
                "namespace": namespace,
                "event": event,
                "args": args,
                "requestId": requestID,
                "expectsResponse": true
            ]) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in
                    self?.completeEventResponse(requestID: requestID, result: Swift.Result.failure(error))
                }
            }
        }
    }

    func tabManager(for spaceID: UUID) throws -> TabManager {
        guard let manager = WebExtensionPermissionPrompter.shared.tabManager(for: spaceID) else {
            throw BridgeError.missingSpace
        }
        return manager
    }

    func dictionaryArgument(_ args: [Any], at index: Int = 0) -> [String: Any] {
        guard args.indices.contains(index) else { return [:] }
        return args[index] as? [String: Any] ?? [:]
    }

    func numberArgument(_ args: [Any], at index: Int) -> NSNumber? {
        guard args.indices.contains(index) else { return nil }
        return args[index] as? NSNumber
    }

    func stringArgument(_ args: [Any], at index: Int) -> String? {
        guard args.indices.contains(index) else { return nil }
        return args[index] as? String
    }

    private func handlePortMessage(_ message: Any?, error: (any Error)?) {
        if error != nil { return }
        guard let payload = message as? [String: Any],
              payload["kind"] as? String == "eventResponse",
              let requestID = payload["requestId"] as? String
        else {
            return
        }

        if let errorPayload = payload["error"] as? [String: Any],
           let message = errorPayload["message"] as? String,
           !message.isEmpty
        {
            completeEventResponse(
                requestID: requestID,
                result: Swift.Result.failure(NSError(
                    domain: "Ora.WebExtension.EventResponse",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message]
                ))
            )
            return
        }

        let value = payload["result"]
        completeEventResponse(
            requestID: requestID,
            result: Swift.Result.success(value is NSNull ? nil : value)
        )
    }

    private func completeEventResponse(
        requestID: String,
        result: Swift.Result<Any?, Error>
    ) {
        guard let pending = pendingEventResponses.removeValue(forKey: requestID) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(with: result)
    }

    private func dispatch(
        namespace: String,
        method: String,
        args: [Any],
        extensionContext: WKWebExtensionContext
    ) async throws -> Any? {
        guard let spaceID = WebExtensionManager.shared.spaceID(for: extensionContext) else {
            throw BridgeError.missingSpace
        }

        if let routed = try await OraChromeExtensionAPIPluginRouter.route(
            namespace: namespace,
            method: method,
            args: args,
            spaceID: spaceID,
            context: extensionContext
        ) {
            return routed.value
        }

        if namespace.hasPrefix("accessibilityFeatures.") {
            return try handleAccessibilitySetting(namespace: namespace, method: method, args: args)
        }
        if namespace.hasPrefix("contentSettings.") {
            return try handleContentSetting(namespace: namespace, method: method, args: args)
        }
        if namespace.hasPrefix("privacy.") {
            return try handlePrivacySetting(namespace: namespace, method: method, args: args)
        }
        if namespace == "proxy.settings" {
            return try handleProxySetting(method: method, args: args, spaceID: spaceID)
        }

        switch namespace {
        case "browsingData":
            return try await handleBrowsingData(method: method, args: args, spaceID: spaceID)
        case "dns":
            return try handleDNS(method: method, args: args)
        case "downloads":
            return try await handleDownloads(method: method, args: args, spaceID: spaceID)
        case "enterprise.hardwarePlatform":
            return try handleEnterpriseHardwarePlatform(method: method)
        case "fontSettings":
            return try handleFontSettings(method: method, args: args)
        case "history":
            return try handleHistory(method: method, args: args, spaceID: spaceID)
        case "identity":
            return try await handleIdentity(method: method, args: args, context: extensionContext)
        case "idle":
            return try handleIdle(method: method, args: args)
        case "management":
            return try await handleManagement(method: method, args: args, spaceID: spaceID, context: extensionContext)
        case "omnibox":
            return try WebExtensionOmniboxCoordinator.shared.handle(method: method, args: args, context: extensionContext)
        case "pageCapture":
            return try await handlePageCapture(method: method, args: args, spaceID: spaceID)
        case "power":
            return try handlePower(method: method, args: args)
        case "processes":
            return try handleProcesses(method: method, args: args)
        case "readingList":
            return try handleReadingList(method: method, args: args)
        case "search":
            return try handleSearch(method: method, args: args, spaceID: spaceID)
        case "sessions":
            return try handleSessions(method: method, args: args, spaceID: spaceID)
        case "system.cpu":
            return try handleSystemCPU(method: method)
        case "system.display":
            return try handleSystemDisplay(method: method)
        case "system.memory":
            return try handleSystemMemory(method: method)
        case "system.storage":
            return try handleSystemStorage(method: method)
        case "systemLog":
            return try handleSystemLog(method: method, args: args)
        case "topSites":
            return try handleTopSites(method: method, spaceID: spaceID)
        case "tts":
            return try handleTTS(method: method, args: args)
        default:
            guard let support = ChromeExtensionAPICatalog.support(for: namespace) else {
                throw BridgeError.unsupportedMethod(namespace, method)
            }
            switch support {
            case .unavailableOnMacOS:
                throw BridgeError.unavailableOnMacOS(namespace)
            case .requiresChromiumProtocol:
                throw BridgeError.requiresChromiumProtocol(namespace)
            case .oraNativeBridge, .webKitNative:
                throw BridgeError.unsupportedMethod(namespace, method)
            }
        }
    }

    private func errorResponse(_ error: BridgeError) -> [String: Any] {
        [
            "ok": false,
            "error": ["code": error.code, "message": error.localizedDescription]
        ]
    }
}
