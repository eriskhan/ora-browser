import Foundation

enum OraMozillaNativeNamespaceScript {
    static let fileName = "__ora_mozilla_native_compat.js"

    static func source(declaredPermissions: Set<String>) -> String {
        let permissions = jsonArrayLiteral(Array(declaredPermissions).sorted())
        return template.replacingOccurrences(
            of: "__ORA_DECLARED_PERMISSIONS__",
            with: permissions
        )
    }

    private static func jsonArrayLiteral(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values),
              let result = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return result
    }

    // The template is JavaScript, not Swift. Keep SwiftFormat from rewriting its contents.
    // swiftformat:disable all
    private static let template = #"""
(() => {
    if (globalThis.__oraMozillaNativeNamespacesInstalled) return;
    globalThis.__oraMozillaNativeNamespacesInstalled = true;

    const root = globalThis.browser || globalThis.chrome;
    if (!root || !root.runtime) return;
    if (!globalThis.browser) globalThis.browser = root;

    const ORA_NATIVE_APPLICATION = "com.orabrowser.ora.mozilla";
    const DECLARED_PERMISSIONS = new Set(__ORA_DECLARED_PERMISSIONS__);
    const eventListeners = new Map();
    const eventSubscriptions = new Map();
    let eventPort;

    function hasPermission(permission) {
        return DECLARED_PERMISSIONS.has(permission);
    }

    function defineIfMissing(name, value) {
        if (root[name] !== undefined && root[name] !== null) return;
        try {
            Object.defineProperty(root, name, {
                value,
                configurable: true,
                enumerable: true,
                writable: false
            });
        } catch (_error) {
            try { root[name] = value; } catch (_ignored) {}
        }
    }

    async function nativeCall(namespace, method, args = []) {
        if (typeof root.runtime.sendNativeMessage !== "function") {
            throw new Error(
                `Ora native compatibility transport is unavailable for browser.${namespace}.${method}`
            );
        }
        const response = await root.runtime.sendNativeMessage(ORA_NATIVE_APPLICATION, {
            ora: "mozilla-api",
            namespace,
            method,
            args
        });
        if (!response || response.ok !== true) {
            const message = response && response.error
                ? response.error
                : `Ora failed browser.${namespace}.${method}`;
            throw new Error(message);
        }
        return response.value === null ? undefined : response.value;
    }

    function eventKey(namespace, event) {
        return `${namespace}.${event}`;
    }

    function dispatch(namespace, event, args) {
        const listeners = eventListeners.get(eventKey(namespace, event));
        if (!listeners) return;
        for (const listener of Array.from(listeners)) {
            try { listener(...args); } catch (_error) {}
        }
    }

    function receiveEvent(message) {
        if (!message || message.ora !== "mozilla-event") return;
        const args = Array.isArray(message.args) ? message.args : [];
        if (message.event === "__ora_targeted__") {
            const [targetExtensionID, actualEvent, actualArgs] = args;
            if (targetExtensionID !== root.runtime.id || typeof actualEvent !== "string") return;
            dispatch(message.namespace, actualEvent, Array.isArray(actualArgs) ? actualArgs : []);
            return;
        }
        dispatch(message.namespace, message.event, args);
    }

    function ensureEventPort() {
        if (eventPort || typeof root.runtime.connectNative !== "function") return;
        try {
            eventPort = root.runtime.connectNative(ORA_NATIVE_APPLICATION);
            eventPort.onMessage.addListener(receiveEvent);
            eventPort.onDisconnect.addListener(() => {
                eventPort = undefined;
                if (Array.from(eventListeners.values()).some((listeners) => listeners.size > 0)) {
                    queueMicrotask(ensureEventPort);
                }
            });
        } catch (_error) {
            eventPort = undefined;
        }
    }

    function nativeEvent(namespace, event, lifecycle = {}) {
        const key = eventKey(namespace, event);
        if (!eventListeners.has(key)) eventListeners.set(key, new Set());
        const listeners = eventListeners.get(key);
        return {
            addListener(listener) {
                if (typeof listener !== "function") throw new TypeError("Listener must be a function");
                const wasEmpty = listeners.size === 0;
                listeners.add(listener);
                ensureEventPort();
                if (wasEmpty && lifecycle.subscribe) {
                    nativeCall(namespace, lifecycle.subscribe).catch(() => {});
                    eventSubscriptions.set(key, true);
                }
            },
            removeListener(listener) {
                listeners.delete(listener);
                if (listeners.size === 0 && eventSubscriptions.get(key) && lifecycle.unsubscribe) {
                    nativeCall(namespace, lifecycle.unsubscribe).catch(() => {});
                    eventSubscriptions.delete(key);
                }
            },
            hasListener(listener) {
                return listeners.has(listener);
            },
            hasListeners() {
                return listeners.size > 0;
            }
        };
    }

    function milliseconds(value) {
        return value instanceof Date ? value.getTime() : value;
    }

    function isoDate(value) {
        return value instanceof Date ? value.toISOString() : value;
    }

    function removalOptions(options = {}) {
        return {
            ...options,
            since: milliseconds(options.since)
        };
    }

    function normalizeDownloadQuery(query = {}) {
        return {
            ...query,
            startedBefore: isoDate(query.startedBefore),
            startedAfter: isoDate(query.startedAfter),
            endedBefore: isoDate(query.endedBefore),
            endedAfter: isoDate(query.endedAfter)
        };
    }

    function nativeBrowserSetting(namespace, setting, readOnly = false) {
        return {
            get: (details = {}) => nativeCall(namespace, "get", [setting, details]),
            set: readOnly
                ? () => Promise.resolve(false)
                : (details) => nativeCall(namespace, "set", [setting, details && details.value]),
            clear: readOnly
                ? () => Promise.resolve(false)
                : (details = {}) => nativeCall(namespace, "clear", [setting, details]),
            onChange: nativeEvent(namespace, `onChange:${setting}`)
        };
    }

    if (!root.browserSettings && hasPermission("browserSettings")) {
        defineIfMissing("browserSettings", {
            verticalTabs: nativeBrowserSetting("browserSettings", "verticalTabs", true),
            newTabPosition: nativeBrowserSetting("browserSettings", "newTabPosition", true)
        });
    }

    if (!root.browsingData && hasPermission("browsingData")) {
        defineIfMissing("browsingData", {
            settings: () => nativeCall("browsingData", "settings"),
            remove: (options, dataToRemove) => nativeCall(
                "browsingData",
                "remove",
                [removalOptions(options), dataToRemove || {}]
            ),
            removeCache: (options) => nativeCall("browsingData", "removeCache", [removalOptions(options)]),
            removeCookies: (options) => nativeCall("browsingData", "removeCookies", [removalOptions(options)]),
            removeDownloads: (options) => nativeCall("browsingData", "removeDownloads", [removalOptions(options)]),
            removeFormData: (options) => nativeCall("browsingData", "removeFormData", [removalOptions(options)]),
            removeHistory: (options) => nativeCall("browsingData", "removeHistory", [removalOptions(options)]),
            removeLocalStorage: (options) => nativeCall(
                "browsingData",
                "removeLocalStorage",
                [removalOptions(options)]
            ),
            removePasswords: (options) => nativeCall("browsingData", "removePasswords", [removalOptions(options)]),
            removePluginData: (options) => nativeCall("browsingData", "removePluginData", [removalOptions(options)])
        });
    }

    if (!root.contextualIdentities && hasPermission("contextualIdentities") && hasPermission("cookies")) {
        defineIfMissing("contextualIdentities", {
            get: (cookieStoreId) => nativeCall("contextualIdentities", "get", [cookieStoreId]),
            query: (details = {}) => nativeCall("contextualIdentities", "query", [details]),
            create: (details) => nativeCall("contextualIdentities", "create", [details || {}]),
            update: (cookieStoreId, details) => nativeCall(
                "contextualIdentities",
                "update",
                [cookieStoreId, details || {}]
            ),
            move: (cookieStoreIds, position) => nativeCall(
                "contextualIdentities",
                "move",
                [cookieStoreIds, position]
            ),
            remove: (cookieStoreId) => nativeCall("contextualIdentities", "remove", [cookieStoreId]),
            getSupportedColors: () => nativeCall("contextualIdentities", "getSupportedColors"),
            getSupportedIcons: () => nativeCall("contextualIdentities", "getSupportedIcons"),
            onCreated: nativeEvent("contextualIdentities", "onCreated"),
            onUpdated: nativeEvent("contextualIdentities", "onUpdated"),
            onRemoved: nativeEvent("contextualIdentities", "onRemoved")
        });
    }

    if (!root.dns && hasPermission("dns")) {
        defineIfMissing("dns", {
            resolve: (hostname, flags = []) => nativeCall("dns", "resolve", [hostname, flags])
        });
    }

    if (!root.downloads && hasPermission("downloads")) {
        defineIfMissing("downloads", {
            download: (options) => nativeCall("downloads", "download", [options || {}]),
            search: (query = {}) => nativeCall("downloads", "search", [normalizeDownloadQuery(query)]),
            pause: (downloadId) => nativeCall("downloads", "pause", [downloadId]),
            resume: (downloadId) => nativeCall("downloads", "resume", [downloadId]),
            cancel: (downloadId) => nativeCall("downloads", "cancel", [downloadId]),
            open: (downloadId) => nativeCall("downloads", "open", [downloadId]),
            show: (downloadId) => nativeCall("downloads", "show", [downloadId]),
            showDefaultFolder: () => nativeCall("downloads", "showDefaultFolder"),
            erase: (query = {}) => nativeCall("downloads", "erase", [normalizeDownloadQuery(query)]),
            removeFile: (downloadId) => nativeCall("downloads", "removeFile", [downloadId]),
            getFileIcon: (downloadId, options = {}) => nativeCall(
                "downloads",
                "getFileIcon",
                [downloadId, options]
            ),
            acceptDanger: (downloadId) => nativeCall("downloads", "acceptDanger", [downloadId]),
            onCreated: nativeEvent("downloads", "onCreated"),
            onChanged: nativeEvent("downloads", "onChanged"),
            onErased: nativeEvent("downloads", "onErased")
        });
    }

    if (!root.idle && hasPermission("idle")) {
        defineIfMissing("idle", {
            queryState: (detectionIntervalInSeconds) => nativeCall(
                "idle",
                "queryState",
                [detectionIntervalInSeconds]
            ),
            setDetectionInterval: (detectionIntervalInSeconds) => nativeCall(
                "idle",
                "setDetectionInterval",
                [detectionIntervalInSeconds]
            ),
            onStateChanged: nativeEvent("idle", "onStateChanged", {
                subscribe: "__subscribe",
                unsubscribe: "__unsubscribe"
            })
        });
    }

    if (!root.management) {
        defineIfMissing("management", {
            getAll: () => nativeCall("management", "getAll"),
            getSelf: () => nativeCall("management", "getSelf"),
            get: (id) => nativeCall("management", "get", [id]),
            setEnabled: (id, enabled) => nativeCall("management", "setEnabled", [id, enabled]),
            uninstall: (id, options = {}) => nativeCall("management", "uninstall", [id, options]),
            uninstallSelf: (options = {}) => nativeCall("management", "uninstallSelf", [options]),
            getPermissionWarningsById: (id) => nativeCall("management", "getPermissionWarningsById", [id]),
            getPermissionWarningsByManifest: (manifestString) => nativeCall(
                "management",
                "getPermissionWarningsByManifest",
                [manifestString]
            ),
            install: (options) => nativeCall("management", "install", [options || {}]),
            onInstalled: nativeEvent("management", "onInstalled", { subscribe: "__subscribe" }),
            onUninstalled: nativeEvent("management", "onUninstalled", { subscribe: "__subscribe" }),
            onEnabled: nativeEvent("management", "onEnabled", { subscribe: "__subscribe" }),
            onDisabled: nativeEvent("management", "onDisabled", { subscribe: "__subscribe" })
        });
    }

    if (!root.privacy && hasPermission("privacy")) {
        defineIfMissing("privacy", {
            services: {
                passwordSavingEnabled: nativeBrowserSetting(
                    "privacy",
                    "services.passwordSavingEnabled"
                )
            },
            websites: {
                cookieConfig: nativeBrowserSetting("privacy", "websites.cookieConfig"),
                trackingProtectionMode: nativeBrowserSetting(
                    "privacy",
                    "websites.trackingProtectionMode"
                ),
                resistFingerprinting: nativeBrowserSetting(
                    "privacy",
                    "websites.resistFingerprinting"
                )
            }
        });
    }
})();
"""#
    // swiftformat:enable all
}
