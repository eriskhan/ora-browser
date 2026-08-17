enum OraChromeDeclarativeContentBridgeScript {
    static let source = #"""
(() => {
    const HOST = 'com.orabrowser.extension-api';
    const chromeRoot = globalThis.chrome || (globalThis.chrome = {});
    const browserRoot = globalThis.browser || (globalThis.browser = {});
    const runtime = chromeRoot.runtime || browserRoot.runtime;

    function callHost(method, args) {
        return new Promise((resolve, reject) => {
            if (!runtime || typeof runtime.sendNativeMessage !== 'function') {
                reject(new Error('Ora native extension bridge is unavailable'));
                return;
            }
            let settled = false;
            const finish = (response, error) => {
                if (settled) return;
                settled = true;
                if (error) { reject(error); return; }
                if (!response || response.ok !== true) {
                    const detail = response && response.error ? response.error : {};
                    const bridgeError = new Error(detail.message || 'Ora extension API call failed');
                    bridgeError.code = detail.code || 'ORA_EXTENSION_API_ERROR';
                    reject(bridgeError);
                    return;
                }
                resolve(response.result);
            };
            try {
                const result = runtime.sendNativeMessage(HOST, {
                    kind: 'call', namespace: 'declarativeContent', method, args
                }, (response) => finish(response, null));
                if (result && typeof result.then === 'function') {
                    result.then((response) => finish(response, null), (error) => finish(null, error));
                }
            } catch (error) { finish(null, error); }
        });
    }

    function serializable(value) {
        if (typeof ImageData !== 'undefined' && value instanceof ImageData) {
            return { __oraImageData: true, width: value.width, height: value.height, data: Array.from(value.data) };
        }
        if (Array.isArray(value)) return value.map(serializable);
        if (value && typeof value === 'object') {
            const result = {};
            for (const [key, nested] of Object.entries(value)) result[key] = serializable(nested);
            return result;
        }
        return value;
    }

    class PageStateMatcher {
        constructor(arg = {}) { Object.assign(this, serializable(arg)); this.__oraType = 'PageStateMatcher'; }
    }
    class ShowAction { constructor() { this.__oraType = 'ShowAction'; } }
    class ShowPageAction { constructor() { this.__oraType = 'ShowPageAction'; } }
    class SetIcon {
        constructor(arg = {}) { Object.assign(this, serializable(arg)); this.__oraType = 'SetIcon'; }
    }
    class RequestContentScript {
        constructor(arg = {}) { Object.assign(this, serializable(arg)); this.__oraType = 'RequestContentScript'; }
    }

    function withCallback(promise, callback) {
        if (typeof callback !== 'function') return promise;
        promise.then((value) => callback(value), () => callback(undefined));
        return undefined;
    }

    const onPageChanged = {
        addRules(rules, callback) {
            return withCallback(callHost('addRules', [serializable(rules || [])]), callback);
        },
        removeRules(ruleIdentifiers, callback) {
            if (typeof ruleIdentifiers === 'function') {
                callback = ruleIdentifiers;
                ruleIdentifiers = undefined;
            }
            return withCallback(callHost('removeRules', [ruleIdentifiers || null]), callback);
        },
        getRules(ruleIdentifiers, callback) {
            if (typeof ruleIdentifiers === 'function') {
                callback = ruleIdentifiers;
                ruleIdentifiers = undefined;
            }
            return withCallback(callHost('getRules', [ruleIdentifiers || null]), callback);
        }
    };

    function install(root) {
        if (!root) return;
        const namespace = root.declarativeContent || {};
        const values = { PageStateMatcher, ShowAction, ShowPageAction, SetIcon, RequestContentScript, onPageChanged };
        for (const [key, value] of Object.entries(values)) {
            try { namespace[key] = value; } catch (_) {}
            if (namespace[key] !== value) {
                try { Object.defineProperty(namespace, key, { value, configurable: true, enumerable: true }); } catch (_) {}
            }
        }
        try { root.declarativeContent = namespace; } catch (_) {}
    }

    install(chromeRoot);
    install(browserRoot);
})();
"""#
}
