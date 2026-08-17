import Foundation
@preconcurrency import WebKit

@MainActor
enum MozillaPrivacyAPI {
    private enum Value: Equatable {
        case bool(Bool)
        case string(String)
    }

    private struct Assignment {
        let extensionID: String
        var value: Value
    }

    private struct ControlStack {
        let baseline: Value
        var assignments: [Assignment]
    }

    private static var controlStacks: [String: ControlStack] = [:]

    static func handle(
        method: String,
        arguments: [Any],
        context: WKWebExtensionContext,
        manager: ExtensionManager
    ) throws -> Any {
        try MozillaNativeAPIRouter.require("privacy", context: context, manager: manager)
        guard let setting = arguments.first as? String else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "A browser.privacy setting name is required."
            )
        }

        switch method {
        case "get":
            return try get(setting: setting, context: context)
        case "set":
            guard arguments.count >= 2 else {
                throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                    "browser.privacy BrowserSetting.set requires a value."
                )
            }
            return try set(
                setting: setting,
                rawValue: arguments[1],
                context: context
            )
        case "clear":
            return try clear(setting: setting, context: context)
        default:
            throw MozillaNativeAPIBridge.BridgeError.unsupportedMethod("privacy", method)
        }
    }

    private static func get(
        setting: String,
        context: WKWebExtensionContext
    ) throws -> [String: Any] {
        let value = try currentValue(setting: setting, context: context)
        return [
            "value": externalValue(value, setting: setting),
            "levelOfControl": levelOfControl(setting: setting, extensionID: context.uniqueIdentifier)
        ]
    }

    private static func set(
        setting: String,
        rawValue: Any,
        context: WKWebExtensionContext
    ) throws -> Bool {
        let value = try parse(rawValue, setting: setting)
        let extensionID = context.uniqueIdentifier
        var stack = controlStacks[setting] ?? ControlStack(
            baseline: try currentValue(setting: setting, context: context),
            assignments: []
        )
        stack.assignments.removeAll { $0.extensionID == extensionID }
        stack.assignments.append(Assignment(extensionID: extensionID, value: value))
        controlStacks[setting] = stack
        try apply(value, setting: setting, context: context)
        emitChange(setting: setting, value: value, extensionID: extensionID)
        return true
    }

    private static func clear(
        setting: String,
        context: WKWebExtensionContext
    ) throws -> Bool {
        let extensionID = context.uniqueIdentifier
        guard var stack = controlStacks[setting] else { return false }
        let controlledBefore = stack.assignments.last?.extensionID == extensionID
        stack.assignments.removeAll { $0.extensionID == extensionID }
        guard controlledBefore else {
            controlStacks[setting] = stack
            return false
        }

        let value = stack.assignments.last?.value ?? stack.baseline
        if stack.assignments.isEmpty {
            controlStacks.removeValue(forKey: setting)
        } else {
            controlStacks[setting] = stack
        }
        try apply(value, setting: setting, context: context)
        emitChange(setting: setting, value: value, extensionID: extensionID)
        return true
    }

    private static func currentValue(
        setting: String,
        context: WKWebExtensionContext
    ) throws -> Value {
        switch setting {
        case "websites.cookieConfig":
            let policy = activePrivacySettings(context: context)?.cookiesPolicy ?? SettingsStore.shared.cookiesPolicy
            return .string(cookieBehavior(for: policy))
        case "websites.trackingProtectionMode":
            let enabled = activePrivacySettings(context: context)?.blockThirdPartyTrackers ??
                SettingsStore.shared.blockThirdPartyTrackers
            return .string(enabled ? "always" : "never")
        case "websites.resistFingerprinting":
            let enabled = activePrivacySettings(context: context)?.blockFingerprinting ??
                SettingsStore.shared.blockFingerprinting
            return .bool(enabled)
        case "services.passwordSavingEnabled":
            return .bool(SettingsStore.shared.passwordSavePromptsEnabled)
        default:
            throw MozillaNativeAPIBridge.BridgeError.unsupportedMethod("privacy", setting)
        }
    }

    private static func parse(_ rawValue: Any, setting: String) throws -> Value {
        switch setting {
        case "websites.cookieConfig":
            guard let details = rawValue as? [String: Any],
                  let behavior = details["behavior"] as? String,
                  ["allow_all", "reject_third_party", "reject_all"].contains(behavior)
            else {
                throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                    "Ora supports cookieConfig behavior allow_all, reject_third_party, or reject_all."
                )
            }
            if details["nonPersistentCookies"] as? Bool == true {
                throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                    "Ora does not support nonPersistentCookies for normal extension windows."
                )
            }
            return .string(behavior)
        case "websites.trackingProtectionMode":
            guard let value = rawValue as? String,
                  value == "always" || value == "never"
            else {
                throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                    "Ora supports trackingProtectionMode always or never."
                )
            }
            return .string(value)
        case "websites.resistFingerprinting", "services.passwordSavingEnabled":
            guard let value = rawValue as? Bool else {
                throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                    "The requested browser.privacy setting requires a Boolean value."
                )
            }
            return .bool(value)
        default:
            throw MozillaNativeAPIBridge.BridgeError.unsupportedMethod("privacy", setting)
        }
    }

    private static func apply(
        _ value: Value,
        setting: String,
        context: WKWebExtensionContext
    ) throws {
        switch (setting, value) {
        case ("websites.cookieConfig", let .string(behavior)):
            let policy = try cookiePolicy(for: behavior)
            SettingsStore.shared.cookiesPolicy = policy
            updatePrivacySettings(context: context) { $0.cookiesPolicy = policy }
        case ("websites.trackingProtectionMode", let .string(mode)):
            let enabled = mode == "always"
            SettingsStore.shared.blockThirdPartyTrackers = enabled
            updatePrivacySettings(context: context) { $0.blockThirdPartyTrackers = enabled }
        case ("websites.resistFingerprinting", let .bool(enabled)):
            SettingsStore.shared.blockFingerprinting = enabled
            updatePrivacySettings(context: context) { $0.blockFingerprinting = enabled }
        case ("services.passwordSavingEnabled", let .bool(enabled)):
            SettingsStore.shared.passwordSavePromptsEnabled = enabled
        default:
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "The requested browser.privacy value is not valid for \(setting)."
            )
        }
    }

    private static func updatePrivacySettings(
        context: WKWebExtensionContext,
        mutate: (inout SpacePrivacySettings) -> Void
    ) {
        let store = SettingsStore.shared
        var seen = Set<ObjectIdentifier>()
        for tabManager in tabManagers(context: context) {
            let identifier = ObjectIdentifier(tabManager)
            guard seen.insert(identifier).inserted else { continue }
            for container in tabManager.containers {
                var settings = store.privacySettings(for: container.id)
                mutate(&settings)
                store.setPrivacySettings(settings, for: container.id)
                store.notifySpacePrivacySettingsChanged(for: container.id)
            }
        }
    }

    private static func activePrivacySettings(
        context: WKWebExtensionContext
    ) -> SpacePrivacySettings? {
        for tabManager in tabManagers(context: context) {
            if let container = tabManager.activeContainer {
                return SettingsStore.shared.privacySettings(for: container.id)
            }
        }
        return nil
    }

    private static func tabManagers(context: WKWebExtensionContext) -> [TabManager] {
        var windows: [OraWebExtensionWindow] = []
        if let focused = context.focusedWindow as? OraWebExtensionWindow {
            windows.append(focused)
        }
        windows.append(contentsOf: context.openWindows.compactMap { $0 as? OraWebExtensionWindow })
        return windows.compactMap(\.tabManager)
    }

    private static func externalValue(_ value: Value, setting: String) -> Any {
        switch (setting, value) {
        case ("websites.cookieConfig", let .string(behavior)):
            return ["behavior": behavior, "nonPersistentCookies": false]
        case (_, let .string(string)):
            return string
        case (_, let .bool(boolean)):
            return boolean
        }
    }

    private static func levelOfControl(setting: String, extensionID: String) -> String {
        guard let stack = controlStacks[setting], let controller = stack.assignments.last else {
            return "controllable_by_this_extension"
        }
        return controller.extensionID == extensionID
            ? "controlled_by_this_extension"
            : "controlled_by_other_extensions"
    }

    private static func emitChange(
        setting: String,
        value: Value,
        extensionID: String
    ) {
        let details: [String: Any] = [
            "value": externalValue(value, setting: setting),
            "levelOfControl": "controlled_by_this_extension"
        ]
        MozillaNativeAPIBridge.shared.emit(
            namespace: "privacy",
            event: "__ora_targeted__",
            arguments: [extensionID, "onChange:\(setting)", [details]]
        )
    }

    private static func cookieBehavior(for policy: CookiesPolicy) -> String {
        switch policy {
        case .allowAll:
            return "allow_all"
        case .blockThirdParty:
            return "reject_third_party"
        case .blockAll:
            return "reject_all"
        }
    }

    private static func cookiePolicy(for behavior: String) throws -> CookiesPolicy {
        switch behavior {
        case "allow_all":
            return .allowAll
        case "reject_third_party":
            return .blockThirdParty
        case "reject_all":
            return .blockAll
        default:
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "Unsupported cookie behavior: \(behavior)."
            )
        }
    }
}
