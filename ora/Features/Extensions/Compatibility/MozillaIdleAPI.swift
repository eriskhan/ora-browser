import CoreGraphics
import Foundation
@preconcurrency import WebKit

@MainActor
enum MozillaIdleAPI {
    private static var detectionIntervals: [String: TimeInterval] = [:]
    private static var lastStates: [String: String] = [:]
    private static var timers: [String: Timer] = [:]

    static func handle(
        method: String,
        arguments: [Any],
        context: WKWebExtensionContext,
        manager: ExtensionManager
    ) throws -> Any {
        try MozillaNativeAPIRouter.require("idle", context: context, manager: manager)
        let extensionID = context.uniqueIdentifier

        switch method {
        case "queryState":
            guard let threshold = seconds(arguments.first), threshold >= 0 else {
                throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                    "browser.idle.queryState requires a non-negative detection interval."
                )
            }
            return currentState(threshold: threshold)

        case "setDetectionInterval":
            guard let threshold = seconds(arguments.first), threshold >= 15 else {
                throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                    "browser.idle.setDetectionInterval requires at least 15 seconds."
                )
            }
            detectionIntervals[extensionID] = threshold
            if timers[extensionID] != nil {
                lastStates[extensionID] = currentState(threshold: threshold)
                restartTimer(for: extensionID)
            }
            return NSNull()

        case "__subscribe":
            if timers[extensionID] == nil {
                let threshold = detectionIntervals[extensionID] ?? 60
                lastStates[extensionID] = currentState(threshold: threshold)
                restartTimer(for: extensionID)
            }
            return NSNull()

        case "__unsubscribe":
            timers[extensionID]?.invalidate()
            timers[extensionID] = nil
            lastStates[extensionID] = nil
            return NSNull()

        default:
            throw MozillaNativeAPIBridge.BridgeError.unsupportedMethod("idle", method)
        }
    }

    private static func restartTimer(for extensionID: String) {
        timers[extensionID]?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                poll(extensionID: extensionID)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        timers[extensionID] = timer
    }

    private static func poll(extensionID: String) {
        let threshold = detectionIntervals[extensionID] ?? 60
        let state = currentState(threshold: threshold)
        guard lastStates[extensionID] != state else { return }
        lastStates[extensionID] = state
        MozillaNativeAPIBridge.shared.emit(
            namespace: "idle",
            event: "__ora_targeted__",
            arguments: [extensionID, "onStateChanged", [state]]
        )
    }

    private static func currentState(threshold: TimeInterval) -> String {
        if isScreenLocked() {
            return "locked"
        }
        let idleSeconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: .null
        )
        return idleSeconds >= threshold ? "idle" : "active"
    }

    private static func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private static func seconds(_ value: Any?) -> TimeInterval? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        return value as? Double
    }
}
