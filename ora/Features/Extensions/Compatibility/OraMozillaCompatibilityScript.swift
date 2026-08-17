import Foundation

enum OraMozillaCompatibilityScript {
    static let fileName = "__ora_mozilla_compat.js"

    static var source: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let buildID = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return template
            .replacingOccurrences(of: "__ORA_APP_VERSION__", with: version)
            .replacingOccurrences(of: "__ORA_BUILD_ID__", with: buildID)
    }

    // The template is JavaScript, not Swift. Keep SwiftFormat from rewriting its contents.
    // swiftformat:disable all
    private static let template = #"""
(() => {
    if (globalThis.__oraMozillaCompatibilityInstalled) return;
    globalThis.__oraMozillaCompatibilityInstalled = true;

    const root = globalThis.browser || globalThis.chrome;
    if (!root) return;
    if (!globalThis.browser) globalThis.browser = root;

    const ORA_NATIVE_APPLICATION = "com.orabrowser.ora.mozilla";
    const ORA_ORIGINAL_NATIVE_MESSAGING = __ORA_ORIGINAL_NATIVE_MESSAGING__;
    const ORA_ORIGINAL_PERMISSIONS = new Set(__ORA_ORIGINAL_PERMISSIONS__);
    const ORA_REQUIRED_PERMISSIONS = new Set(__ORA_REQUIRED_PERMISSIONS__);
    const ORA_OPTIONAL_PERMISSIONS = new Set(__ORA_OPTIONAL_PERMISSIONS__);
    const ORA_NATIVE_BRIDGE_PERMISSIONS = new Set([
        "browserSettings",
        "browsingData",
        "contextualIdentities",
        "cookies",
        "dns",
        "downloads",
        "downloads.open",
        "find",
        "history",
        "idle",
        "management",
        "privacy",
        "search",
        "topSites"
    ]);
    const eventListeners = new Map();
    let eventPort;
    let generatedContentScriptID = 0;
    let generatedLegacyUserScriptID = 0;
    const registeredUserScriptIDs = new Set();

    function hasOriginalPermission(permission) {
        return ORA_ORIGINAL_PERMISSIONS.has(permission);
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

    function call(namespace, method, args) {
        const value = namespace && namespace[method];
        if (typeof value !== "function") {
            return Promise.reject(new Error(`Ora does not support browser.${method} in this context`));
        }
        try {
            return Promise.resolve(value.apply(namespace, args));
        } catch (error) {
            return Promise.reject(error);
        }
    }

    async function rawNativeCall(namespace, method, args = []) {
        if (!root.runtime || typeof root.runtime.sendNativeMessage !== "function") {
            throw new Error(`Ora native compatibility transport is unavailable for browser.${namespace}.${method}`);
        }
        const response = await root.runtime.sendNativeMessage(ORA_NATIVE_APPLICATION, {
            ora: "mozilla-api",
            namespace,
            method,
            args
        });
        if (!response || response.ok !== true) {
            throw new Error(response && response.error ? response.error : `Ora failed browser.${namespace}.${method}`);
        }
        return response.value === null ? undefined : response.value;
    }

    const requiredNativeBridgePermissions = Array.from(ORA_REQUIRED_PERMISSIONS).filter(
        (permission) => ORA_NATIVE_BRIDGE_PERMISSIONS.has(permission)
    );
    const isWebContentContext = typeof location !== "undefined" &&
        (location.protocol === "http:" || location.protocol === "https:");
    globalThis.__oraMozillaPermissionsReady = isWebContentContext
        ? Promise.resolve(true)
        : rawNativeCall("permissions", "ensureRequired", [requiredNativeBridgePermissions]).catch(() => false);

    async function nativeCall(namespace, method, args = []) {
        if (namespace !== "permissions" && globalThis.__oraMozillaPermissionsReady) {
            await globalThis.__oraMozillaPermissionsReady;
        }
        return rawNativeCall(namespace, method, args);
    }

    function eventKey(namespace, event) {
        return `${namespace}.${event}`;
    }

    function ensureEventPort() {
        if (eventPort || !root.runtime || typeof root.runtime.connectNative !== "function") return;
        try {
            eventPort = root.runtime.connectNative(ORA_NATIVE_APPLICATION);
            eventPort.onMessage.addListener((message) => {
                if (!message || message.ora !== "mozilla-event") return;
                const listeners = eventListeners.get(eventKey(message.namespace, message.event));
                if (!listeners) return;
                for (const listener of Array.from(listeners)) {
                    try { listener(...(Array.isArray(message.args) ? message.args : [])); } catch (_error) {}
                }
            });
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

    function nativeEvent(namespace, event) {
        const key = eventKey(namespace, event);
        if (!eventListeners.has(key)) eventListeners.set(key, new Set());
        const listeners = eventListeners.get(key);
        return {
            addListener(listener) {
                if (typeof listener !== "function") throw new TypeError("Listener must be a function");
                listeners.add(listener);
                ensureEventPort();
            },
            removeListener(listener) {
                listeners.delete(listener);
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
        if (value instanceof Date) return value.getTime();
        return value;
    }

    function normalizeHistoryQuery(query = {}) {
        return {
            ...query,
            startTime: milliseconds(query.startTime),
            endTime: milliseconds(query.endTime)
        };
    }

    function normalizeHistoryAdd(details = {}) {
        return {
            ...details,
            visitTime: milliseconds(details.visitTime)
        };
    }

    if (root.action) {
        defineIfMissing("browserAction", root.action);

        if (!root.pageAction) {
            const action = root.action;
            defineIfMissing("pageAction", {
                onClicked: action.onClicked,
                setTitle: (...args) => call(action, "setTitle", args),
                getTitle: (...args) => call(action, "getTitle", args),
                setIcon: (...args) => call(action, "setIcon", args),
                setPopup: (...args) => call(action, "setPopup", args),
                getPopup: (...args) => call(action, "getPopup", args),
                show: (tabId) => call(action, "enable", [tabId]),
                hide: (tabId) => call(action, "disable", [tabId]),
                openPopup: (...args) => call(action, "openPopup", args)
            });
        }
    }

    if (!root.menus && root.contextMenus) defineIfMissing("menus", root.contextMenus);

    if (root.runtime && typeof root.runtime.getBrowserInfo !== "function") {
        try {
            root.runtime.getBrowserInfo = () => Promise.resolve({
                name: "Ora",
                vendor: "Ora Browser",
                version: "__ORA_APP_VERSION__",
                buildID: "__ORA_BUILD_ID__"
            });
        } catch (_error) {}
    }

    if (root.permissions) {
        const permissions = root.permissions;
        const originalGetAll = typeof permissions.getAll === "function" ? permissions.getAll.bind(permissions) : undefined;
        const originalContains = typeof permissions.contains === "function" ? permissions.contains.bind(permissions) : undefined;
        const originalRequest = typeof permissions.request === "function" ? permissions.request.bind(permissions) : undefined;
        const originalRemove = typeof permissions.remove === "function" ? permissions.remove.bind(permissions) : undefined;
        const visiblePermissions = (values) => ORA_ORIGINAL_NATIVE_MESSAGING
            ? (values || [])
            : (values || []).filter((value) => value !== "nativeMessaging");

        function splitPermissionQuery(query = {}) {
            const requested = visiblePermissions(query.permissions);
            const bridge = requested.filter((permission) => ORA_NATIVE_BRIDGE_PERMISSIONS.has(permission));
            const webkit = requested.filter((permission) => !ORA_NATIVE_BRIDGE_PERMISSIONS.has(permission));
            return {
                bridge,
                webkit,
                origins: Array.isArray(query.origins) ? query.origins : []
            };
        }

        async function callWebKitPermissionMethod(method, split) {
            if (!method) return true;
            if (split.webkit.length === 0 && split.origins.length === 0) return true;
            return Boolean(await method({ permissions: split.webkit, origins: split.origins }));
        }

        permissions.getAll = async () => {
            const webkit = originalGetAll ? await originalGetAll() : { permissions: [], origins: [] };
            const bridged = await nativeCall("permissions", "getAll");
            return {
                ...webkit,
                permissions: Array.from(new Set([
                    ...visiblePermissions(webkit.permissions),
                    ...(Array.isArray(bridged) ? bridged : [])
                ]))
            };
        };

        permissions.contains = async (query = {}) => {
            const split = splitPermissionQuery(query);
            const bridgeAllowed = split.bridge.length === 0 ||
                await nativeCall("permissions", "contains", [split.bridge]);
            if (!bridgeAllowed) return false;
            return callWebKitPermissionMethod(originalContains, split);
        };

        permissions.request = async (query = {}) => {
            const split = splitPermissionQuery(query);
            const webkitAllowed = await callWebKitPermissionMethod(originalRequest, split);
            if (!webkitAllowed) return false;
            if (split.bridge.length === 0) return true;
            return Boolean(await nativeCall("permissions", "request", [split.bridge]));
        };

        permissions.remove = async (query = {}) => {
            const split = splitPermissionQuery(query);
            const webkitRemoved = await callWebKitPermissionMethod(originalRemove, split);
            if (!webkitRemoved) return false;
            if (split.bridge.length === 0) return true;
            return Boolean(await nativeCall("permissions", "remove", [split.bridge]));
        };
    }

    if (!root.history && hasOriginalPermission("history")) {
        defineIfMissing("history", {
            search: (query) => nativeCall("history", "search", [normalizeHistoryQuery(query)]),
            getVisits: (details) => nativeCall("history", "getVisits", [details || {}]),
            addUrl: (details) => nativeCall("history", "addUrl", [normalizeHistoryAdd(details)]),
            deleteUrl: (details) => nativeCall("history", "deleteUrl", [details || {}]),
            deleteRange: (range) => nativeCall("history", "deleteRange", [{
                ...range,
                startTime: milliseconds(range && range.startTime),
                endTime: milliseconds(range && range.endTime)
            }]),
            deleteAll: () => nativeCall("history", "deleteAll"),
            onVisited: nativeEvent("history", "onVisited"),
            onVisitRemoved: nativeEvent("history", "onVisitRemoved"),
            onTitleChanged: nativeEvent("history", "onTitleChanged")
        });
    }

    if (!root.topSites && hasOriginalPermission("topSites")) {
        defineIfMissing("topSites", {
            get: (options = {}) => nativeCall("topSites", "get", [options])
        });
    }

    if (!root.search && hasOriginalPermission("search")) {
        async function performSearch(properties, defaultDisposition) {
            const details = properties || {};
            if (details.tabId !== undefined && details.disposition !== undefined) {
                throw new TypeError("browser.search cannot use tabId and disposition together");
            }
            const url = await nativeCall("search", "buildURL", [details]);
            if (details.tabId !== undefined) {
                await root.tabs.update(details.tabId, { url });
                return;
            }

            const disposition = details.disposition || defaultDisposition;
            if (disposition === "CURRENT_TAB") {
                await root.tabs.update({ url });
            } else if (disposition === "NEW_WINDOW") {
                await root.windows.create({ url });
            } else {
                await root.tabs.create({ url });
            }
        }

        defineIfMissing("search", {
            get: () => nativeCall("search", "get"),
            search: (properties) => performSearch(properties, "NEW_TAB"),
            query: (properties) => performSearch(
                {
                    query: properties && properties.text,
                    disposition: properties && properties.disposition,
                    tabId: properties && properties.tabId,
                    engine: properties && properties.engine
                },
                "CURRENT_TAB"
            )
        });
    }

    if (!root.clipboard && typeof navigator !== "undefined" && navigator.clipboard) {
        defineIfMissing("clipboard", {
            async setImageData(imageData, imageType) {
                if (typeof ClipboardItem === "undefined" || typeof navigator.clipboard.write !== "function") {
                    throw new Error("browser.clipboard.setImageData is unavailable in this WebKit context");
                }
                const normalizedType = String(imageType || "png").toLowerCase();
                if (normalizedType !== "png" && normalizedType !== "jpeg" && normalizedType !== "jpg") {
                    throw new TypeError("Firefox clipboard.setImageData supports png and jpeg images");
                }
                const mimeType = normalizedType === "png" ? "image/png" : "image/jpeg";
                const blob = new Blob([imageData], { type: mimeType });
                await navigator.clipboard.write([new ClipboardItem({ [mimeType]: blob })]);
            }
        });
    }

    function rejectUnsupportedRegistrationOptions(options, apiName) {
        const unsupported = ["includeGlobs", "excludeGlobs", "matchAboutBlank", "cssOrigin"].filter(
            (key) => options && options[key] !== undefined
        );
        if (unsupported.length) {
            throw new Error(`${apiName} options not supported by Ora: ${unsupported.join(", ")}`);
        }
    }

    function fileList(entries, apiName) {
        if (!entries) return undefined;
        return entries.map((entry) => {
            if (typeof entry === "string") return entry;
            if (entry && typeof entry.file === "string") return entry.file;
            if (entry && typeof entry.code === "string") {
                throw new Error(`${apiName} inline code cannot be registered faithfully by Ora`);
            }
            throw new TypeError(`${apiName} script entries must reference packaged files`);
        });
    }

    function makeRegisteredContentScript(options, id, apiName) {
        rejectUnsupportedRegistrationOptions(options, apiName);
        if (!Array.isArray(options.matches) || options.matches.length === 0) {
            throw new TypeError(`${apiName} requires a non-empty matches array in Ora`);
        }
        const script = {
            id,
            matches: options.matches,
            persistAcrossSessions: false
        };
        if (options.excludeMatches) script.excludeMatches = options.excludeMatches;
        if (options.allFrames !== undefined) script.allFrames = Boolean(options.allFrames);
        if (options.runAt) script.runAt = options.runAt;
        const js = fileList(options.js, apiName);
        const css = fileList(options.css, apiName);
        if (js && js.length) script.js = js;
        if (css && css.length) script.css = css;
        return script;
    }

    if (!root.contentScripts && root.scripting && typeof root.scripting.registerContentScripts === "function") {
        defineIfMissing("contentScripts", {
            async register(options) {
                const id = `ora-content-${++generatedContentScriptID}`;
                const script = makeRegisteredContentScript(options || {}, id, "browser.contentScripts.register");
                await root.scripting.registerContentScripts([script]);
                return {
                    unregister: () => root.scripting.unregisterContentScripts({ ids: [id] })
                };
            }
        });
    }

    function userScriptInternalID(id) {
        return `ora-user-${id}`;
    }

    function makeModernUserScript(script) {
        rejectUnsupportedRegistrationOptions(script, "browser.userScripts");
        if (!script || typeof script.id !== "string" || script.id.length === 0) {
            throw new TypeError("browser.userScripts requires a non-empty script id");
        }
        const converted = makeRegisteredContentScript(
            { ...script, css: undefined },
            userScriptInternalID(script.id),
            "browser.userScripts"
        );
        if (script.world === "MAIN") converted.world = "MAIN";
        registeredUserScriptIDs.add(script.id);
        return converted;
    }

    function makeLegacyUserScript(options) {
        const publicID = `legacy-${++generatedLegacyUserScriptID}`;
        const converted = makeRegisteredContentScript(
            {
                ...options,
                matches: options.matches || options.hosts,
                js: options.js || (options.file ? [{ file: options.file }] : options.code ? [{ code: options.code }] : undefined)
            },
            userScriptInternalID(publicID),
            "browser.userScripts.register"
        );
        registeredUserScriptIDs.add(publicID);
        return { publicID, converted };
    }

    if (!root.userScripts && root.scripting && typeof root.scripting.registerContentScripts === "function") {
        defineIfMissing("userScripts", {
            async register(scripts) {
                if (Array.isArray(scripts)) {
                    const converted = scripts.map(makeModernUserScript);
                    await root.scripting.registerContentScripts(converted);
                    return undefined;
                }

                const legacy = makeLegacyUserScript(scripts || {});
                await root.scripting.registerContentScripts([legacy.converted]);
                return {
                    unregister: async () => {
                        await root.scripting.unregisterContentScripts({ ids: [userScriptInternalID(legacy.publicID)] });
                        registeredUserScriptIDs.delete(legacy.publicID);
                    }
                };
            },

            async getScripts(filter = {}) {
                const publicIDs = Array.isArray(filter.ids) ? filter.ids : Array.from(registeredUserScriptIDs);
                if (publicIDs.length === 0) return [];
                const scripts = await root.scripting.getRegisteredContentScripts({
                    ids: publicIDs.map(userScriptInternalID)
                });
                return scripts.map((script) => ({
                    ...script,
                    id: script.id.replace(/^ora-user-/, ""),
                    js: (script.js || []).map((file) => ({ file }))
                }));
            },

            async update(scripts) {
                if (!Array.isArray(scripts)) throw new TypeError("browser.userScripts.update expects an array");
                const converted = scripts.map(makeModernUserScript);
                await root.scripting.updateContentScripts(converted);
            },

            async unregister(filter = {}) {
                const publicIDs = Array.isArray(filter.ids) ? filter.ids : Array.from(registeredUserScriptIDs);
                if (publicIDs.length === 0) return;
                await root.scripting.unregisterContentScripts({ ids: publicIDs.map(userScriptInternalID) });
                for (const id of publicIDs) registeredUserScriptIDs.delete(id);
            }
        });
    }
})();
"""#
    // swiftformat:enable all
}
