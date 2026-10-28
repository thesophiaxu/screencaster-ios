import Foundation
import NetworkExtension

let local = try TailnetRoutes.settings(nil)
precondition(local.ipv4Settings!.addresses.first == "10.7.0.0")
precondition(local.ipv4Settings!.includedRoutes!.count == 1)
precondition(local.ipv4Settings!.includedRoutes!.first!.destinationAddress == "10.7.0.1")
precondition(local.dnsSettings == nil)
let config = TailnetRoutes(localAddresses: ["100.90.80.70/32", "fd7a:115c:a1e0::1/128"], routes: ["100.64.0.0/10", "fd7a:115c:a1e0::/48", "192.168.99.0/24"], excludeRoutes: [], dnsServers: ["100.100.100.100"], dnsDomains: ["example.ts.net"], dnsMatchDomains: ["example.ts.net"], mtu: 1280)
let split = try TailnetRoutes.settings(config)
precondition(split.ipv4Settings!.addresses == ["100.90.80.70", "10.7.0.0"])
precondition(split.ipv4Settings!.includedRoutes!.count == 3)
precondition(split.ipv6Settings!.includedRoutes!.count == 1)
precondition(split.dnsSettings!.matchDomains == ["example.ts.net"])
precondition(!split.ipv4Settings!.includedRoutes!.contains(where: { $0.destinationSubnetMask == "0.0.0.0" }))
var exit = config; exit.routes += ["0.0.0.0/0", "::/0"]; exit.excludeRoutes = ["8.8.8.8/32"]; exit.dnsMatchDomains = []
let full = try TailnetRoutes.settings(exit)
precondition(full.ipv4Settings!.includedRoutes!.contains(where: { $0.destinationSubnetMask == "0.0.0.0" }))
precondition(full.ipv6Settings!.includedRoutes!.contains(where: { $0.destinationNetworkPrefixLength == 0 }))
precondition(full.ipv4Settings!.excludedRoutes!.count == 1)
precondition(full.dnsSettings!.matchDomains == [""])
for invalid in ["1.2.3.4/33", "1.2.3.4/-1", "garbage/24", "fd00::1/129", "1.2.3.4", "1.2.3.4/24/4"] {
    do { _ = try TailnetRoutes.cidr(invalid); fatalError("accepted invalid CIDR") } catch {}
}
print("PASS: reflector preservation, dual-stack split routes, DNS scope, exit routes, invalid CIDRs")
