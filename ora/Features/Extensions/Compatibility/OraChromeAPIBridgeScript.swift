import Foundation

enum OraChromeAPIBridgeScript {
    static let applicationIdentifier = "com.orabrowser.extension-api"
    static let fileName = "__ora_chrome_api_bridge.js"

    static var source: String {
        let namespaces = (try? JSONSerialization.data(withJSONObject: ChromeExtensionAPICatalog.bridgeNamespaceNames))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        return template
            .replacingOccurrences(of: "__ORA_BRIDGE_NAMESPACES__", with: namespaces)
            .replacingOccurrences(of: "__ORA_NATIVE_HOST__", with: applicationIdentifier)
    }

    private static let template = #"""
(() => {
    if (globalThis.__oraChromeBridgeInstalled) return;
    globalThis.__oraChromeBridgeInstalled = true;

    const HOST = "__ORA_NATIVE_HOST__";
    const BRIDGE_NAMESPACES = __ORA_BRIDGE_NAMESPACES__;
    const chromeRoot = globalThis.chrome || (globalThis.chrome = {});
    const browserRoot = globalThis.browser || (globalThis.browser = {});
    const runtime = chromeRoot.runtime || browserRoot.runtime;
    const eventListeners = new Map();
    let eventPort = null;

    function normalizeResponse(response) {
        if (!response || response.ok !== true) {
            const detail = response && response.error ? response.error : {};
            const error = new Error(detail.message || "Ora extension API call failed");
            error.code = detail.code || "ORA_EXTENSION_API_ERROR";
            throw error;
        }
        return response.result;
    }

    function sendNative(request) {
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

    function invoke(namespace, method, suppliedArgs) {
        const args = Array.from(suppliedArgs);
        const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
        const promise = sendNative({ kind: "call", namespace, method, args });

        if (callback) {
            promise.then(
                (result) => callback(result),
                (error) => {
                    console.error(`[Ora Extensions] ${namespace}.${method} failed`, error);
                    callback(undefined);
                }
            );
            return undefined;
        }
        return promise;
    }

    function ensureEventPort() {
        if (eventPort || !runtime || typeof runtime.connectNative !== "function") return;
        try {
            eventPort = runtime.connectNative(HOST);
            eventPort.onMessage.addListener((message) => {
                if (!message || message.kind !== "event") return;
                const key = `${message.namespace}.${message.event}`;
                const listeners = eventListeners.get(key);
                if (!listeners) return;
                for (const listener of Array.from(listeners)) {
                    try { listener(...(Array.isArray(message.args) ? message.args : [])); }
                    catch (error) { console.error("[Ora Extensions] event listener failed", error); }
                }
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

    function makeNamespace(namespace) {
        const events = new Map();
        return new Proxy({}, {
            get(_target, property) {
                if (property === "then") return undefined;
                if (typeof property !== "string") return undefined;
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

    function makePrivacyNamespace() {
        return {
            network: makeSettingsNamespace("privacy.network"),
            services: makeSettingsNamespace("privacy.services"),
            websites: makeSettingsNamespace("privacy.websites")
        };
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
        if (object[leaf] == null) object[leaf] = valueFactory();
    }

    for (const namespace of BRIDGE_NAMESPACES) {
        let factory = () => makeNamespace(namespace);
        if (namespace === "accessibilityFeatures" || namespace === "contentSettings") {
            factory = () => makeSettingsNamespace(namespace);
        } else if (namespace === "privacy") {
            factory = makePrivacyNamespace;
        }
        installPath(chromeRoot, namespace, factory);
        installPath(browserRoot, namespace, factory);
    }
})();
"""#
}
