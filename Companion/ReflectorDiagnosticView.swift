import SwiftUI
import NetworkExtension

@MainActor final class ReflectorModel: ObservableObject {
    @Published var message = "Loading reflector configuration…"
    @Published var stats = ""
    @Published var connected = false
    @Published var ready = false
    @Published var extensionStatus = "Extension capture has not started."
    private var manager: NETunnelProviderManager?
    private var autoStarted = false
    private var probeStarted = false
    private var directProbeSent = false
    private var setupAttempted = false
    private var extensionProbeSent = false
    let extensionMode = ProcessInfo.processInfo.environment["PHANTOM_REFLECTOR_EXTENSION_CAPTURE"] == "1"
    let global = ProcessInfo.processInfo.environment["PHANTOM_REFLECTOR_GLOBAL"] == "1"
    private func matches(_ candidate: NETunnelProviderManager) -> Bool {
        guard let proto = candidate.protocolConfiguration as? NETunnelProviderProtocol,
              proto.providerBundleIdentifier == "me.sophiaxu.phantommonitor.reflector" else { return false }
        return global ? candidate.routingMethod == .destinationIP && proto.providerConfiguration?["PhantomGlobalTest"] as? Bool == true : candidate.routingMethod == .sourceApplication
    }
    private func createGlobalConfiguration() async throws {
        let candidate = NETunnelProviderManager()
        candidate.localizedDescription = "Phantom Global Reflector Test"
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "me.sophiaxu.phantommonitor.reflector"
        proto.serverAddress = "10.7.0.1"
        proto.providerConfiguration = ["PhantomGlobalTest": true]
        proto.includeAllNetworks = false
        candidate.protocolConfiguration = proto
        candidate.isOnDemandEnabled = false
        candidate.isEnabled = true
        message = "Approve the iOS VPN configuration prompt to prepare the global reflector test."
        log()
        try await candidate.saveToPreferences()
        try await candidate.loadFromPreferences()
    }
    func refresh() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first(where: matches)
            if manager == nil && global && !setupAttempted && ProcessInfo.processInfo.environment["PHANTOM_REFLECTOR_STOP"] != "1" {
                setupAttempted = true
                try await createGlobalConfiguration()
                return
            }
            guard let manager else { ready = false; message = global ? "Global reflector configuration is unavailable." : "Install the Phantom Per-App Reflector profile in Settings, then return here."; log(); return }
            let rules = manager.copyAppRules() ?? []
            ready = global ? manager.routingMethod == .destinationIP : manager.routingMethod == .sourceApplication && !rules.isEmpty
            connected = manager.connection.status == .connected
            message = "Routing: \(manager.routingMethod.rawValue) · app rules: \(rules.count) · VPN: \(manager.connection.status.rawValue)"
            if !ready { message += "\nRefusing to start: routing does not match the selected diagnostic." }
            if let session = manager.connection as? NETunnelProviderSession, connected {
                try? session.sendProviderMessage(Data("status".utf8)) { _ in }
                if extensionMode && !extensionProbeSent {
                    extensionProbeSent = true
                    let pairingURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhantomTunnel/pairing.plist")
                    let args: [String: Any] = ["pairing": try Data(contentsOf: pairingURL), "record": ProcessInfo.processInfo.environment["PHANTOM_EXTENSION_RECORD_VIDEO"] == "1", "seconds": Double(ProcessInfo.processInfo.environment["PHANTOM_TUNNEL_CAPTURE_SECONDS"] ?? "180") ?? 180]
                    var request = Data("extension-capture\0".utf8)
                    request.append(try PropertyListSerialization.data(fromPropertyList: args, format: .binary, options: 0))
                    try session.sendProviderMessage(request) { _ in }
                }
                if !directProbeSent && ProcessInfo.processInfo.environment["PHANTOM_REFLECTOR_DIRECT_AUTH"] == "1" {
                    directProbeSent = true
                    let pairingURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhantomTunnel/pairing.plist")
                    var request = Data("direct-auth\0".utf8)
                    request.append(try Data(contentsOf: pairingURL))
                    try session.sendProviderMessage(request) { _ in }
                }
            }
            if let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.me.sophiaxu.phantomcapture"),
               let data = try? Data(contentsOf: root.appendingPathComponent("Documents/Capture/diagnostics/reflector.json")) {
                stats = String(data: data, encoding: .utf8) ?? ""
                if extensionMode, let statusData = try? Data(contentsOf: root.appendingPathComponent("Documents/Capture/diagnostics/extension-capture-status.json")),
                   let status = try? JSONSerialization.jsonObject(with: statusData) as? [String: Any] {
                    extensionStatus = status["message"] as? String ?? "Waiting for extension…"
                }
            }
            log()
            if ProcessInfo.processInfo.environment["PHANTOM_REFLECTOR_STOP"] == "1" { stop(); return }
            if ready && !autoStarted && ProcessInfo.processInfo.environment["PHANTOM_REFLECTOR_AUTOSTART"] == "1" {
                autoStarted = true; if !connected { start() }
            }
            if connected && !probeStarted && ProcessInfo.processInfo.environment["PHANTOM_REFLECTOR_SCREENSHOT"] == "1" {
                probeStarted = true; TunnelCaptureProbe.start()
            }
        } catch { message = error.localizedDescription; log() }
    }
    func start() {
        guard ready, let manager else { return }
        Task {
            do {
                if !manager.isEnabled {
                    manager.isEnabled = true
                    try await manager.saveToPreferences()
                    try await manager.loadFromPreferences()
                }
                try manager.connection.startVPNTunnel()
            } catch { message = error.localizedDescription; log() }
        }
    }
    func stop() {
        TunnelCaptureProbe.stop()
        try? (manager?.connection as? NETunnelProviderSession)?.sendProviderMessage(Data("stop-capture".utf8)) { _ in }
        manager?.connection.stopVPNTunnel()
    }
    private func log() {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.me.sophiaxu.phantomcapture") else { return }
        let url = root.appendingPathComponent("Documents/Capture/diagnostics/reflector-controller.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try? JSONSerialization.data(withJSONObject: ["at": Date().timeIntervalSince1970, "message": message, "ready": ready, "connected": connected, "global": global])
        try? data?.write(to: url, options: .atomic)
    }
}
struct ReflectorDiagnosticView: View {
    @StateObject private var model = ReflectorModel()
    @State private var captureStatus = "Screenshot probe has not started."
    var body: some View {
        NavigationStack {
            List {
                Section(model.global ? "Global reflector test" : "Local per-app reflector") {
                    Text(model.message)
                    Button("Start reflector") { model.start() }.disabled(!model.ready || model.connected)
                    Button("Stop reflector and probe", role: .destructive) { model.stop() }
                    Text(model.global ? "Uses the device-wide VPN slot, replacing Tailscale while connected. Only 10.7.0.1 is routed into this local reflector." : "Only Phantom is mapped to this local tunnel. No remote server is used.").font(.footnote)
                }
                Section("Packet counters") { Text(model.stats).font(.caption.monospaced()) }
                Section("Capture diagnostic") { Text(model.extensionMode ? model.extensionStatus : captureStatus).font(.caption) }
            }.navigationTitle("Phantom Reflector")
            .overlay {
                if ProcessInfo.processInfo.environment["PHANTOM_REFLECTOR_STRESS"] == "1" {
                    CaptureTransportStressView(stop: { model.stop() })
                }
            }
            .task {
                while !Task.isCancelled {
                    await model.refresh()
                    captureStatus = TunnelCaptureProbe.statusText()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }
}

// A reproducible large-image source, only shown by an explicit diagnostic launch.
// Pixels are generated once in RAM; no user image or photo-library access is needed.
private struct CaptureTransportStressView: View {
    var stop: () -> Void
    @State private var started = Date()
    private static let noise: UIImage = {
        let width = 1398, height = 2034
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 0x12345678
        for i in stride(from: 0, to: bytes.count, by: 4) {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            bytes[i] = UInt8(truncatingIfNeeded: seed)
            bytes[i+1] = UInt8(truncatingIfNeeded: seed >> 8)
            bytes[i+2] = UInt8(truncatingIfNeeded: seed >> 16)
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return UIImage(cgImage: image)
    }()
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { tick in
            let elapsed = max(0, Int(tick.date.timeIntervalSince(started)))
            let complex = (elapsed / 20) % 2 == 1
            ZStack {
                Color.gray
                if complex { Image(uiImage: Self.noise).resizable().interpolation(.none) }
                VStack {
                    Text(complex ? "Large-image transport test" : "Small-image transport control")
                    Text("\(elapsed) seconds · changes every 20 seconds")
                    Button("Stop test", role: .destructive, action: stop)
                }.padding().background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
            }.ignoresSafeArea()
        }
    }
}
