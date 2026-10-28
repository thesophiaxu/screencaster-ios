// Built on AwgScale's Go bridge (BSD-3-Clause); see TailscaleCore/LICENSE.
import Foundation
import Network
import NetworkExtension
import Libtailscale
import os


final class TailnetBackend: NSObject, LibtailscalePacketCallbackProtocol, LibtailscaleTunnelConfigCallbackProtocol {
    static let defaults = UserDefaults(suiteName: "group.me.sophiaxu.phantomcapture")!
    static func failure(_ message: String) -> NSError { NSError(domain: "PhantomTailnet", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private weak var provider: NEPacketTunnelProvider?
    private let control = DispatchQueue(label: "PhantomTailnetControl", qos: .utility)
    private let pathQueue = DispatchQueue(label: "PhantomTailnetPath")
    private let context = TailnetContext()
    private let lock = NSLock()
    private let configLock = NSLock()
    private var application: (any LibtailscaleApplicationProtocol)?
    private var stopping = false
    private var routesEnabled = true
    private var routingError: String?
    private var monitor: NWPathMonitor?
    init(provider: NEPacketTunnelProvider) { self.provider = provider }
    private func app() -> (any LibtailscaleApplicationProtocol)? { lock.lock(); defer { lock.unlock() }; return application }
    private func isStopping() -> Bool { lock.lock(); defer { lock.unlock() }; return stopping }

    func start() {
        control.async {
            guard !self.isStopping(), self.app() == nil else { return }
            do {
                let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tailnet", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                let monitor = NWPathMonitor()
                monitor.pathUpdateHandler = { path in
                    if let iface = path.availableInterfaces.first(where: { path.usesInterfaceType($0.type) && ($0.type == .wifi || $0.type == .cellular || $0.type == .wiredEthernet) }) {
                        LibtailscaleUpdateLastKnownDefaultRouteInterface(iface.name)
                    }
                }
                self.monitor = monitor; monitor.start(queue: self.pathQueue)
                guard let application = LibtailscaleStart(directory.path, "", false, self.context) else { throw Self.failure("Tailscale core did not start") }
                self.lock.lock(); self.application = application; self.lock.unlock()
                application.setPacketCallback(self)
                LibtailscaleSetTunnelConfigCallback(application, self)
                _ = try self.api("PATCH", "prefs", ["Hostname": "phantom-duo", "HostnameSet": true, "WantRunning": true, "WantRunningSet": true])
            } catch { self.lock.lock(); self.routingError = error.localizedDescription; self.lock.unlock() }
        }
    }
    func stop() {
        lock.lock(); stopping = true; lock.unlock()
        monitor?.cancel()
        control.async {
            if let application = self.app() {
                application.setPacketCallback(nil)
                LibtailscaleSetTunnelConfigCallback(application, nil)
                application.stop()
            }
            self.lock.lock(); self.application = nil; self.lock.unlock()
        }
    }
    func inject(_ data: Data) -> Bool {
        guard !isStopping(), let application = app() else { return false }
        do { try application.injectInboundPacket(data); return true } catch { return false }
    }
    func onPacket(_ packet: Data?) throws {
        guard !isStopping(), let packet, let first = packet.first, let provider else { return }
        let version = first >> 4
        guard version == 4 || version == 6 else { return }
        guard provider.packetFlow.writePackets([packet], withProtocols: [NSNumber(value: version == 4 ? AF_INET : AF_INET6)]) else { throw Self.failure("Packet flow write failed") }
    }
    func onTunnelConfigUpdate(_ configJSON: Data?) throws {
        guard let configJSON else { return }
        let config = try JSONDecoder().decode(TailnetRoutes.self, from: configJSON)
        try apply(config)
    }
    private func apply(_ config: TailnetRoutes?) throws {
        configLock.lock(); defer { configLock.unlock() }
        guard !isStopping(), let provider else { return }
        lock.lock(); let useRoutes = routesEnabled; lock.unlock()
        let settings = try TailnetRoutes.settings(useRoutes ? config : nil)
        let sem = DispatchSemaphore(value: 0)
        let result = SettingsResult()
        provider.setTunnelNetworkSettings(settings) { error in result.set(error); sem.signal() }
        let completed = sem.wait(timeout: .now() + 12) == .success
        let error = completed ? result.get() : Self.failure("Timed out applying Tailscale routes")
        lock.lock(); routingError = error?.localizedDescription; lock.unlock()
        if let error {
            // A late settings completion must not leave an apparently healthy VPN.
            provider.cancelTunnelWithError(error)
            throw error
        }
    }
    private final class SettingsResult {
        let lock = NSLock(); var error: Error?
        func set(_ value: Error?) { lock.lock(); error = value; lock.unlock() }
        func get() -> Error? { lock.lock(); defer { lock.unlock() }; return error }
    }
    @discardableResult private func api(_ method: String, _ endpoint: String, _ body: [String: Any]? = nil) throws -> [String: Any] {
        guard let application = app() else { throw Self.failure("Tailscale core is not ready") }
        let input = try body.map { TailnetInput(try JSONSerialization.data(withJSONObject: $0)) }
        let response = try application.callLocalAPI(8000, method: method, endpoint: "/localapi/v0/" + endpoint, body: input)
        let bytes = try response.bodyBytes()
        guard (200..<300).contains(response.statusCode()) else { throw Self.failure("Tailscale \(endpoint) failed (HTTP \(response.statusCode()))") }
        guard !bytes.isEmpty else { return [:] }
        return (try JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:]
    }
    private func snapshot() throws -> [String: Any] {
        let status = try api("GET", "status")
        let prefs = try api("GET", "prefs")
        let myself = status["Self"] as? [String: Any] ?? [:]
        let peers = status["Peer"] as? [String: [String: Any]] ?? [:]
        let mapped = peers.values.sorted { ($0["HostName"] as? String ?? "") < ($1["HostName"] as? String ?? "") }.prefix(500).map { peer -> [String: Any] in
            ["id": peer["ID"] as? String ?? "", "name": peer["HostName"] as? String ?? "", "dnsName": peer["DNSName"] as? String ?? "",
             "ips": peer["TailscaleIPs"] as? [String] ?? [], "online": peer["Online"] as? Bool ?? false,
             "exitNode": peer["ExitNodeOption"] as? Bool ?? false]
        }
        lock.lock(); let routeError = routingError; lock.unlock()
        var output: [String: Any] = ["state": status["BackendState"] as? String ?? "Starting", "authURL": status["AuthURL"] as? String ?? "",
            "name": myself["HostName"] as? String ?? "phantom-duo", "ips": status["TailscaleIPs"] as? [String] ?? [],
            "tailnet": (status["CurrentTailnet"] as? [String: Any])?["Name"] as? String ?? "",
            "peers": mapped, "peerCount": peers.count, "dns": prefs["CorpDNS"] as? Bool ?? true, "subnets": prefs["RouteAll"] as? Bool ?? false,
            "exitNodeID": prefs["ExitNodeID"] as? String ?? "", "wantRunning": prefs["WantRunning"] as? Bool ?? false,
            "health": status["Health"] as? [String] ?? [], "availableMiB": Double(os_proc_available_memory()) / 1048576,
            "version": LibtailscaleCoreVersion(), "memory": PhantomExtensionMemory()]
        if let routeError { output["error"] = routeError }
        return output
    }
    func handle(_ data: Data, reply: @escaping (Data?) -> Void) {
        control.async {
            do {
                guard data.count < 4096, let request = try JSONSerialization.jsonObject(with: data) as? [String: Any], let command = request["command"] as? String else { throw Self.failure("Invalid request") }
                switch command {
                case "status": break
                case "connect", "login":
                    self.lock.lock(); self.routesEnabled = true; self.lock.unlock()
                    _ = try self.api("PATCH", "prefs", ["WantRunning": true, "WantRunningSet": true])
                    Self.defaults.set(true, forKey: "tailnetEnabled")
                    if command == "login" { _ = try self.api("POST", "login-interactive") }
                case "disconnect", "logout":
                    if command == "logout" { _ = try self.api("POST", "logout") }
                    else { _ = try self.api("PATCH", "prefs", ["WantRunning": false, "WantRunningSet": true]) }
                    self.lock.lock(); self.routesEnabled = false; self.lock.unlock()
                    try self.apply(nil)
                    Self.defaults.set(false, forKey: "tailnetEnabled")
                case "dns", "subnets":
                    guard let value = request["value"] as? Bool else { throw Self.failure("Expected a toggle value") }
                    let field = command == "dns" ? "CorpDNS" : "RouteAll"
                    _ = try self.api("PATCH", "prefs", [field: value, field + "Set": true])
                case "exit":
                    guard let id = request["value"] as? String, id.count < 256 else { throw Self.failure("Invalid exit node") }
                    let status = try self.api("GET", "status")
                    let peers = status["Peer"] as? [String: [String: Any]] ?? [:]
                    guard id.isEmpty || peers.values.contains(where: { $0["ID"] as? String == id && $0["ExitNodeOption"] as? Bool == true }) else { throw Self.failure("Exit node is no longer available") }
                    _ = try self.api("PATCH", "prefs", ["ExitNodeID": id, "ExitNodeIDSet": true, "ExitNodeAllowLANAccess": false, "ExitNodeAllowLANAccessSet": true])
                default: throw Self.failure("Unknown command")
                }
                reply(try JSONSerialization.data(withJSONObject: self.snapshot()))
            } catch {
                reply(try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription]))
            }
        }
    }
}
