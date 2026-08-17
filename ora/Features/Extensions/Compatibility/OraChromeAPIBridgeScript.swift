import Foundation

enum OraChromeAPIBridgeScript {
    static let applicationIdentifier = "com.orabrowser.extension-api"
    static let fileName = "__ora_chrome_api_bridge.js"

    static var source: String {
        let namespaces = (try? JSONSerialization.data(withJSONObject: ChromeExtensionAPICatalog.allNamespaceNames))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        return template
            .replacingOccurrences(of: "__ORA_EXTENSION_NAMESPACES__", with: namespaces)
            .replacingOccurrences(of: "__ORA_NATIVE_HOST__", with: applicationIdentifier)
    }

    private static let template = #"""
(() => {
    if (globalThis.__oraChromeBridgeInstalled) return;
    globalThis.__oraChromeBridgeInstalled = true;

    const HOST = "__ORA_NATIVE_HOST__";
    const EXTENSION_NAMESPACES = __ORA_EXTENSION_NAMESPACES__;
    const chromeRoot = globalThis.chrome || (globalThis.chrome = {});
    const browserRoot = globalThis.browser || (globalThis.browser = {});
    const nativeTabsAPI = chromeRoot.tabs || browserRoot.tabs;
    const eventListeners = new Map();
    let eventPort = null;
    let bridgeLastError = null;

    const STATIC_VALUES = {
        tabs: { TAB_ID_NONE: -1 },
        tabGroups: { TAB_GROUP_ID_NONE: -1 },
        windows: { WINDOW_ID_NONE: -1, WINDOW_ID_CURRENT: -2 }
    };

    function runtimeObject() {
        return chromeRoot.runtime || browserRoot.runtime;
    }

    function reviveBridgeValue(value) {
        if (value && typeof value === "object" && value.__oraBlobBase64 && value.__oraBlobType) {
            const binary = atob(value.__oraBlobBase64);
            const bytes = new Uint8Array(binary.length);
            for (let index = 0; index < binary.length; ++index) bytes[index] = binary.charCodeAt(index);
            return new Blob([bytes], { type: value.__oraBlobType });
        }
        if (Array.isArray(value)) return value.map(reviveBridgeValue);
        if (value && typeof value === "object") {
            const result = {};
            for (const [key, nested] of Object.entries(value)) result[key] = reviveBridgeValue(nested);
            return result;
        }
        return value;
    }

    function normalizeResponse(response) {
        if (!response || response.ok !== true) {
            const detail = response && response.error ? response.error : {};
            const error = new Error(detail.message || "Ora extension API call failed");
            error.code = detail.code || "ORA_EXTENSION_API_ERROR";
            throw error;
        }
        return reviveBridgeValue(response.result);
    }

    function sendNative(request) {
        const runtime = runtimeObject();
        if (!runtime || typeof runtime.sendNativeMessage !== "function") {
            return Promise.reject(new Error("Ora native extension bridge is unavailable"));
        }

        return new Promise((resolve, reject) => {
            let settled = false;
            const finish = (value, error) => {
                if (settled) return;
                settled = true;
                if (error) reject(error);
                else {
                    try { resolve(normalizeResponse(value)); }
                    catch (caught) { reject(caught); }
                }
            };

            try {
                const maybePromise = runtime.sendNativeMessage(HOST, request, (response) => finish(response, null));
                if (maybePromise && typeof maybePromise.then === "function") {
                    maybePromise.then((response) => finish(response, null), (error) => finish(null, error));
                }
            } catch (error) {
                finish(null, error);
            }
        });
    }

    async function tabMetadata(tabId) {
        if (tabId == null || !nativeTabsAPI || typeof nativeTabsAPI.get !== "function") return null;
        try {
            const tab = await nativeTabsAPI.get(tabId);
            if (!tab) return null;
            return {
                id: tab.id,
                index: tab.index,
                windowId: tab.windowId,
                active: tab.active,
                pinned: tab.pinned,
                url: tab.url,
                pendingUrl: tab.pendingUrl,
                title: tab.title
            };
        } catch (_error) {
            return null;
        }
    }

    async function prepareArgs(namespace, method, suppliedArgs) {
        const args = Array.from(suppliedArgs);
        if (namespace === "pageCapture" && method === "saveAsMHTML" && args[0] && typeof args[0] === "object") {
            const details = { ...args[0] };
            details.__oraTab = await tabMetadata(details.tabId);
            args[0] = details;
        }
        if (namespace === "tabCapture" && method === "getMediaStreamId" && args[0] && typeof args[0] === "object") {
            const options = { ...args[0] };
            options.__oraTab = await tabMetadata(options.targetTabId);
            args[0] = options;
        }
        return args;
    }

    function invoke(namespace, method, suppliedArgs) {
        const args = Array.from(suppliedArgs);
        const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
        const promise = prepareArgs(namespace, method, args)
            .then((preparedArgs) => sendNative({ kind: "call", namespace, method, args: preparedArgs }));

        if (callback) {
            promise.then(
                (result) => callback(result),
                (error) => {
                    bridgeLastError = { message: error && error.message ? error.message : String(error) };
                    try { callback(undefined); }
                    finally { bridgeLastError = null; }
                }
            );
            return undefined;
        }
        return promise;
    }

    function postEventResponse(requestId, result, error) {
        if (!eventPort || !requestId) return;
        try {
            eventPort.postMessage({
                kind: "eventResponse",
                requestId,
                result: result === undefined ? null : result,
                error: error ? { message: error && error.message ? error.message : String(error) } : null
            });
        } catch (postError) {
            console.error("[Ora Extensions] unable to post event response", postError);
        }
    }

    function dispatchBridgeEvent(message) {
        const key = `${message.namespace}.${message.event}`;
        const listeners = eventListeners.get(key);
        const args = Array.isArray(message.args) ? message.args : [];

        if (!listeners || listeners.size === 0) {
            if (message.expectsResponse) postEventResponse(message.requestId, null, null);
            return;
        }

        let settled = false;
        const respond = (value) => {
            if (settled) return;
            settled = true;
            postEventResponse(message.requestId, value, null);
        };
        const reject = (error) => {
            if (settled) return;
            settled = true;
            postEventResponse(message.requestId, null, error);
        };

        for (const listener of Array.from(listeners)) {
            try {
                const listenerArgs = message.expectsResponse ? [...args, respond] : args;
                const returned = listener(...listenerArgs);
                if (message.expectsResponse && returned && typeof returned.then === "function") {
                    returned.then(respond, reject);
                } else if (message.expectsResponse && returned !== undefined && returned !== true) {
                    respond(returned);
                }
            } catch (error) {
                if (message.expectsResponse) reject(error);
                else console.error("[Ora Extensions] event listener failed", error);
            }
        }
    }

    function ensureEventPort() {
        if (eventPort) return;
        const runtime = runtimeObject();
        if (!runtime || typeof runtime.connectNative !== "function") return;
        try {
            eventPort = runtime.connectNative(HOST);
            eventPort.onMessage.addListener((message) => {
                if (!message || message.kind !== "event") return;
                dispatchBridgeEvent(message);
            });
            eventPort.onDisconnect.addListener(() => { eventPort = null; });
        } catch (error) {
            console.error("[Ora Extensions] unable to connect event bridge", error);
        }
    }

    function makeEvent(namespace, eventName) {
        const key = `${namespace}.${eventName}`;
        return {
            addListener(listener) {
                if (typeof listener !== "function") return;
                let listeners = eventListeners.get(key);
                if (!listeners) {
                    listeners = new Set();
                    eventListeners.set(key, listeners);
                }
                listeners.add(listener);
                ensureEventPort();
            },
            removeListener(listener) { eventListeners.get(key)?.delete(listener); },
            hasListener(listener) { return eventListeners.get(key)?.has(listener) || false; },
            hasListeners() { return (eventListeners.get(key)?.size || 0) > 0; }
        };
    }

    function makeNamespace(namespace, existing = {}) {
        const events = new Map();
        return new Proxy(existing || {}, {
            get(target, property, receiver) {
                if (property === "then") return undefined;
                if (namespace === "runtime" && property === "lastError" && bridgeLastError) return bridgeLastError;
                if (typeof property !== "string") return Reflect.get(target, property, receiver);

                const staticValue = STATIC_VALUES[namespace] && STATIC_VALUES[namespace][property];
                if (staticValue !== undefined) return staticValue;

                let nativeValue;
                try { nativeValue = Reflect.get(target, property, receiver); }
                catch (_error) { nativeValue = undefined; }
                if (nativeValue !== undefined && nativeValue !== null) {
                    return typeof nativeValue === "function" ? nativeValue.bind(target) : nativeValue;
                }

                if (/^on[A-Z]/.test(property)) {
                    if (!events.has(property)) events.set(property, makeEvent(namespace, property));
                    return events.get(property);
                }
                return (...args) => invoke(namespace, property, args);
            }
        });
    }

    function makeSetting(namespace, property) {
        const fullNamespace = `${namespace}.${property}`;
        return {
            get(details, callback) {
                if (typeof details === "function") return invoke(fullNamespace, "get", [details]);
                return invoke(fullNamespace, "get", callback ? [details || {}, callback] : [details || {}]);
            },
            set(details, callback) { return invoke(fullNamespace, "set", callback ? [details || {}, callback] : [details || {}]); },
            clear(details, callback) { return invoke(fullNamespace, "clear", callback ? [details || {}, callback] : [details || {}]); },
            onChange: makeEvent(fullNamespace, "onChange")
        };
    }

    function makeSettingsNamespace(namespace) {
        const cache = new Map();
        return new Proxy({}, {
            get(_target, property) {
                if (property === "then") return undefined;
                if (typeof property !== "string") return undefined;
                if (!cache.has(property)) cache.set(property, makeSetting(namespace, property));
                return cache.get(property);
            }
        });
    }

    function makePrivacyNamespace(existing) {
        const value = existing || {};
        if (!value.network) value.network = makeSettingsNamespace("privacy.network");
        if (!value.services) value.services = makeSettingsNamespace("privacy.services");
        if (!value.websites) value.websites = makeSettingsNamespace("privacy.websites");
        return value;
    }

    function makeProxyNamespace(existing) {
        const value = existing || {};
        if (!value.settings) value.settings = makeSetting("proxy", "settings");
        return makeNamespace("proxy", value);
    }

    function installPath(root, path, valueFactory) {
        const components = path.split(".");
        let object = root;
        for (let index = 0; index < components.length - 1; ++index) {
            const component = components[index];
            if (!object[component]) object[component] = {};
            object = object[component];
        }
        const leaf = components[components.length - 1];
        const existing = object[leaf];
        const replacement = valueFactory(existing);
        if (replacement === existing) return;

        try { object[leaf] = replacement; } catch (_error) {}
        if (object[leaf] !== replacement) {
            try {
                Object.defineProperty(object, leaf, {
                    value: replacement,
                    configurable: true,
                    enumerable: true
                });
            } catch (_error) {}
        }
    }

    for (const namespace of EXTENSION_NAMESPACES) {
        let factory = (existing) => makeNamespace(namespace, existing || {});
        if (namespace === "accessibilityFeatures" || namespace === "contentSettings") {
            factory = (existing) => existing || makeSettingsNamespace(namespace);
        } else if (namespace === "privacy") {
            factory = makePrivacyNamespace;
        } else if (namespace === "proxy") {
            factory = makeProxyNamespace;
        }
        installPath(chromeRoot, namespace, factory);
        installPath(browserRoot, namespace, factory);
    }
})();
"""#
}
