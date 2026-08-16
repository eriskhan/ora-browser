import Darwin
import Foundation
import Network
@preconcurrency import WebKit

extension OraChromeExtensionAPIHost {
    func handleDNS(method: String, args: [Any]) throws -> Any? {
        guard method == "resolve" else { throw BridgeError.unsupportedMethod("dns", method) }
        guard let hostname = stringArgument(args, at: 0), !hostname.isEmpty,
              !hostname.contains("://"), !hostname.contains("/")
        else {
            throw BridgeError.invalidArguments("dns.resolve requires a hostname without a URL scheme or path.")
        }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostname, nil, &hints, &result)
        guard status == 0, let first = result else {
            if result != nil { freeaddrinfo(result) }
            return ["resultCode": status]
        }
        defer { freeaddrinfo(first) }

        var current: UnsafeMutablePointer<addrinfo>? = first
        while let info = current {
            if let address = numericAddress(info.pointee) {
                return ["resultCode": 0, "address": address]
            }
            current = info.pointee.ai_next
        }
        return ["resultCode": EAI_NONAME]
    }

    func handleEnterpriseHardwarePlatform(method: String) throws -> Any? {
        guard method == "getHardwarePlatformInfo" else {
            throw BridgeError.unsupportedMethod("enterprise.hardwarePlatform", method)
        }
        return [
            "manufacturer": "Apple Inc.",
            "model": hardwareModel()
        ]
    }

    func handleIdentity(
        method: String,
        args: [Any],
        context: WKWebExtensionContext
    ) async throws -> Any? {
        let runtimeIdentifier = WebExtensionManager.shared.installedExtension(for: context)?.runtimeIdentifier
            ?? context.uniqueIdentifier
        let redirectBase = "https://\(runtimeIdentifier).chromiumapp.org/"

        switch method {
        case "getRedirectURL":
            let path = stringArgument(args, at: 0) ?? ""
            let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
            return redirectBase + normalizedPath
        case "getProfileUserInfo":
            return ["email": "", "id": ""]
        case "getAccounts":
            return []
        case "clearAllCachedAuthTokens", "removeCachedAuthToken":
            return nil
        case "launchWebAuthFlow":
            let details = dictionaryArgument(args)
            guard let rawURL = details["url"] as? String, let url = URL(string: rawURL) else {
                throw BridgeError.invalidArguments("identity.launchWebAuthFlow requires a valid URL.")
            }
            return try await WebExtensionAuthFlowCoordinator.shared.start(
                url: url,
                redirectPrefix: redirectBase,
                context: context
            )
        case "getAuthToken":
            throw BridgeError.unsupportedMethod("identity", method)
        default:
            throw BridgeError.unsupportedMethod("identity", method)
        }
    }

    func handleProxySetting(method: String, args: [Any], spaceID: UUID) throws -> Any? {
        let defaultsKey = "webExtensions.proxy.\(spaceID.uuidString)"
        let profile = BrowserEngine.shared.makeProfile(identifier: spaceID, isPrivate: false)

        switch method {
        case "get":
            let value = storedProxyValue(key: defaultsKey) ?? ["mode": "system"]
            return ["value": value, "levelOfControl": "controlled_by_this_extension"]
        case "clear":
            profile.dataStore.proxyConfigurations = []
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            emit(namespace: "proxy.settings", event: "onChange", args: [["value": ["mode": "system"]]], spaceID: spaceID)
            return nil
        case "set":
            let details = dictionaryArgument(args)
            guard let value = details["value"] as? [String: Any], let mode = value["mode"] as? String else {
                throw BridgeError.invalidArguments("proxy.settings.set requires a proxy configuration value.")
            }

            switch mode {
            case "direct", "system":
                profile.dataStore.proxyConfigurations = []
            case "fixed_servers":
                guard let rules = value["rules"] as? [String: Any],
                      let proxy = (rules["singleProxy"] as? [String: Any])
                        ?? (rules["proxyForHttps"] as? [String: Any])
                        ?? (rules["proxyForHttp"] as? [String: Any])
                else {
                    throw BridgeError.invalidArguments("Ora currently requires singleProxy, proxyForHttps, or proxyForHttp for fixed_servers.")
                }
                profile.dataStore.proxyConfigurations = [try makeProxyConfiguration(proxy: proxy, rules: rules)]
            case "pac_script":
                throw BridgeError.unsupportedMethod("proxy.settings", "PAC scripts")
            default:
                throw BridgeError.invalidArguments("Unknown proxy mode: \(mode).")
            }

            storeProxyValue(value, key: defaultsKey)
            emit(namespace: "proxy.settings", event: "onChange", args: [["value": value]], spaceID: spaceID)
            return nil
        default:
            throw BridgeError.unsupportedMethod("proxy.settings", method)
        }
    }

    private func numericAddress(_ info: addrinfo) -> String? {
        guard let socketAddress = info.ai_addr else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = buffer.withUnsafeMutableBufferPointer { pointer in
            getnameinfo(
                socketAddress,
                info.ai_addrlen,
                pointer.baseAddress,
                socklen_t(pointer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
        }
        guard status == 0 else { return nil }
        return String(cString: buffer)
    }

    private func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return "Mac"
        }
        var bytes = [CChar](repeating: 0, count: size)
        let result = bytes.withUnsafeMutableBufferPointer { pointer in
            sysctlbyname("hw.model", pointer.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return "Mac" }
        return String(cString: bytes)
    }

    private func makeProxyConfiguration(
        proxy: [String: Any],
        rules: [String: Any]
    ) throws -> ProxyConfiguration {
        guard let host = proxy["host"] as? String,
              let portNumber = proxy["port"] as? NSNumber,
              let port = NWEndpoint.Port(rawValue: portNumber.uint16Value)
        else {
            throw BridgeError.invalidArguments("Proxy host and port are required.")
        }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
        let scheme = (proxy["scheme"] as? String ?? "http").lowercased()
        var configuration: ProxyConfiguration
        switch scheme {
        case "socks4", "socks5":
            configuration = ProxyConfiguration(socksv5Proxy: endpoint)
        case "https":
            configuration = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: NWProtocolTLS.Options())
        default:
            configuration = ProxyConfiguration(httpCONNECTProxy: endpoint)
        }
        configuration.excludedDomains = rules["bypassList"] as? [String] ?? []
        return configuration
    }

    private func storedProxyValue(key: String) -> [String: Any]? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    private func storeProxyValue(_ value: [String: Any], key: String) {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value)
        else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
