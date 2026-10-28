import SwiftUI
import Charts
import AVKit
import NetworkExtension

struct ProbeEvent: Codable { let at: Double; let message: String }
struct ProbeStatus: Codable {
    let schema: Int
    let session, state: String
    let heartbeat, startedAt, elapsed, limitSeconds: Double
    let frames: Int
    let bytes: Int64
    let lastFrameAt: Double
    let lastFile: String
    let discarded, buffered, locks, unlocks: Int
    let displays: [String: Int]
    let events: [ProbeEvent]
    let error, thermal: String
    let codec: String?
    let width, height: Int?
    let desired: Bool?
    let maxFPS, recentFPS, resolveMS, captureMS, resizeMS, encodeMS: Double?
    let requested: Int?
    let command: String?
}
struct HistoryPoint: Codable, Identifiable {
    var id: String { "\(session)-\(at)" }
    let at: Double
    let session, state: String
    let frames: Int
    let bytes: Int64
    let fps, cpu, memoryMiB, battery: Double
    let thermal: Int
    var date: Date { Date(timeIntervalSince1970: at) }
}
struct SessionRecord: Codable, Identifiable {
    let id: String
    let startedAt, updatedAt: Double
    let state: String
    let frames: Int
    let bytes: Int64
    let codec: String
    let width, height: Int
    let error: String
}
struct ClipMetadata: Codable {
    let file: String
    let start, end: Double
    let frames: Int
    let bytes: Int64
    let width, height: Int
    let display: Int
}
struct Clip: Identifiable {
    var id: String { url.path }
    let url: URL
    let session: String
    let metadata: ClipMetadata?
    let bytes: Int64
    var partial: Bool { metadata == nil }
    var start: Date { Date(timeIntervalSince1970: metadata?.start ?? 0) }
}
struct LibrarySnapshot {
    var sessions: [SessionRecord] = []
    var clips: [Clip] = []
    var history: [HistoryPoint] = []
    var totalBytes: Int64 = 0
    var freeBytes: Int64 = 0
}

