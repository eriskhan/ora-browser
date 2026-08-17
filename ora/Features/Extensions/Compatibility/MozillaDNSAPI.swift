import Darwin
import Foundation
@preconcurrency import WebKit

@MainActor
enum MozillaDNSAPI {
    private struct Resolution: Sendable {
        let addresses: [String]
        let canonicalName: String?
    }

    static func handle(method: String, arguments: [Any]) async throws -> Any {
        guard method == "resolve" else {
            throw MozillaNativeAPIBridge.BridgeError.unsupportedMethod("dns", method)
        }
        guard let hostname = arguments.first as? String, !hostname.isEmpty else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "browser.dns.resolve requires a hostname."
            )
        }

        let flags = Set(arguments.dropFirst().first as? [String] ?? [])
        let knownFlags: Set<String> = [
            "allow_name_collisions",
            "bypass_cache",
            "canonical_name",
            "disable_ipv4",
            "disable_ipv6",
            "disable_trr",
            "offline",
            "priority_low",
            "priority_medium",
            "speculate"
        ]
        let unknown = flags.subtracting(knownFlags)
        guard unknown.isEmpty else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "Unknown browser.dns.resolve flags: \(unknown.sorted().joined(separator: ", "))."
            )
        }
        guard !flags.contains("bypass_cache") else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "Ora cannot guarantee a cache-bypassing system DNS lookup on macOS."
            )
        }
        guard !flags.contains("offline") else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "Ora cannot safely restrict the macOS resolver to cached records only."
            )
        }
        guard !flags.contains("speculate") else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "Ora has no browser DNS-prefetch policy equivalent for speculative lookups."
            )
        }
        guard !(flags.contains("disable_ipv4") && flags.contains("disable_ipv6")) else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "browser.dns.resolve cannot disable both IPv4 and IPv6."
            )
        }

        let family: Int32
        if flags.contains("disable_ipv4") {
            family = AF_INET6
        } else if flags.contains("disable_ipv6") {
            family = AF_INET
        } else {
            family = AF_UNSPEC
        }
        let wantsCanonicalName = flags.contains("canonical_name")
        let priority: TaskPriority = flags.contains("priority_low") && !flags.contains("priority_medium")
            ? .background
            : .userInitiated

        let resolution = try await Task.detached(priority: priority) {
            try resolve(hostname: hostname, family: family, canonicalName: wantsCanonicalName)
        }.value

        var record: [String: Any] = [
            "addresses": resolution.addresses,
            "isTRR": false
        ]
        if wantsCanonicalName, let canonicalName = resolution.canonicalName {
            record["canonicalName"] = canonicalName
        }
        return record
    }

    private static func resolve(
        hostname: String,
        family: Int32,
        canonicalName: Bool
    ) throws -> Resolution {
        var hints = addrinfo(
            ai_flags: canonicalName ? AI_CANONNAME : 0,
            ai_family: family,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostname, nil, &hints, &result)
        guard status == 0, let first = result else {
            let message = String(cString: gai_strerror(status))
            throw MozillaNativeAPIBridge.BridgeError.itemNotFound(
                "DNS resolution failed for \(hostname): \(message)."
            )
        }
        defer { freeaddrinfo(first) }

        var addresses: [String] = []
        var seen = Set<String>()
        var canonical: String?
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            let info = current.pointee
            if canonical == nil, let name = info.ai_canonname {
                canonical = String(cString: name)
            }
            if let address = info.ai_addr {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    address,
                    info.ai_addrlen,
                    &buffer,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    let value = String(cString: buffer)
                    if seen.insert(value).inserted {
                        addresses.append(value)
                    }
                }
            }
            cursor = info.ai_next
        }

        guard !addresses.isEmpty else {
            throw MozillaNativeAPIBridge.BridgeError.itemNotFound(
                "DNS resolution for \(hostname) returned no addresses."
            )
        }
        return Resolution(addresses: addresses, canonicalName: canonical)
    }
}
