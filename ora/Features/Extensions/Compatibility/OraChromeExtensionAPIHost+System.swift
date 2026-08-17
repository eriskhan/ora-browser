import AppKit
import Foundation
import os.log

extension OraChromeExtensionAPIHost {
    func handleIdle(method: String, args: [Any]) throws -> Any? {
        switch method {
        case "queryState":
            let interval = numberArgument(args, at: 0)?.doubleValue ?? idleDetectionInterval
            return idleState(threshold: interval)
        case "setDetectionInterval":
            guard let interval = numberArgument(args, at: 0)?.doubleValue, interval >= 15 else {
                throw BridgeError.invalidArguments("idle.setDetectionInterval requires at least 15 seconds.")
            }
            idleDetectionInterval = interval
            return nil
        case "getAutoLockDelay":
            return 0
        default:
            throw BridgeError.unsupportedMethod("idle", method)
        }
    }

    func startIdleMonitoringIfNeeded() {
        guard idleTimer == nil else { return }
        lastIdleState = idleState(threshold: idleDetectionInterval)
        idleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let state = self.idleState(threshold: self.idleDetectionInterval)
                guard state != self.lastIdleState else { return }
                self.lastIdleState = state
                self.emit(namespace: "idle", event: "onStateChanged", args: [state])
            }
        }
    }

    func handlePower(method: String, args: [Any]) throws -> Any? {
        switch method {
        case "requestKeepAwake":
            let level = stringArgument(args, at: 0) ?? "system"
            if let existing = powerActivity {
                ProcessInfo.processInfo.endActivity(existing)
            }
            let options: ProcessInfo.ActivityOptions = level == "display"
                ? [.idleDisplaySleepDisabled, .userInitiated]
                : [.idleSystemSleepDisabled, .userInitiated]
            powerActivity = ProcessInfo.processInfo.beginActivity(
                options: options,
                reason: "Chrome extension requested keep-awake through Ora"
            )
            return nil
        case "releaseKeepAwake":
            if let existing = powerActivity {
                ProcessInfo.processInfo.endActivity(existing)
                powerActivity = nil
            }
            return nil
        default:
            throw BridgeError.unsupportedMethod("power", method)
        }
    }

    func handleTTS(method: String, args: [Any]) throws -> Any? {
        switch method {
        case "speak":
            guard let text = stringArgument(args, at: 0) else {
                throw BridgeError.invalidArguments("tts.speak requires text.")
            }
            _ = speechSynthesizer.startSpeaking(text)
            emit(namespace: "tts", event: "onEvent", args: [["type": "start", "charIndex": 0]])
            return nil
        case "stop":
            speechSynthesizer.stopSpeaking()
            return nil
        case "pause":
            speechSynthesizer.pauseSpeaking(at: .immediateBoundary)
            return nil
        case "resume":
            speechSynthesizer.continueSpeaking()
            return nil
        case "isSpeaking":
            return speechSynthesizer.isSpeaking
        case "getVoices":
            return NSSpeechSynthesizer.availableVoices.map { voice in
                [
                    "voiceName": String(describing: voice),
                    "lang": Locale.current.identifier,
                    "remote": false,
                    "extensionId": "",
                    "eventTypes": ["start", "end", "error"]
                ] as [String: Any]
            }
        default:
            throw BridgeError.unsupportedMethod("tts", method)
        }
    }

    func handleSystemCPU(method: String) throws -> Any? {
        guard method == "getInfo" else { throw BridgeError.unsupportedMethod("system.cpu", method) }
        let processInfo = ProcessInfo.processInfo
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif

        let processors = (0 ..< processInfo.processorCount).map { _ in
            ["usage": ["user": 0, "kernel": 0, "idle": 0, "total": 0]]
        }
        return [
            "numOfProcessors": processInfo.processorCount,
            "archName": architecture,
            "modelName": architecture == "arm64" ? "Apple Silicon" : "Mac",
            "features": [],
            "processors": processors,
            "temperatures": []
        ] as [String: Any]
    }

    func handleSystemMemory(method: String) throws -> Any? {
        guard method == "getInfo" else { throw BridgeError.unsupportedMethod("system.memory", method) }
        let memory = ProcessInfo.processInfo.physicalMemory
        return [
            "capacity": Double(memory),
            "availableCapacity": Double(memory)
        ]
    }

    func handleSystemDisplay(method: String) throws -> Any? {
        guard method == "getInfo" else { throw BridgeError.unsupportedMethod("system.display", method) }
        guard let primary = NSScreen.screens.first else { return [] }
        return NSScreen.screens.map { screen in
            let frame = screen.frame
            let visible = screen.visibleFrame
            let scale = screen.backingScaleFactor
            let identifier = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
                ?? UUID().uuidString
            return [
                "id": identifier,
                "name": screen.localizedName,
                "isPrimary": screen === primary,
                "isInternal": false,
                "isEnabled": true,
                "dpiX": 72 * scale,
                "dpiY": 72 * scale,
                "rotation": 0,
                "bounds": rectDictionary(frame),
                "overscan": ["left": 0, "top": 0, "right": 0, "bottom": 0],
                "workArea": rectDictionary(visible)
            ] as [String: Any]
        }
    }

    func handleSystemStorage(method: String) throws -> Any? {
        switch method {
        case "getInfo":
            let root = URL(fileURLWithPath: "/")
            let values = try root.resourceValues(forKeys: [
                .volumeNameKey,
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ])
            return [[
                "id": root.path,
                "name": values.volumeName ?? "Macintosh HD",
                "type": "fixed",
                "capacity": values.volumeTotalCapacity ?? 0,
                "availableCapacity": values.volumeAvailableCapacityForImportantUsage ?? 0
            ]] as [[String: Any]]
        case "ejectDevice":
            throw BridgeError.unsupportedMethod("system.storage", method)
        default:
            throw BridgeError.unsupportedMethod("system.storage", method)
        }
    }

    func handleProcesses(method: String, args: [Any]) throws -> Any? {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process: [String: Any] = [
            "id": Int(pid),
            "osProcessId": Int(pid),
            "type": "browser",
            "profile": "ora",
            "naclDebugPort": 0,
            "tabs": [],
            "cpu": 0,
            "network": 0,
            "privateMemory": 0,
            "jsMemoryAllocated": 0,
            "jsMemoryUsed": 0,
            "sqliteMemory": 0
        ]
        switch method {
        case "getProcessIdForTab":
            return Int(pid)
        case "getProcessInfo":
            return [String(pid): process]
        case "terminate":
            return false
        default:
            throw BridgeError.unsupportedMethod("processes", method)
        }
    }

    func handleSystemLog(method: String, args: [Any]) throws -> Any? {
        guard method == "add" else { throw BridgeError.unsupportedMethod("systemLog", method) }
        let message = dictionaryArgument(args)["message"] as? String ?? stringArgument(args, at: 0) ?? ""
        Logger(subsystem: "com.orabrowser.ora", category: "ExtensionSystemLog").info("\(message, privacy: .public)")
        return nil
    }

    func handleAccessibilitySetting(namespace: String, method: String, args: [Any]) throws -> Any? {
        let property = namespace.split(separator: ".").last.map(String.init) ?? ""
        guard method == "get" else {
            throw BridgeError.unsupportedMethod("accessibilityFeatures", "\(property).\(method)")
        }

        let workspace = NSWorkspace.shared
        let value: Any
        switch property {
        case "animationPolicy":
            value = workspace.accessibilityDisplayShouldReduceMotion ? "none" : "allowed"
        case "highContrast":
            value = workspace.accessibilityDisplayShouldIncreaseContrast
        case "reducedMotion":
            value = workspace.accessibilityDisplayShouldReduceMotion
        default:
            value = false
        }
        return ["value": value, "levelOfControl": "not_controllable"]
    }

    func handleContentSetting(namespace: String, method: String, args: [Any]) throws -> Any? {
        let property = namespace.split(separator: ".").last.map(String.init) ?? ""
        guard method == "get" else {
            throw BridgeError.unsupportedMethod("contentSettings", "\(property).\(method)")
        }
        let setting: String
        switch property {
        case "javascript", "images", "cookies": setting = "allow"
        case "popups": setting = "block"
        default: setting = "ask"
        }
        return ["setting": setting]
    }

    func handlePrivacySetting(namespace: String, method: String, args: [Any]) throws -> Any? {
        guard method == "get" else {
            throw BridgeError.unsupportedMethod("privacy", "\(namespace).\(method)")
        }
        let property = namespace.split(separator: ".").last.map(String.init) ?? ""
        let value: Any
        switch property {
        case "networkPredictionEnabled": value = false
        case "webRTCIPHandlingPolicy": value = "default"
        case "passwordSavingEnabled": value = true
        case "doNotTrackEnabled": value = false
        default: value = false
        }
        return ["value": value, "levelOfControl": "not_controllable"]
    }

    func handleFontSettings(method: String, args: [Any]) throws -> Any? {
        switch method {
        case "getFontList":
            return NSFontManager.shared.availableFontFamilies.map { family in
                ["fontId": family, "displayName": family]
            }
        case "getFont":
            let details = dictionaryArgument(args)
            let genericFamily = details["genericFamily"] as? String ?? "standard"
            let defaults: [String: String] = [
                "standard": "Times New Roman",
                "serif": "Times New Roman",
                "sansserif": "Helvetica",
                "fixed": "Menlo",
                "cursive": "Apple Chancery",
                "fantasy": "Papyrus"
            ]
            return ["fontId": defaults[genericFamily] ?? "Times New Roman", "levelOfControl": "not_controllable"]
        case "getDefaultFontSize":
            return ["pixelSize": 16, "levelOfControl": "not_controllable"]
        case "getDefaultFixedFontSize":
            return ["pixelSize": 13, "levelOfControl": "not_controllable"]
        case "getMinimumFontSize":
            return ["pixelSize": 0, "levelOfControl": "not_controllable"]
        case "setFont", "clearFont", "setDefaultFontSize", "clearDefaultFontSize", "setDefaultFixedFontSize",
             "clearDefaultFixedFontSize", "setMinimumFontSize", "clearMinimumFontSize":
            throw BridgeError.unsupportedMethod("fontSettings", method)
        default:
            throw BridgeError.unsupportedMethod("fontSettings", method)
        }
    }

    private func idleState(threshold: TimeInterval) -> String {
        let mouseIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
        let keyboardIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        return min(mouseIdle, keyboardIdle) >= threshold ? "idle" : "active"
    }

    private func rectDictionary(_ rect: CGRect) -> [String: Int] {
        [
            "left": Int(rect.minX),
            "top": Int(rect.minY),
            "width": Int(rect.width),
            "height": Int(rect.height)
        ]
    }
}
