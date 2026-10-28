import SwiftUI
import NetworkExtension
import SafariServices
import Network

// One-shot completion protects against late IPC replies after an extension exit.
enum TailnetIPC {
    private final class Reply {
        let lock = NSLock()
        var continuation: CheckedContinuation<Data, Error>?
        init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }
        func finish(_ result: Result<Data, Error>) {
            lock.lock(); let continuation = self.continuation; self.continuation = nil; lock.unlock()
            continuation?.resume(with: result)
        }
    }
    static func send(_ data: Data, session: NETunnelProviderSession, timeout: Double = 30) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let reply = Reply(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                reply.finish(.failure(NSError(domain: "PhantomTailnet", code: 1, userInfo: [NSLocalizedDescriptionKey: "The VPN did not reply. It may have stopped; reconnect and try again."])))
            }
            do {
                try session.sendProviderMessage(data) { data in
                    if let data { reply.finish(.success(data)) }
                    else { reply.finish(.failure(NSError(domain: "PhantomTailnet", code: 2, userInfo: [NSLocalizedDescriptionKey: "The VPN closed the request."]))) }
                }
            } catch { reply.finish(.failure(error)) }
        }
    }
    // Opt-in device validation: a bounded plain TCP exchange with the Mac's
    // test server, without weakening the app's transport-security settings.
    static func testTCP(_ url: URL) async throws -> Data {
        guard let host = url.host, let port = url.port, let networkPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw NSError(domain: "PhantomTest", code: 1)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let reply = Reply(continuation)
            let queue = DispatchQueue(label: "PhantomTailnetTCPTest")
            let connection = NWConnection(host: NWEndpoint.Host(host), port: networkPort, using: .tcp)
            var buffer = Data()
            func finish(_ result: Result<Data, Error>) { reply.finish(result); connection.cancel() }
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
                    if let data { buffer.append(data) }
                    if let error { finish(.failure(error)); return }
                    if buffer.count > 8192 { finish(.failure(NSError(domain: "PhantomTest", code: 2))); return }
                    if complete { finish(.success(buffer)); return }
                    receive()
                }
            }
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    let request = "GET \(url.path) HTTP/1.0\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                        if let error { finish(.failure(error)) } else { receive() }
                    })
                } else if case .failed(let error) = state { finish(.failure(error)) }
            }
            queue.asyncAfter(deadline: .now() + 10) { finish(.failure(NSError(domain: "PhantomTest", code: 3, userInfo: [NSLocalizedDescriptionKey: "TCP test timed out"]))) }
            connection.start(queue: queue)
        }
    }

}

private struct TailnetPeer: Identifiable {
    var id: String; var name: String; var dnsName: String; var ips: [String]; var online: Bool; var exitNode: Bool
    init(_ d: [String: Any]) {
        id = d["id"] as? String ?? ""; name = d["name"] as? String ?? ""; dnsName = d["dnsName"] as? String ?? ""
        ips = d["ips"] as? [String] ?? []; online = d["online"] as? Bool ?? false; exitNode = d["exitNode"] as? Bool ?? false
    }
}
private struct TailnetLogin: Identifiable { let id = UUID(); let url: URL }

