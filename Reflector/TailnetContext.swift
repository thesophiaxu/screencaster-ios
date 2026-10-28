// Interface enumeration adapted from AwgScale (BSD-3-Clause); see TailscaleCore/LICENSE.
import Foundation
import Security
import Libtailscale
import os

final class TailnetContext: NSObject, LibtailscaleAppContextProtocol {
    private let service = "me.sophiaxu.phantommonitor.tailnet"
    private let logger = Logger(subsystem: "me.sophiaxu.phantommonitor.reflector", category: "tailscale")
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }
    func log(_ tag: String?, logLine: String?) {
        logger.debug("\(tag ?? "go", privacy: .public): \(logLine ?? "", privacy: .private)")
    }
    func encrypt(toPref key: String?, value: String?) throws {
        guard let key, let value else { return }
        let attrs: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query(key) as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query(key).merging(attrs) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    func decrypt(fromPref key: String?, error: NSErrorPointer) -> String {
        guard let key else { return "" }
        var q = query(key); q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else { error?.pointee = NSError(domain: NSOSStatusErrorDomain, code: Int(status)); return "" }
        return (result as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    func getStateStoreKeysJSON() -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                               kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return "[]" }
        let keys = items.compactMap { $0[kSecAttrAccount as String] as? String }
            .filter { $0.hasPrefix("statestore-") }.map { String($0.dropFirst("statestore-".count)) }
        return String(data: (try? JSONEncoder().encode(keys)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
    }
    func getOSVersion(_ error: NSErrorPointer) -> String { ProcessInfo.processInfo.operatingSystemVersionString }
    func getDeviceName(_ error: NSErrorPointer) -> String { "Phantom Duo" }
    func getInstallSource() -> String { "development" }
    func shouldUseGoogleDNSFallback() -> Bool { false }
    func isChromeOS(_ result: UnsafeMutablePointer<ObjCBool>?) throws { result?.pointee = false }
    func getPlatformDNSConfig() -> String { "" }
    private func unsupported() -> NSError { NSError(domain: "syspolicy", code: 0, userInfo: [NSLocalizedDescriptionKey: "no such key"]) }
    func getSyspolicyStringValue(_ key: String?, error: NSErrorPointer) -> String { error?.pointee = unsupported(); return "" }
    func getSyspolicyBooleanValue(_ key: String?, ret0_: UnsafeMutablePointer<ObjCBool>?) throws { throw unsupported() }
    func getSyspolicyStringArrayJSONValue(_ key: String?, error: NSErrorPointer) -> String { error?.pointee = unsupported(); return "[]" }
    func hardwareAttestationKeySupported() -> Bool { false }
    func hardwareAttestationKeyCreate(_ error: NSErrorPointer) -> String { error?.pointee = unsupported(); return "" }
    func hardwareAttestationKeyLoad(_ keyID: String?) throws { throw unsupported() }
    func hardwareAttestationKeyRelease(_ keyID: String?) throws { throw unsupported() }
    func hardwareAttestationKeyPublic(_ keyID: String?) throws -> Data { throw unsupported() }
    func hardwareAttestationKeySign(_ keyID: String?, data: Data?) throws -> Data { throw unsupported() }
    func getInterfacesAsJson(_ error: NSErrorPointer) -> String {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else {
            return "[]"
        }
        defer { freeifaddrs(addrs) }

        // Collect interfaces and their addresses
        var ifaceMap: [String: (flags: UInt32, addrs: [[String: Any]])] = [:]
        var cursor = addrs
        while let ifa = cursor {
            let name = String(cString: ifa.pointee.ifa_name)
            let flags = ifa.pointee.ifa_flags

            if ifaceMap[name] == nil {
                ifaceMap[name] = (flags: flags, addrs: [])
            }

            if let sa = ifa.pointee.ifa_addr {
                let family = sa.pointee.sa_family
                if family == UInt8(AF_INET) {
                    sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        var addr = sin.pointee.sin_addr
                        inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
                        let ip = String(cString: buf)
                        var prefixLen = 32
                        if let netmask = ifa.pointee.ifa_netmask {
                            netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { nm in
                                let mask = UInt32(bigEndian: nm.pointee.sin_addr.s_addr)
                                prefixLen = mask.nonzeroBitCount
                            }
                        }
                        ifaceMap[name]?.addrs.append(["ip": ip, "prefixLen": prefixLen])
                    }
                } else if family == UInt8(AF_INET6) {
                    sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                        var addr = sin6.pointee.sin6_addr
                        inet_ntop(AF_INET6, &addr, &buf, socklen_t(INET6_ADDRSTRLEN))
                        var ip = String(cString: buf)
                        if sin6.pointee.sin6_scope_id != 0 {
                            ip += "%\(name)"
                        }
                        var prefixLen = 128
                        if let netmask = ifa.pointee.ifa_netmask {
                            netmask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { nm in
                                let bytes = withUnsafeBytes(of: nm.pointee.sin6_addr) { Array($0) }
                                prefixLen = bytes.reduce(0) { $0 + $1.nonzeroBitCount }
                            }
                        }
                        ifaceMap[name]?.addrs.append(["ip": ip, "prefixLen": prefixLen])
                    }
                }
            }

            cursor = ifa.pointee.ifa_next
        }

        // Build JSON array
        var result: [[String: Any]] = []
        for (name, info) in ifaceMap {
            let idx = if_nametoindex(name)
            let iface: [String: Any] = [
                "name": name,
                "index": Int(idx),
                "mtu": 0, // MTU requires ioctl, skip for now
                "up": (info.flags & UInt32(IFF_UP)) != 0,
                "broadcast": (info.flags & UInt32(IFF_BROADCAST)) != 0,
                "loopback": (info.flags & UInt32(IFF_LOOPBACK)) != 0,
                "pointToPoint": (info.flags & UInt32(IFF_POINTOPOINT)) != 0,
                "multicast": (info.flags & UInt32(IFF_MULTICAST)) != 0,
                "addrs": info.addrs,
            ]
            result.append(iface)
        }

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: result)
            return String(data: jsonData, encoding: .utf8) ?? "[]"
        } catch let err as NSError {
            error?.pointee = err
            return "[]"
        }
    }


}

final class TailnetInput: NSObject, LibtailscaleInputStreamProtocol {
    private var data: Data?
    init(_ data: Data) { self.data = data }
    func read() throws -> Data { defer { data = nil }; return data ?? Data() }
    func close() throws { data = nil }
}
