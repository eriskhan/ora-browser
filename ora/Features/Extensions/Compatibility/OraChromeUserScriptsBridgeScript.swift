enum OraChromeUserScriptsBridgeScript {
    static let source = #"""
(() => {
    const HOST = "com.orabrowser.extension-api";
    const chromeRoot = globalThis.chrome || (globalThis.chrome = {});
    const browserRoot = globalThis.browser || (globalThis.browser = {});
    const runtime = chromeRoot.runtime || browserRoot.runtime;
    const tabs = chromeRoot.tabs || browserRoot.tabs;

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
                const result = runtime.sendNativeMessage(HOST, { kind: 'call', namespace: 'userScripts', method, args }, (response) => finish(response, null));
                if (result && typeof result.then === 'function') result.then((response) => finish(response, null), (error) => finish(null, error));
            } catch (error) { finish(null, error); }
        });
    }

    function metadata(tab) {
        if (!tab) return null;
        return { id: tab.id, index: tab.index, windowId: tab.windowId, active: tab.active, pinned: tab.pinned, url: tab.url, pendingUrl: tab.pendingUrl, title: tab.title };
    }

    function install(root) {
        if (!root || !root.userScripts || root.userScripts.__oraExecuteWrapped) return;
        const native = root.userScripts;
        const wrapped = new Proxy(native, {
            get(target, property, receiver) {
                if (property === '__oraExecuteWrapped') return true;
                if (property !== 'execute') {
                    const value = Reflect.get(target, property, receiver);
                    return typeof value === 'function' ? value.bind(target) : value;
                }
                return (injection, callback) => {
                    const promise = (async () => {
                        const copy = { ...(injection || {}) };
                        copy.target = { ...(copy.target || {}) };
                        const tabId = copy.target.tabId;
                        if (tabId != null && tabs && typeof tabs.get === 'function') {
                            try { copy.target.__oraTab = metadata(await tabs.get(tabId)); } catch (_) {}
                        }
                        return callHost('execute', [copy]);
                    })();
                    if (typeof callback === 'function') {
                        promise.then((value) => callback(value), () => callback(undefined));
                        return undefined;
                    }
                    return promise;
                };
            }
        });
        try { root.userScripts = wrapped; } catch (_) {}
        if (root.userScripts !== wrapped) {
            try { Object.defineProperty(root, 'userScripts', { value: wrapped, configurable: true, enumerable: true }); } catch (_) {}
        }
    }

    install(chromeRoot);
    install(browserRoot);
})();
"""#
}
