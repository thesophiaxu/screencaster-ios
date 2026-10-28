// Route translation adapted from AwgScale; see TailscaleCore/LICENSE.
import Foundation
import NetworkExtension

struct TailnetRoutes: Decodable {
    var localAddresses: [String]
    var routes: [String]
    var excludeRoutes: [String]?
    var dnsServers: [String]
    var dnsDomains: [String]
    var dnsMatchDomains: [String]?
    var mtu: Int

    private static func routeError(_ message: String) -> NSError { NSError(domain: "PhantomRoutes", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    static func cidr(_ value: String) throws -> (String, Int, Bool) {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]) else { throw routeError("Malformed route") }
        let address = String(parts[0]); let v6 = address.contains(":")
        var bytes = [UInt8](repeating: 0, count: 16)
        guard (0...(v6 ? 128 : 32)).contains(prefix), inet_pton(v6 ? AF_INET6 : AF_INET, address, &bytes) == 1 else { throw routeError("Invalid route address") }
        return (address, prefix, v6)
    }
    static func mask(_ prefix: Int) -> String {
        let n: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
        return [24,16,8,0].map { String((n >> $0) & 255) }.joined(separator: ".")
    }
    static func settings(_ config: TailnetRoutes?) throws -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.7.0.1")
        // iOS uses the first IPv4 address for general tunnel traffic. Put the
        // Tailscale address first; capture explicitly binds its synthetic address.
        var a4 = ["10.7.0.0"], masks = ["255.255.255.0"], a6: [String] = [], p6: [NSNumber] = []
        for value in config?.localAddresses ?? [] {
            let (ip, prefix, v6) = try cidr(value)
            if v6 { a6.append(ip); p6.append(NSNumber(value: prefix)) }
            else if ip != "10.7.0.0" { a4.append(ip); masks.append(mask(prefix)) }
        }
        func routes4(_ list: [String]) throws -> [NEIPv4Route] {
            try list.compactMap { let (ip, p, v6) = try cidr($0); return v6 ? nil : NEIPv4Route(destinationAddress: ip, subnetMask: mask(p)) }
        }
        func routes6(_ list: [String]) throws -> [NEIPv6Route] {
            try list.compactMap { let (ip, p, v6) = try cidr($0); return v6 ? NEIPv6Route(destinationAddress: ip, networkPrefixLength: NSNumber(value: p)) : nil }
        }
        if a4.count > 1 { a4.append(a4.removeFirst()); masks.append(masks.removeFirst()) }
        let v4 = NEIPv4Settings(addresses: a4, subnetMasks: masks)
        v4.includedRoutes = [NEIPv4Route(destinationAddress: "10.7.0.1", subnetMask: "255.255.255.255")] + (try routes4(config?.routes ?? []))
        // A broad excluded route could shadow the reflector. The more-specific
        // reflector route remains included, and no excluded default is installed.
        v4.excludedRoutes = try routes4((config?.excludeRoutes ?? []).filter { $0 != "0.0.0.0/0" && $0 != "10.7.0.1/32" })
        settings.ipv4Settings = v4
        if !a6.isEmpty {
            let v6 = NEIPv6Settings(addresses: a6, networkPrefixLengths: p6)
            v6.includedRoutes = try routes6(config?.routes ?? [])
            v6.excludedRoutes = try routes6((config?.excludeRoutes ?? []).filter { $0 != "::/0" })
            settings.ipv6Settings = v6
        }
        if let config, !config.dnsServers.isEmpty {
            let dns = NEDNSSettings(servers: config.dnsServers)
            dns.matchDomains = config.dnsMatchDomains?.isEmpty == false ? config.dnsMatchDomains : [""]
            dns.searchDomains = config.dnsDomains
            settings.dnsSettings = dns
        }
        settings.mtu = NSNumber(value: max(1280, min(config?.mtu ?? 1280, 1500)))
        return settings
    }
}