@MainActor private final class TailnetModel: ObservableObject {
    @Published var status: [String: Any] = [:]
    @Published var busy = false
    @Published var automaticReconnect = PhoneCaptureVPN.automaticReconnect
    func setAutomaticReconnect(_ enabled: Bool) {
        guard !busy else { return }
        Task {
            busy = true; defer { busy = false }
            do { try await PhoneCaptureVPN.setAutomaticReconnect(enabled); automaticReconnect = enabled; error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
    @Published var error: String?
    @Published var login: TailnetLogin?
    private var awaitingLogin = false
    private var autoConnected = false
    private var tested = false
    func autoConnectIfRequested() {
        if !autoConnected && ProcessInfo.processInfo.environment["PHANTOM_TAILNET_AUTOCONNECT"] == "1" { autoConnected = true; command("connect") }
    }
    private var displayedAuthURL: String?
    var state: String { status["state"] as? String ?? "Disconnected" }
    var peers: [TailnetPeer] { (status["peers"] as? [[String: Any]] ?? []).map(TailnetPeer.init) }
    var ips: [String] { status["ips"] as? [String] ?? [] }
    var enabled: Bool { status["wantRunning"] as? Bool ?? false }
    func flag(_ key: String, fallback: Bool) -> Bool { status[key] as? Bool ?? fallback }
    func text(_ key: String) -> String { status[key] as? String ?? "" }

    func refresh() async { guard !busy else { return }; await perform("status", activate: false) }
    func command(_ command: String, value: Any? = nil) {
        guard !busy else { return }
        if command == "login" { awaitingLogin = true; displayedAuthURL = nil }
        Task { await perform(command, value: value, activate: command == "connect" || command == "login") }
    }
    private func perform(_ command: String, value: Any? = nil, activate: Bool) async {
        busy = true; defer { busy = false }
        do {
            let manager = try await PhoneCaptureVPN.manager()
            if activate && manager.connection.status != .connected {
                if !manager.isEnabled { manager.isEnabled = true; try await manager.saveToPreferences(); try await manager.loadFromPreferences() }
                if manager.connection.status != .connecting { try manager.connection.startVPNTunnel(options: ["tailnet": NSNumber(value: true)]) }
                for _ in 0..<40 {
                    if manager.connection.status == .connected { break }
                    try await Task.sleep(for: .milliseconds(500))
                }
            }
            guard manager.connection.status == .connected, let session = manager.connection as? NETunnelProviderSession else {
                status = ["state": "Disconnected"]
                if activate { throw NSError(domain: "PhantomTailnet", code: 3, userInfo: [NSLocalizedDescriptionKey: "The Phantom VPN did not connect."]) }
                return
            }
            if command == "disconnect" || command == "logout" { try await PhoneCaptureVPN.applyOnDemand(manager, enabledOverride: PhoneCaptureVPN.automaticReconnect && PhoneCaptureVPN.recordingEnabled) }
            var request: [String: Any] = ["command": command]; if let value { request["value"] = value }
            var data = Data("tailnet\0".utf8); data.append(try JSONSerialization.data(withJSONObject: request))
            let reply = try await TailnetIPC.send(data, session: session)
            guard let result = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return }
            if let message = result["error"] as? String { error = message } else { error = nil }
            if result["state"] != nil { status = result }
            if result["error"] == nil && (command == "connect" || command == "login") { try await PhoneCaptureVPN.applyOnDemand(manager) }
            automaticReconnect = PhoneCaptureVPN.automaticReconnect
            if ProcessInfo.processInfo.environment["PHANTOM_TAILNET"] == "1", let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.me.sophiaxu.phantomcapture") {
                var diagnostic = result.filter { ["state", "error", "availableMiB", "version", "wantRunning", "peerCount", "memory"].contains($0.key) }
                diagnostic["at"] = Date().timeIntervalSince1970
                diagnostic["onDemandEnabled"] = manager.isOnDemandEnabled
                diagnostic["onDemandRuleCount"] = manager.onDemandRules?.count ?? 0
                let url = root.appendingPathComponent("Documents/Capture/diagnostics/tailnet-test.json")
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? JSONSerialization.data(withJSONObject: diagnostic).write(to: url, options: .atomic)
            }
            if state == "Running" { awaitingLogin = false; login = nil; displayedAuthURL = nil }
            if state == "Running", (result["peerCount"] as? Int ?? 0) > 0, !tested, let raw = ProcessInfo.processInfo.environment["PHANTOM_TAILNET_TEST_URLS"],
               let rawData = raw.data(using: .utf8), let urls = try? JSONDecoder().decode([String].self, from: rawData) {
                tested = true
                var checks: [[String: Any]] = []
                if let value = ProcessInfo.processInfo.environment["PHANTOM_TAILNET_TEST_CAPTURE_SECONDS"], let seconds = Double(value), seconds > 0 && seconds <= 120 {
                    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhantomTunnel/pairing.plist")
                    let args: [String: Any] = ["pairing": try Data(contentsOf: url), "seconds": seconds, "record": true]
                    var message = Data("extension-capture\0".utf8)
                    message.append(try PropertyListSerialization.data(fromPropertyList: args, format: .binary, options: 0))
                    let reply = try await PhoneCaptureVPN.send(message, session: session)
                    checks.append(["captureStarted": reply == "started"])
                }
                for string in urls.prefix(2) {
                    guard let url = URL(string: string), url.scheme == "http" else { continue }
                    do {
                        let bytes = try await TailnetIPC.testTCP(url)
                        let response = String(data: bytes, encoding: .utf8) ?? ""
                        let success = response.hasPrefix("HTTP/1.0 200") && response.hasSuffix("phantom-tailnet-ok\n")
                        checks.append(["host": url.host ?? "", "ok": success, "bytes": bytes.count])
                    } catch { checks.append(["host": url.host ?? "", "ok": false, "error": error.localizedDescription]) }
                }
                // Exercise reversible preference changes, restoring the originals.
                for (command, field) in [("dns", "dns"), ("subnets", "subnets")] {
                    let original = result[field] as? Bool ?? false
                    for value in [!original, original] {
                        var message = Data("tailnet\0".utf8)
                        message.append(try JSONSerialization.data(withJSONObject: ["command": command, "value": value]))
                        do {
                            let data = try await TailnetIPC.send(message, session: session)
                            let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                            checks.append(["command": command, "value": value, "ok": response[field] as? Bool == value && response["error"] == nil])
                        } catch { checks.append(["command": command, "value": value, "ok": false, "error": error.localizedDescription]) }
                    }
                }
                if let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.me.sophiaxu.phantomcapture") {
                    try JSONSerialization.data(withJSONObject: checks).write(to: root.appendingPathComponent("Documents/Capture/diagnostics/tailnet-checks.json"), options: .atomic)
                }
            }
            if awaitingLogin, let raw = result["authURL"] as? String, !raw.isEmpty, raw != displayedAuthURL,
               let url = URL(string: raw), url.scheme == "https", let host = url.host,
               host == "tailscale.com" || host.hasSuffix(".tailscale.com") {
                displayedAuthURL = raw; login = TailnetLogin(url: url)
            }
            if command == "disconnect" || command == "logout" {
                awaitingLogin = false; login = nil
                // Capture and Tailscale have independent lifetimes.
                let capture = try await PhoneCaptureVPN.send(Data("capture-state".utf8), session: session)
                try await PhoneCaptureVPN.applyOnDemand(manager)
                if capture == "finished" && !PhoneCaptureVPN.recordingEnabled { manager.connection.stopVPNTunnel() }
            }
        } catch { self.error = error.localizedDescription }
    }
}

