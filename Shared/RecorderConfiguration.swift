import Foundation

// One atomic file is authoritative across processes. UserDefaults caches must
// not turn a saved Disabled preference back on after an extension restart.
struct RecorderConfiguration {
    struct Preference: Codable { var enabled: Bool }
    let directory: URL
    static func shared() throws -> RecorderConfiguration {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.me.sophiaxu.phantomcapture") else {
            throw NSError(domain: "PhantomRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Shared recorder storage is unavailable."])
        }
        return RecorderConfiguration(directory: root.appendingPathComponent("Library/Application Support/Recorder", isDirectory: true))
    }
    var preferenceURL: URL { directory.appendingPathComponent("recording.json") }
    var pairingURL: URL { directory.appendingPathComponent("pairing.plist") }
    func enabled() throws -> Bool {
        do { return try JSONDecoder().decode(Preference.self, from: Data(contentsOf: preferenceURL)).enabled }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return true }
        // Unreadable/corrupt preferences must never be treated as Enabled.
    }
    private func prepareDirectory() throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
        try FileManager.default.setAttributes(attributes, ofItemAtPath: directory.path)
        var url = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    private func write(_ data: Data, to url: URL) throws {
        try prepareDirectory()
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: url, options: options)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func setEnabled(_ enabled: Bool) throws { try write(JSONEncoder().encode(Preference(enabled: enabled)), to: preferenceURL) }
    func pairing() throws -> Data {
        let data = try Data(contentsOf: pairingURL)
        guard !data.isEmpty else { throw NSError(domain: "PhantomRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Recorder pairing is unavailable. Open Phantom once to prepare automatic recording."]) }
        return data
    }
    func savePairing(_ data: Data) throws {
        guard !data.isEmpty, data.count < 1_048_576,
              (try PropertyListSerialization.propertyList(from: data, format: nil)) is [String: Any] else {
            throw NSError(domain: "PhantomRecorder", code: 3, userInfo: [NSLocalizedDescriptionKey: "Recorder pairing data is invalid."])
        }
        if (try? Data(contentsOf: pairingURL)) != data { try write(data, to: pairingURL) }
    }
    // Called by the host once per launch, before configuring VPN On Demand.
    func prepareFromHost() throws {
        let source = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhantomTunnel/pairing.plist")
        if FileManager.default.fileExists(atPath: source.path) { try savePairing(Data(contentsOf: source)) }
        if !FileManager.default.fileExists(atPath: preferenceURL.path) { try setEnabled(true) }
    }
}
