import NetworkExtension

// Local capture reflector and Tailscale share one packet tunnel.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let queue = DispatchQueue(label: "PhantomReflector")
    private var running = false
    private var tailnet: TailnetBackend?
    private var directProbeStarted = false
    private var extensionCapture: PhantomExtensionCapture?
    private var recordingTimer: DispatchSourceTimer?
    private var stoppingCapture = false
    private var nextCaptureAttempt = Date.distantPast
    private var reflected: UInt64 = 0
    private var dropped: UInt64 = 0
    private var headers: [[String: Any]] = []
    private var writeAccepted = false
    private var lastWrite = Date.distantPast
    private var policySnapshot: [String: Any] = [:]
    private var policyIdentity: Data?
    private var lastPolicyWrite = Date.distantPast
    private var state = "stopped"
    private var statusURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.me.sophiaxu.phantomcapture")?
            .appendingPathComponent("Documents/Capture/diagnostics/reflector.json")
    }
    private func reflectorSnapshot() -> [String: Any] {
        return ["at": Date().timeIntervalSince1970, "state": state,
                                 "reflected": reflected, "dropped": dropped, "headers": headers, "writeAccepted": writeAccepted,
                                 "routingMethod": routingMethod.rawValue]
    }
    private func report(_ message: String? = nil) {
        if let message { state = message }
        guard let url = statusURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: reflectorSnapshot()) { try? data.write(to: url, options: .atomic) }
        lastWrite = Date()
    }
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let config = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        let global = routingMethod == .destinationIP && config?["PhantomGlobalTest"] as? Bool == true
        let perApp = routingMethod == .sourceApplication && !(appRules ?? []).isEmpty
        guard global || perApp else {
            completionHandler(NSError(domain: "PhantomReflector", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected per-app routing or an explicitly configured global diagnostic."]))
            return
        }
        reflected = 0; dropped = 0; headers = []; writeAccepted = false; directProbeStarted = false
        let settings: NEPacketTunnelNetworkSettings
        do { settings = try TailnetRoutes.settings(nil) }
        catch { completionHandler(error); return }
        setTunnelNetworkSettings(settings) { error in
            self.queue.async {
                if let error { self.report("settings failed: \(error.localizedDescription)"); completionHandler(error); return }
                self.running = true
                self.report("running")
                completionHandler(nil)
                self.readNext()
                if TailnetBackend.defaults.bool(forKey: "tailnetEnabled") || options?["tailnet"] as? Bool == true {
                    self.startTailnet()
                }
                if let pairing = options?["pairing"] as? Data {
                    try? RecorderConfiguration.shared().savePairing(pairing)
                }
                self.startRecordingSupervisor()
            }
        }
    }
    private func readNext() {
        guard running else { return }
        packetFlow.readPackets { packets, protocols in
            self.queue.async {
                guard self.running else { return }
                var output: [Data] = []
                for (index, packet) in packets.enumerated() {
                    // Restrict reflection to our synthetic peer. Never reflect other traffic.
                    guard protocols[index].int32Value == AF_INET, packet.count >= 20,
                          packet[0] >> 4 == 4, packet[0] & 15 >= 5,
                          packet.count >= Int(packet[0] & 15) * 4,
                          Array(packet[12..<16]) == [10,7,0,0],
                          Array(packet[16..<20]) == [10,7,0,1] else {
                        if self.tailnet?.inject(packet) != true { self.dropped += 1 }
                        continue
                    }
                    let offset = Int(packet[0] & 15) * 4
                    if packet[9] == 6 && packet.count >= offset + 20 {
                        self.headers.append(["at": Date().timeIntervalSince1970, "sourcePort": Int(packet[offset])*256+Int(packet[offset+1]), "destinationPort": Int(packet[offset+2])*256+Int(packet[offset+3]), "flags": Int(packet[offset+13]), "length": packet.count])
                        if self.headers.count > 12 { self.headers.removeFirst() }
                    }
                    var reflectedPacket = packet
                    reflectedPacket.replaceSubrange(12..<16, with: packet[16..<20])
                    reflectedPacket.replaceSubrange(16..<20, with: packet[12..<16])
                    // Swapping source/destination preserves IPv4 and TCP/UDP checksum sums.
                    output.append(reflectedPacket)
                    self.reflected += 1
                }
                if !output.isEmpty { self.writeAccepted = self.packetFlow.writePackets(output, withProtocols: output.map { _ in NSNumber(value: AF_INET) }) }
                if Date().timeIntervalSince(self.lastWrite) > 60 { self.report() }
                self.readNext()
            }
        }
    }
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.async {
            self.running = false
            self.recordingTimer?.cancel(); self.recordingTimer = nil
            self.extensionCapture?.stop()
            self.tailnet?.stop()
            self.report("stopped: \(reason.rawValue)")
            completionHandler()
        }
    }
    @discardableResult private func startCapture(pairing: Data, seconds: Double, record: Bool) -> Bool {
        guard running, routingMethod == .destinationIP, extensionCapture == nil || extensionCapture?.finished == true else { return false }
        let capture = PhantomExtensionCapture()
        capture.recordVideo = record
        extensionCapture = capture
        capture.start(withPairing: pairing, seconds: seconds)
        return true
    }
    private func recordingPolicyStatus(_ state: String, enabled: Bool?, error: String? = nil) {
        guard let url = statusURL?.deletingLastPathComponent().appendingPathComponent("recording-policy.json") else { return }
        var row: [String: Any] = ["at": Date().timeIntervalSince1970, "state": state, "pid": ProcessInfo.processInfo.processIdentifier]
        if let enabled { row["enabled"] = enabled }
        if let error { row["error"] = error }
        policySnapshot = row
        var identity = row; identity.removeValue(forKey: "at")
        let encoded = try? JSONSerialization.data(withJSONObject: identity, options: .sortedKeys)
        guard encoded != policyIdentity || Date().timeIntervalSince(lastPolicyWrite) >= 60 else { return }
        if let data = try? JSONSerialization.data(withJSONObject: row) { try? data.write(to: url, options: .atomic) }
        policyIdentity = encoded; lastPolicyWrite = Date()
    }
    private func startRecordingSupervisor() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(3), leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.reconcileRecording() }
        recordingTimer = timer; timer.resume()
    }
    private func reconcileRecording() {
        guard running, routingMethod == .destinationIP else { return }
        do {
            let configuration = try RecorderConfiguration.shared()
            let enabled = try configuration.enabled()
            if !enabled {
                if extensionCapture?.finished == false && !stoppingCapture {
                    stoppingCapture = true; extensionCapture?.stop()
                }
                recordingPolicyStatus(extensionCapture?.finished == false ? "finishing" : "disabled", enabled: false)
                return
            }
            if extensionCapture?.finished == false {
                recordingPolicyStatus(stoppingCapture ? "waiting-for-finalization" : "running", enabled: true)
                return
            }
            guard Date() >= nextCaptureAttempt else { return }
            nextCaptureAttempt = Date().addingTimeInterval(10)
            let pairing: Data
            do { pairing = try configuration.pairing() }
            catch {
                recordingPolicyStatus("waiting-for-pairing", enabled: true, error: "Open Phantom once to prepare recording, or unlock after restarting the phone.")
                return
            }
            if startCapture(pairing: pairing, seconds: 0, record: true) {
                stoppingCapture = false
                recordingPolicyStatus("starting", enabled: true)
            }
        } catch {
            // If the persisted preference cannot be read, fail closed until it
            // becomes readable again. In particular, do not override Disabled.
            if extensionCapture?.finished == false && !stoppingCapture { stoppingCapture = true; extensionCapture?.stop() }
            recordingPolicyStatus("waiting-for-preferences", enabled: nil, error: error.localizedDescription)
        }
    }
    private func startTailnet() {
        guard tailnet == nil else { return }
        let backend = TailnetBackend(provider: self)
        tailnet = backend
        backend.start()
    }
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        if messageData == Data("recording-snapshot".utf8) {
            queue.async {
                var snapshot: [String: Any] = ["policy": self.policySnapshot, "at": Date().timeIntervalSince1970,
                                               "captureFinished": self.extensionCapture?.finished != false]
                if let status = self.extensionCapture?.liveStatus { snapshot["status"] = status }
                completionHandler?(try? JSONSerialization.data(withJSONObject: snapshot))
            }
            return
        }
        if messageData == Data("recording-preference-changed".utf8) {
            queue.async {
                self.nextCaptureAttempt = .distantPast
                self.reconcileRecording()
                completionHandler?(Data("applied".utf8))
            }
            return
        }
        let tailnetPrefix = Data("tailnet\0".utf8)
        if messageData.starts(with: tailnetPrefix) {
            let request = Data(messageData.dropFirst(tailnetPrefix.count))
            queue.async {
                let object = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any]
                let command = object?["command"] as? String
                if command == "connect" || command == "login" { self.startTailnet() }
                guard let backend = self.tailnet else {
                    completionHandler?(Data("{\"state\":\"Disconnected\"}".utf8)); return
                }
                backend.handle(request) { completionHandler?($0) }
            }
            return
        }
        let capturePrefix = Data("extension-capture\0".utf8)
        if messageData.starts(with: capturePrefix) {
            queue.async {
                guard let args = try? PropertyListSerialization.propertyList(from: Data(messageData.dropFirst(capturePrefix.count)), format: nil) as? [String: Any],
                      let pairing = args["pairing"] as? Data else { completionHandler?(Data("rejected".utf8)); return }
                let started = self.startCapture(pairing: pairing, seconds: args["seconds"] as? Double ?? 180, record: args["record"] as? Bool ?? false)
                completionHandler?(Data((started ? "started" : "busy").utf8))
            }
            return
        }
        if messageData == Data("stop-capture".utf8) {
            queue.async {
                do { try RecorderConfiguration.shared().setEnabled(false); self.reconcileRecording(); completionHandler?(Data("stopping".utf8)) }
                catch { completionHandler?(Data("preference-save-failed".utf8)) }
            }
            return
        }
        if messageData == Data("capture-state".utf8) { queue.async { completionHandler?(Data((self.extensionCapture?.finished != false ? "finished" : "running").utf8)) }; return }
        let prefix = Data("direct-auth\0".utf8)
        if messageData.starts(with: prefix) {
            queue.async {
                guard !self.directProbeStarted else { completionHandler?(nil); return }
                self.directProbeStarted = true
                let credential = Data(messageData.dropFirst(prefix.count))
                DispatchQueue.global(qos: .utility).async {
                    let result = PhantomProbeDirectTunnel(credential)
                    let data = result.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                    if let url = self.statusURL?.deletingLastPathComponent().appendingPathComponent("reflector-direct-auth.json"), let data { try? data.write(to: url, options: .atomic) }
                    completionHandler?(data)
                }
            }
            return
        }
        queue.async { completionHandler?(try? JSONSerialization.data(withJSONObject: self.reflectorSnapshot())) }
    }
}