struct TailnetView: View {
    @StateObject private var model = TailnetModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmLogout = false
    @State private var visible = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "network").foregroundStyle(model.state == "Running" ? .green : .secondary)
                        VStack(alignment: .leading) {
                            Text(model.state).font(.headline)
                            if !model.text("tailnet").isEmpty { Text(model.text("tailnet")).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if model.busy { ProgressView() }
                    }
                    if !model.ips.isEmpty {
                        LabeledContent(model.text("name"), value: model.ips.joined(separator: "\n")).textSelection(.enabled).font(.caption.monospaced())
                    }
                    if model.state == "NeedsLogin" || model.state == "Disconnected" || model.state == "NoState" {
                        Button("Sign in to Tailscale") { model.command("login") }.disabled(model.busy)
                    }
                    Toggle("Reconnect automatically", isOn: Binding(get: { model.automaticReconnect }, set: { model.setAutomaticReconnect($0) })).disabled(model.busy)
                    if model.enabled {
                        Button("Disconnect Tailscale") { model.command("disconnect") }.disabled(model.busy)
                    } else {
                        Button("Connect") { model.command("connect") }.disabled(model.busy)
                    }
                } footer: {
                    Text("Phantom joins as its own device. Tailscale and recording share this VPN; leave the separate Tailscale app disconnected. Automatic reconnection uses iOS VPN On Demand while Tailscale or recording is enabled. Disconnect stops Tailscale; recording can keep the VPN connected.")
                }
                if let error = model.error { Section { Text(error).foregroundStyle(.red) } }
                ForEach(model.status["health"] as? [String] ?? [], id: \.self) { Text($0).font(.footnote).foregroundStyle(.orange) }
                if model.status["dns"] != nil {
                    Section("Routing") {
                        Toggle("Use Tailscale DNS", isOn: Binding(get: { model.flag("dns", fallback: true) }, set: { model.command("dns", value: $0) }))
                        Toggle("Use subnet routes", isOn: Binding(get: { model.flag("subnets", fallback: false) }, set: { model.command("subnets", value: $0) }))
                        Picker("Exit node", selection: Binding(get: { model.text("exitNodeID") }, set: { model.command("exit", value: $0) })) {
                            Text("None").tag("")
                            ForEach(model.peers.filter(\.exitNode)) { peer in Text(peer.name + (peer.online ? "" : " (offline)")).tag(peer.id) }
                        }
                    }.disabled(model.busy)
                    Section("Devices (\(model.status["peerCount"] as? Int ?? model.peers.count))") {
                        ForEach(model.peers) { peer in
                            HStack {
                                Circle().fill(peer.online ? Color.green : Color.secondary).frame(width: 7, height: 7)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(peer.name)
                                    Text(peer.dnsName.isEmpty ? peer.ips.joined(separator: " · ") : peer.dnsName).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                Spacer()
                                if peer.exitNode { Image(systemName: "globe").foregroundStyle(.secondary) }
                            }
                        }
                    }
                    Section {
                        if let free = model.status["availableMiB"] as? Double { LabeledContent("Extension memory headroom", value: String(format: "%.1f MiB", free)) }
                        Text(model.text("version")).font(.caption).foregroundStyle(.secondary)
                        Button("Sign out", role: .destructive) { confirmLogout = true }.disabled(model.busy)
                    } footer: { Text("Powered by AwgScale and Tailscale. Taildrop controls are not included. Memory headroom is shared with recording.") }
                }
            }
            .navigationTitle("Tailscale")
            .refreshable { await model.refresh() }
            .confirmationDialog("Sign out of Tailscale on Phantom?", isPresented: $confirmLogout) {
                Button("Sign out", role: .destructive) { model.command("logout") }
            }
            .sheet(item: $model.login) { login in TailnetBrowser(url: login.url).ignoresSafeArea() }
            .onAppear { visible = true; model.autoConnectIfRequested() }
            .onDisappear { visible = false }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    if visible { await model.refresh() }
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                }
            }
        }
    }
}
private struct TailnetBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