@MainActor final class MonitorModel: ObservableObject {
    @Published var status: ProbeStatus?
    @Published var library = LibrarySnapshot()
    @Published var now = Date()
    @Published var message = ""
    @Published var starting = false
    @Published var recordingEnabled = true
    @Published var recordingPolicyMessage = ""
    private var recordingChangeID = UUID()
    @Published var historyHours = 24
    private var lastLibrary = Date.distantPast
    private var loading = false
    private var refreshing = false
    var consumedAutostart = false
    private var validatedStatus = false
    let root: URL? = {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.me.sophiaxu.phantomcapture") else { return nil }
        let documents = container.appendingPathComponent("Documents")
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let root = documents.appendingPathComponent("Capture"), legacy = container.appendingPathComponent("Capture")
        if !FileManager.default.fileExists(atPath: root.path), FileManager.default.fileExists(atPath: legacy.path) { try? FileManager.default.moveItem(at: legacy, to: root) }
        return root
    }()
    var live: Bool { guard let s = status else { return false }; return now.timeIntervalSince1970 - s.heartbeat < 12 }
    var recording: Bool { live && status?.desired == true }
    // A stale checkpoint can still refer to an active writer. Never treat IPC
    // timeout alone as permission to delete its unfinished file or directory.
    func protectsSession(_ id: String) -> Bool { status?.session == id && (status?.desired == true || live) }
    var title: String {
        guard recordingEnabled else { return recording ? "Disabling recording…" : "Recording disabled" }
        guard live, let s = status else { return starting ? "Starting recorder…" : "Recording enabled · waiting for VPN" }
        switch s.state {
        case "frontboard-probe": return "Display diagnostics · recording off"
        case "capturing": return "Recording"
        case "locked": return "Paused while locked"
        case "settling": return "Resuming after unlock"
        case "waiting-for-display": return "Waiting for active display"
        case "error": return "Recording stopped with an error"
        case "stopped": return "Ready to record"
        default: return "Starting recorder"
        }
    }
    @discardableResult func command(_ action: String) -> String? {
        guard let root else { message = "Shared storage is unavailable. Reinstall both apps with the shared-storage profile."; return nil }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let id = UUID().uuidString
            let value: [String: Any] = ["id": id, "at": Date().timeIntervalSince1970, "action": action]
            try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent("command.json"), options: .atomic)
            return id
        } catch { message = error.localizedDescription; return nil }
    }
    func prepareRecording() async {
        do {
            try PhoneCaptureVPN.prepareRecording()
            recordingEnabled = try RecorderConfiguration.shared().enabled()
            try await PhoneCaptureVPN.reconcileRecording(startIfNeeded: recordingEnabled)
        } catch { message = error.localizedDescription }
    }
    func setRecordingEnabled(_ enabled: Bool) {
        let change = UUID(); recordingChangeID = change
        do {
            try RecorderConfiguration.shared().setEnabled(enabled)
            recordingEnabled = enabled
        } catch { message = error.localizedDescription; return }
        starting = enabled; message = enabled ? "Recording enabled. Starting when the VPN is ready…" : "Recording disabled. Finalizing the current clip when unlocked…"
        Task {
            do {
                try await PhoneCaptureVPN.reconcileRecording(startIfNeeded: enabled)
                if recordingChangeID == change { message = "" }
            } catch { if recordingChangeID == change { message = "Preference saved. " + error.localizedDescription } }
            if recordingChangeID == change { starting = false }
            await refresh(force: true)
        }
    }
    func start() { setRecordingEnabled(true) }
    func stop() { setRecordingEnabled(false) }
    func refresh(force: Bool = false) async {
        guard !refreshing else { return }; refreshing = true; defer { refreshing = false }
        now = Date()
        if let enabled = try? RecorderConfiguration.shared().enabled() { recordingEnabled = enabled }
        guard let root else { message = "Shared storage is unavailable."; return }
        let snapshot = try? await PhoneCaptureVPN.liveSnapshot()
        var policy = snapshot?["policy"] as? [String: Any]
        var current: ProbeStatus?
        var recentHistory: [HistoryPoint] = []
        if let live = snapshot?["status"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: live) {
            current = try? JSONDecoder().decode(ProbeStatus.self, from: data)
            if let rows = live["recentHistory"], let historyData = try? JSONSerialization.data(withJSONObject: rows) {
                recentHistory = (try? JSONDecoder().decode([HistoryPoint].self, from: historyData)) ?? []
            }
        }
        if current == nil, let data = try? Data(contentsOf: root.appendingPathComponent("status.json")) {
            current = try? JSONDecoder().decode(ProbeStatus.self, from: data)
        }
        if let current, current.heartbeat >= (status?.heartbeat ?? 0) { status = current }
        if policy == nil, let data = try? Data(contentsOf: root.appendingPathComponent("diagnostics/recording-policy.json")) {
            policy = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        recordingPolicyMessage = now.timeIntervalSince1970 - (policy?["at"] as? Double ?? 0) < 75 ? (policy?["error"] as? String ?? "") : ""
        if !loading && (force || now.timeIntervalSince(lastLibrary) > 10) {
            loading = true
            let hours = historyHours
            library = await Task.detached(priority: .utility) { Self.scan(root: root, hours: hours) }.value
            lastLibrary = Date(); loading = false
        }
        // Merge the newest RAM samples with the durable history, without duplicates.
        let known = Set(library.history.map(\.id))
        library.history += recentHistory.filter { !known.contains($0.id) }
        library.history.sort { $0.at < $1.at }
    }
    // Opt-in bounded device check: one report at the end, no per-poll disk logging.
    func validateStatusPersistence() async {
        guard !validatedStatus, let text = ProcessInfo.processInfo.environment["PHANTOM_STATUS_CHECK_SECONDS"],
              let seconds = Double(text), seconds > 0, seconds <= 120, let root else { return }
        validatedStatus = true
        var samples: [[String: Any]] = []
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !Task.isCancelled {
            var row: [String: Any] = ["at": Date().timeIntervalSince1970, "uiFrames": status?.frames ?? -1]
            do {
                if let envelope = try await PhoneCaptureVPN.liveSnapshot(), let live = envelope["status"] as? [String: Any] {
                    row["live"] = live.filter { ["session", "state", "heartbeat", "frames", "statusCheckpointWrites", "metadataAppendFlushes"].contains($0.key) }
                    row["policy"] = envelope["policy"]
                    if let data = try? JSONSerialization.data(withJSONObject: live) { row["decodes"] = (try? JSONDecoder().decode(ProbeStatus.self, from: data)) != nil }
                }
                if let data = try? Data(contentsOf: root.appendingPathComponent("status.json")), let disk = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    row["disk"] = disk.filter { ["session", "state", "heartbeat", "frames", "statusCheckpointWrites"].contains($0.key) }
                }
            } catch { row["error"] = error.localizedDescription }
            samples.append(row)
            try? await Task.sleep(for: .seconds(2))
        }
        if let data = try? JSONSerialization.data(withJSONObject: samples) {
            try? data.write(to: root.appendingPathComponent("diagnostics/status-persistence-test.json"), options: .atomic)
        }
    }
    nonisolated static func scan(root: URL, hours: Int) -> LibrarySnapshot {
        var result = LibrarySnapshot()
        let decoder = JSONDecoder(), fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root.appendingPathComponent("sessions"), includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            if let data = try? Data(contentsOf: folder.appendingPathComponent("session.json")), let session = try? decoder.decode(SessionRecord.self, from: data) { result.sessions.append(session) }
            var known = Set<String>()
            if let text = try? String(contentsOf: folder.appendingPathComponent("segments.jsonl"), encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    guard let clip = try? decoder.decode(ClipMetadata.self, from: Data(line.utf8)), !clip.file.contains("/"), !clip.file.contains("..") else { continue }
                    let url = folder.appendingPathComponent(clip.file)
                    guard fm.fileExists(atPath: url.path) else { continue }
                    known.insert(clip.file)
                    result.clips.append(Clip(url: url, session: folder.lastPathComponent, metadata: clip, bytes: clip.bytes)); result.totalBytes += clip.bytes
                }
            }
            for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where !known.contains(url.lastPathComponent) && (url.pathExtension == "mp4" || url.pathExtension == "partial") {
                let bytes = ((try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
                result.clips.append(Clip(url: url, session: folder.lastPathComponent, metadata: nil, bytes: bytes)); result.totalBytes += bytes
            }
        }
        result.sessions.sort { $0.startedAt > $1.startedAt }; result.clips.sort { $0.start > $1.start }
        let cutoff = Date().addingTimeInterval(-Double(hours)*3600).timeIntervalSince1970
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let oldestFile = formatter.string(from: Date(timeIntervalSince1970: cutoff)) + ".jsonl"
        let historyFiles = ((try? fm.contentsOfDirectory(at: root.appendingPathComponent("history"), includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent >= oldestFile && $0.pathExtension == "jsonl" }
        for url in historyFiles {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            result.history += text.split(separator: "\n").compactMap { try? decoder.decode(HistoryPoint.self, from: Data($0.utf8)) }.filter { $0.at >= cutoff }
        }
        result.history.sort { $0.at < $1.at }
        if result.history.count > 1200 { let step = Int(ceil(Double(result.history.count)/1200)); result.history = stride(from: 0, to: result.history.count, by: step).map { result.history[$0] } }
        result.freeBytes = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        return result
    }
    func delete(_ clip: Clip) async {
        guard !(protectsSession(clip.session) && clip.partial), let root, clip.url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { message = "The active clip cannot be deleted."; return }
        do { try FileManager.default.removeItem(at: clip.url); await refresh(force: true) } catch { message = error.localizedDescription }
    }
    func deleteSession(_ session: SessionRecord) async {
        guard !(protectsSession(session.id)), let root, UUID(uuidString: session.id) != nil else { message = "Start a new session before deleting the worker’s current session."; return }
        do { try FileManager.default.removeItem(at: root.appendingPathComponent("sessions").appendingPathComponent(session.id)); await refresh(force: true) } catch { message = error.localizedDescription }
    }
}

func sizeText(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
func elapsedText(_ value: Double) -> String { let s = max(0, Int(value)); return s >= 3600 ? "\(s/3600)h \((s%3600)/60)m" : "\(s/60)m \(s%60)s" }

@main struct PhantomMonitorApp: App {
    @StateObject private var model = MonitorModel()
    @State private var selectedTab = ProcessInfo.processInfo.environment["PHANTOM_TAILNET"] == "1" ? 3 : 0
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.environment["PHANTOM_REFLECTOR"] == "1" {
                ReflectorDiagnosticView()
            } else if ProcessInfo.processInfo.environment["PHANTOM_TUNNEL_CAPTURE"] == "1" {
                TunnelCaptureDiagnosticView()
            } else if ProcessInfo.processInfo.environment["PHANTOM_TUNNEL_ROUTES"] == "1" {
                TunnelDiagnosticView()
            } else if ProcessInfo.processInfo.environment["PHANTOM_SCREEN_ONLY_PROBE"] == "1" {
                ScreenOnlyDiagnosticView()
            } else {
            TabView(selection: $selectedTab) {
                Dashboard(model: model).tabItem { Label("Recorder", systemImage: "record.circle") }.tag(0)
                HistoryView(model: model).tabItem { Label("History", systemImage: "chart.xyaxis.line") }.tag(1)
                LibraryView(model: model).tabItem { Label("Recordings", systemImage: "film.stack") }.tag(2)
                TailnetView().tabItem { Label("Tailscale", systemImage: "network") }.tag(3)
            }
            .tint(.indigo)
            .task { await model.validateStatusPersistence() }
            .onOpenURL { url in if url.host == "start" { model.start() } }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await model.prepareRecording()
                await model.refresh(force: true)
                if !model.consumedAutostart && ProcessInfo.processInfo.environment["PHANTOM_AUTOSTART"] == "1" { model.consumedAutostart = true; model.start() }
                while !Task.isCancelled { await model.refresh(); try? await Task.sleep(for: .seconds(2)) }
            }
            }
        }
    }
}
struct Dashboard: View {
    @ObservedObject var model: MonitorModel
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: model.recording ? "record.circle.fill" : "record.circle").font(.largeTitle).foregroundStyle(model.recording ? .red : .secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.title).font(.title3.bold())
                            Text(model.live ? "On this iPhone · no session timeout" : "Saved recordings and history remain available").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 10)
                    Toggle("Recording enabled", isOn: Binding(get: { model.recordingEnabled }, set: { model.setRecordingEnabled($0) }))
                    Text("Starts automatically whenever the VPN runs. Disabling stays in effect across app, VPN, and phone restarts.").font(.caption).foregroundStyle(.secondary)
                    if !model.recordingPolicyMessage.isEmpty { Text(model.recordingPolicyMessage).font(.caption).foregroundStyle(.orange) }
                    if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(.secondary) }
                }
                if let s = model.status {
                    Section(model.live ? "Current session" : "Last received session") {
                        LabeledContent("Elapsed", value: elapsedText(s.elapsed))
                        LabeledContent("Saved video frames", value: s.frames.formatted())
                        LabeledContent("Recent saved FPS", value: String(format: "%.2f / %.0f maximum", s.recentFPS ?? 0, s.maxFPS ?? 1))
                        LabeledContent("Screenshot requests", value: (s.requested ?? s.frames).formatted())
                        Text("Elapsed includes pauses. Saved frames exclude the 3-second safety buffer and frames discarded at lock or display changes.").font(.caption).foregroundStyle(.secondary)
                        if let resolve = s.resolveMS, let capture = s.captureMS {
                            LabeledContent("Display lookup / screenshot", value: String(format: "%.0f / %.0f ms", resolve, capture))
                            LabeledContent("Resize / encode", value: String(format: "%.0f / %.0f ms", s.resizeMS ?? 0, s.encodeMS ?? 0))
                        }
                        LabeledContent("Session video size", value: sizeText(s.bytes))
                        LabeledContent("Last captured frame", value: s.lastFrameAt > 0 ? "\(max(0,Int(model.now.timeIntervalSince1970-s.lastFrameAt)))s ago" : "None yet")
                        LabeledContent("Output", value: "\(s.width ?? 0) × \(s.height ?? 0) · HEVC")
                        LabeledContent("Thermal state", value: s.thermal)
                        LabeledContent("Lock / unlock events", value: "\(s.locks) / \(s.unlocks)")
                        LabeledContent("Pending / discarded frames", value: "\(s.buffered) / \(s.discarded)")
                    }
                    if !s.error.isEmpty { Section("Last issue") { Text(s.error).font(.caption).textSelection(.enabled) } }
                    Section("Recent events") {
                        ForEach(Array(s.events.reversed().enumerated()), id: \.offset) { _, event in
                            VStack(alignment: .leading) { Text(event.message).font(.caption); Text(Date(timeIntervalSince1970: event.at), style: .time).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
                Section("Recording settings") {
                    Label("Active display only", systemImage: "iphone")
                    Label("Half width and height · hardware HEVC", systemImage: "film")
                    Label("Up to 1 frame per second", systemImage: "speedometer")
                    Label("One-minute clips · no automatic deletion", systemImage: "folder")
                    Text("One screenshot is processed at a time. Capture and video admission pause while locked, then wait 3 seconds after unlock. Actual frame rate depends on screenshot latency.").font(.footnote).foregroundStyle(.secondary)
                    Text("Capture runs in the local VPN extension and needs Developer Mode and the developer disk image. Use the Tailscale tab to share this VPN with capture.").font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("Phantom").refreshable { await model.refresh(force: true) }
        }
    }
}
struct HistoryView: View {
    @ObservedObject var model: MonitorModel
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Period", selection: $model.historyHours) { Text("1 hour").tag(1); Text("24 hours").tag(24); Text("7 days").tag(168) }.pickerStyle(.segmented)
                        .onChange(of: model.historyHours) { _, _ in Task { await model.refresh(force: true) } }
                    if model.library.history.isEmpty { ContentUnavailableView("No history yet", systemImage: "chart.xyaxis.line", description: Text("The recorder saves a measurement every 10 seconds, including while capture is paused.")) }
                }
                if !model.library.history.isEmpty {
                    Section("Capture rate") {
                        Chart(model.library.history) { p in LineMark(x: .value("Time", p.date), y: .value("FPS", p.fps), series: .value("Session", p.session)).foregroundStyle(.indigo) }.chartYScale(domain: 0...max(1.1, (model.library.history.map(\.fps).max() ?? 1) * 1.05)).frame(height: 170)
                        Text("Admitted frames per second. The current limit is 1 fps; older sessions may be higher. Lock guards and screenshot latency can reduce the actual rate.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Worker CPU") {
                        Chart(model.library.history) { p in LineMark(x: .value("Time", p.date), y: .value("% of one core", p.cpu), series: .value("Session", p.session)).foregroundStyle(.teal) }.frame(height: 150)
                        Text("Percent of one core; excludes system capture services.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Memory footprint") {
                        Chart(model.library.history.filter { $0.memoryMiB >= 0 }) { p in LineMark(x: .value("Time", p.date), y: .value("MiB", p.memoryMiB), series: .value("Session", p.session)).foregroundStyle(.blue) }.frame(height: 150)
                    }
                    Section("Battery") {
                        Chart(model.library.history.filter { $0.battery >= 0 }) { p in LineMark(x: .value("Time", p.date), y: .value("Battery %", p.battery*100), series: .value("Session", p.session)).foregroundStyle(.orange) }.chartYScale(domain: 0...100).frame(height: 150)
                        Text("iOS percentage readings are coarse. This is not a wattage measurement.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Thermal state") {
                        Chart(model.library.history) { p in PointMark(x: .value("Time", p.date), y: .value("Level", p.thermal)).foregroundStyle(p.thermal >= 2 ? .red : .green) }.chartYScale(domain: 0...3).frame(height: 100)
                        Text("0 Nominal · 1 Fair · 2 Serious · 3 Critical").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.navigationTitle("History")
        }
    }
}
struct LibraryView: View {
    @ObservedObject var model: MonitorModel
    @State private var deleteSession: SessionRecord?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Video storage", value: sizeText(model.library.totalBytes))
                    LabeledContent("Available on phone", value: sizeText(model.library.freeBytes))
                    Text("Clips stay on this phone. Export or delete them below; nothing is automatically removed.").font(.caption).foregroundStyle(.secondary)
                }
                if model.library.sessions.isEmpty { ContentUnavailableView("No recordings yet", systemImage: "film.stack", description: Text("Start recording to create your first session.")) }
                ForEach(model.library.sessions) { session in
                    Section(Date(timeIntervalSince1970: session.startedAt).formatted(date: .abbreviated, time: .shortened)) {
                        let clips = model.library.clips.filter { $0.session == session.id }
                        HStack { Text("\(clips.filter { !$0.partial }.count) clips").font(.subheadline); Spacer(); Text(sizeText(clips.reduce(0) { $0+$1.bytes })).foregroundStyle(.secondary) }
                        ForEach(clips) { clip in
                            NavigationLink { ClipView(clip: clip, model: model) } label: {
                                HStack {
                                    Image(systemName: clip.partial ? "hourglass" : "play.rectangle").foregroundStyle(.indigo)
                                    VStack(alignment: .leading) {
                                        Text(clip.partial ? (model.protectsSession(clip.session) ? "Current clip · not finalized" : "Interrupted clip") : clip.start.formatted(date: .omitted, time: .standard))
                                        Text(clip.metadata.map { "\(elapsedText($0.end-$0.start)) · \($0.width) × \($0.height) · \(sizeText(clip.bytes))" } ?? "\(sizeText(clip.bytes)) · may not be playable").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if !(model.protectsSession(session.id)) { Button("Delete session", role: .destructive) { deleteSession = session } }
                    }
                }
            }.navigationTitle("Recordings").refreshable { await model.refresh(force: true) }
                .confirmationDialog("Delete this session and all its video files?", isPresented: Binding(get: { deleteSession != nil }, set: { if !$0 { deleteSession = nil } }), titleVisibility: .visible) {
                    Button("Delete session", role: .destructive) { if let session = deleteSession { Task { await model.deleteSession(session) } }; deleteSession = nil }
                }
        }
    }
}
struct ClipView: View {
    let clip: Clip
    @ObservedObject var model: MonitorModel
    @State private var player: AVPlayer?
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 20) {
            if clip.partial { ContentUnavailableView("Unfinished clip", systemImage: "hourglass", description: Text("The current clip becomes playable when it closes. An interrupted clip can be exported for recovery.")) }
            else { VideoPlayer(player: player).frame(minHeight: 220).onAppear { player = AVPlayer(url: clip.url) }.onDisappear { player?.pause(); player = nil } }
            if let meta = clip.metadata {
                Text("\(meta.width) × \(meta.height) · HEVC · \(meta.frames) frames").font(.subheadline)
                Text("\(Date(timeIntervalSince1970: meta.start).formatted()) – \(Date(timeIntervalSince1970: meta.end).formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
            }
            ShareLink(item: clip.url) { Label("Export video", systemImage: "square.and.arrow.up") }.disabled(clip.partial && model.protectsSession(clip.session))
            Button("Delete clip", role: .destructive) { confirmDelete = true }.disabled(clip.partial && model.protectsSession(clip.session))
            Spacer()
        }.padding().navigationTitle("Video clip").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Permanently delete this clip?", isPresented: $confirmDelete, titleVisibility: .visible) { Button("Delete clip", role: .destructive) { player?.pause(); Task { await model.delete(clip); dismiss() } } }
    }
}


struct ScreenOnlyDiagnosticView: View {
    @State private var status = "Starting screenshot-only probe…"
    var body: some View {
        VStack(spacing: 24) {
            Text("Screenshot-only diagnostic").font(.title2.bold())
            Text(status).monospacedDigit()
            Text("No UI automation session is requested. This probe counts inner-display frames in memory for up to two minutes. Keep the phone unfolded for this first check.").font(.callout).foregroundStyle(.secondary)
            Button("Stop probe") { ScreenOnlyProbe.stop() }.buttonStyle(.bordered)
        }.padding(32).task {
            ScreenOnlyProbe.start()
            while !Task.isCancelled {
                status = ScreenOnlyProbe.statusText()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

struct TunnelDiagnosticView: View {
    @State private var status = "Preparing local route check…"
    var body: some View {
        VStack(spacing: 24) {
            Text("Developer connection diagnostic").font(.title2.bold())
            Text(status)
            Text("Checking this phone’s own network addresses. No screenshots, VPN changes, or UI automation.").font(.callout).foregroundStyle(.secondary)
        }.padding(32).task {
            TunnelProbe.start()
            while !Task.isCancelled {
                status = TunnelProbe.statusText()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

struct TunnelCaptureDiagnosticView: View {
    @State private var status = "Preparing on-phone tunnel…"
    var body: some View {
        VStack(spacing: 24) {
            Text("On-phone capture diagnostic").font(.title2.bold())
            Text(status).monospacedDigit()
            Text("No XCTest worker or VPN changes. Locked-screen frames are skipped. This diagnostic retains only frame counts, hashes and timing.").font(.callout).foregroundStyle(.secondary)
            Button("Stop probe") { TunnelCaptureProbe.stop() }.buttonStyle(.bordered)
        }.padding(32).task {
            TunnelCaptureProbe.start()
            while !Task.isCancelled {
                status = TunnelCaptureProbe.statusText()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}


@MainActor enum PhoneCaptureVPN {
    private static var preparedRecording = false
    private static var statusManager: NETunnelProviderManager?
    static func liveSnapshot() async throws -> [String: Any]? {
        if statusManager == nil || statusManager?.connection.status != .connected {
            statusManager = try await NETunnelProviderManager.loadAllFromPreferences().first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == "me.sophiaxu.phantommonitor.reflector" && $0.routingMethod == .destinationIP
            }
        }
        guard let manager = statusManager, manager.connection.status == .connected,
              let session = manager.connection as? NETunnelProviderSession else { return nil }
        do {
            let data = try await TailnetIPC.send(Data("recording-snapshot".utf8), session: session, timeout: 2)
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch { statusManager = nil; throw error }
    }
    static var recordingEnabled: Bool { (try? RecorderConfiguration.shared().enabled()) ?? false }
    static func prepareRecording() throws {
        guard !preparedRecording else { return }
        try RecorderConfiguration.shared().prepareFromHost()
        preparedRecording = true
    }
    private static let preferences = UserDefaults(suiteName: "group.me.sophiaxu.phantomcapture")!
    static var automaticReconnect: Bool {
        preferences.object(forKey: "tailnetOnDemand") as? Bool ?? true
    }
    static func setAutomaticReconnect(_ enabled: Bool) async throws {
        let previous = automaticReconnect
        preferences.set(enabled, forKey: "tailnetOnDemand")
        do { _ = try await manager() }
        catch { preferences.set(previous, forKey: "tailnetOnDemand"); throw error }
    }
    static func applyOnDemand(_ manager: NETunnelProviderManager, enabledOverride: Bool? = nil) async throws {
        let enabled = enabledOverride ?? (automaticReconnect && (preferences.bool(forKey: "tailnetEnabled") || recordingEnabled))
        let correctRule = manager.onDemandRules?.count == 1 && manager.onDemandRules?.first is NEOnDemandRuleConnect
        guard manager.isOnDemandEnabled != enabled || (enabled && !correctRule) || manager.localizedDescription != "Phantom Capture + Tailscale" else { return }
        let rule = NEOnDemandRuleConnect()
        rule.interfaceTypeMatch = .any
        manager.onDemandRules = [rule]
        manager.isOnDemandEnabled = enabled
        manager.localizedDescription = "Phantom Capture + Tailscale"
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
    }
    static func manager() async throws -> NETunnelProviderManager {
        try prepareRecording()
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        if let existing = managers.first(where: { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == "me.sophiaxu.phantommonitor.reflector" && $0.routingMethod == .destinationIP }) {
            try await applyOnDemand(existing)
            return existing
        }
        let manager = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "me.sophiaxu.phantommonitor.reflector"
        proto.serverAddress = "10.7.0.1"
        proto.providerConfiguration = ["PhantomGlobalTest": true]
        proto.includeAllNetworks = false
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Phantom Capture + Tailscale"
        manager.isEnabled = true; manager.isOnDemandEnabled = false
        try await manager.saveToPreferences();try await manager.loadFromPreferences()
        try await applyOnDemand(manager)
        return manager
    }
    static func send(_ data: Data, session: NETunnelProviderSession) async throws -> String {
        let reply = try await TailnetIPC.send(data, session: session)
        return String(data: reply, encoding: .utf8) ?? "no reply"
    }

    static func reconcileRecording(startIfNeeded: Bool) async throws {
        let manager = try await manager()
        if manager.connection.status == .connected, let session = manager.connection as? NETunnelProviderSession {
            let reply = try await send(Data("recording-preference-changed".utf8), session: session)
            guard reply == "applied" else { throw NSError(domain: "PhantomRecorder", code: 4, userInfo: [NSLocalizedDescriptionKey: "The VPN has not applied the recording preference yet; it will retry automatically."]) }
        } else if startIfNeeded && recordingEnabled {
            if !manager.isEnabled { manager.isEnabled = true; try await manager.saveToPreferences(); try await manager.loadFromPreferences() }
            if manager.connection.status != .connecting && manager.connection.status != .reasserting { try manager.connection.startVPNTunnel() }
        }
    }
    static func start() async throws {
        try prepareRecording()
        try RecorderConfiguration.shared().setEnabled(true)
        try await reconcileRecording(startIfNeeded: true)
    }
    static func stop() async throws {
        try RecorderConfiguration.shared().setEnabled(false)
        try await reconcileRecording(startIfNeeded: false)
    }
}
