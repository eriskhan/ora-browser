enum OraChromeTabGroupBridgeScript {
    static let source = #"""
(() => {
    const HOST = "com.orabrowser.extension-api";
    const chromeRoot = globalThis.chrome || (globalThis.chrome = {});
    const browserRoot = globalThis.browser || (globalThis.browser = {});
    const runtime = chromeRoot.runtime || browserRoot.runtime;

    function callHost(namespace, method, args) {
        if (!runtime || typeof runtime.sendNativeMessage !== "function") {
            return Promise.reject(new Error("Ora native extension bridge is unavailable"));
        }
        return new Promise((resolve, reject) => {
            let settled = false;
            const finish = (response, error) => {
                if (settled) return;
                settled = true;
                if (error) {
                    reject(error);
                    return;
                }
                if (!response || response.ok !== true) {
                    const detail = response && response.error ? response.error : {};
                    const bridgeError = new Error(detail.message || "Ora extension API call failed");
                    bridgeError.code = detail.code || "ORA_EXTENSION_API_ERROR";
                    reject(bridgeError);
                    return;
                }
                resolve(response.result);
            };
            try {
                const maybePromise = runtime.sendNativeMessage(HOST, { kind: "call", namespace, method, args }, (response) => {
                    finish(response, null);
                });
                if (maybePromise && typeof maybePromise.then === "function") {
                    maybePromise.then((response) => finish(response, null), (error) => finish(null, error));
                }
            } catch (error) {
                finish(null, error);
            }
        });
    }

    function metadata(tab) {
        if (!tab || typeof tab !== "object") return null;
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
    }

    async function decorateTab(tab) {
        if (!tab || typeof tab !== "object") return tab;
        try {
            const groupId = await callHost("tabs", "__oraGetGroupId", [{ __oraTab: metadata(tab) }]);
            tab.groupId = typeof groupId === "number" ? groupId : -1;
        } catch (_error) {
            tab.groupId = -1;
        }
        if (tab.splitViewId == null) tab.splitViewId = -1;
        return tab;
    }

    async function decorateResult(result) {
        if (Array.isArray(result)) {
            return Promise.all(result.map(decorateTab));
        }
        return decorateTab(result);
    }

    function invokeWithCallback(promise, callback) {
        if (typeof callback !== "function") return promise;
        promise.then((value) => callback(value), () => callback(undefined));
        return undefined;
    }

    function wrapTabs(namespace) {
        if (!namespace || namespace.__oraTabGroupsWrapped) return namespace;
        const wrapped = new Proxy(namespace, {
            get(target, property, receiver) {
                if (property === "__oraTabGroupsWrapped") return true;
                if (property === "SPLIT_VIEW_ID_NONE") return -1;
                if (property === "group") {
                    return (options, callback) => {
                        const promise = (async () => {
                            const copy = { ...(options || {}) };
                            const rawIds = Array.isArray(copy.tabIds) ? copy.tabIds : [copy.tabIds];
                            const nativeGet = target.get;
                            const tabs = [];
                            for (const tabId of rawIds) {
                                if (tabId == null || typeof nativeGet !== "function") continue;
                                try {
                                    const tab = await nativeGet.call(target, tabId);
                                    if (tab) tabs.push(metadata(tab));
                                } catch (_error) {}
                            }
                            copy.__oraTabs = tabs;
                            return callHost("tabs", "group", [copy]);
                        })();
                        return invokeWithCallback(promise, callback);
                    };
                }
                if (property === "ungroup") {
                    return (tabIds, callback) => {
                        const promise = (async () => {
                            const rawIds = Array.isArray(tabIds) ? tabIds : [tabIds];
                            const nativeGet = target.get;
                            const tabs = [];
                            for (const tabId of rawIds) {
                                if (tabId == null || typeof nativeGet !== "function") continue;
                                try {
                                    const tab = await nativeGet.call(target, tabId);
                                    if (tab) tabs.push(metadata(tab));
                                } catch (_error) {}
                            }
                            return callHost("tabs", "ungroup", [{ tabIds, __oraTabs: tabs }]);
                        })();
                        return invokeWithCallback(promise, callback);
                    };
                }

                const nativeValue = Reflect.get(target, property, receiver);
                const decoratedMethods = new Set(["create", "duplicate", "get", "getCurrent", "move", "query", "update"]);
                if (typeof property === "string" && decoratedMethods.has(property) && typeof nativeValue === "function") {
                    return (...suppliedArgs) => {
                        const args = Array.from(suppliedArgs);
                        const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
                        let requestedGroupId = null;
                        let requestedSplitViewId = null;
                        if (property === "query" && args[0] && typeof args[0] === "object") {
                            const query = { ...args[0] };
                            if (Object.prototype.hasOwnProperty.call(query, "groupId")) {
                                requestedGroupId = query.groupId;
                                delete query.groupId;
                            }
                            if (Object.prototype.hasOwnProperty.call(query, "splitViewId")) {
                                requestedSplitViewId = query.splitViewId;
                                delete query.splitViewId;
                            }
                            args[0] = query;
                        }

                        let promise;
                        try {
                            if (callback) {
                                promise = new Promise((resolve, reject) => {
                                    const result = nativeValue.apply(target, [...args, (value) => resolve(value)]);
                                    if (result && typeof result.then === "function") result.then(resolve, reject);
                                });
                            } else {
                                promise = Promise.resolve(nativeValue.apply(target, args));
                            }
                        } catch (error) {
                            promise = Promise.reject(error);
                        }

                        promise = promise.then(decorateResult).then((value) => {
                            if (property === "query" && Array.isArray(value)) {
                                let filtered = value;
                                if (requestedGroupId != null) {
                                    filtered = filtered.filter((tab) => tab.groupId === requestedGroupId);
                                }
                                if (requestedSplitViewId != null) {
                                    filtered = filtered.filter((tab) => tab.splitViewId === requestedSplitViewId);
                                }
                                return filtered;
                            }
                            return value;
                        });
                        return invokeWithCallback(promise, callback);
                    };
                }
                return typeof nativeValue === "function" ? nativeValue.bind(target) : nativeValue;
            }
        });
        return wrapped;
    }

    function installTabs(root) {
        if (!root || !root.tabs) return;
        const wrapped = wrapTabs(root.tabs);
        try { root.tabs = wrapped; } catch (_error) {}
        if (root.tabs !== wrapped) {
            try {
                Object.defineProperty(root, "tabs", {
                    value: wrapped,
                    configurable: true,
                    enumerable: true
                });
            } catch (_error) {}
        }
    }

    installTabs(chromeRoot);
    installTabs(browserRoot);
})();
"""#
}
