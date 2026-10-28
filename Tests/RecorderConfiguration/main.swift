import Foundation
func check(_ condition: Bool) { precondition(condition) }
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("phantom-policy-test-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: directory) }
let config = RecorderConfiguration(directory: directory)
check(try config.enabled())
try config.setEnabled(false)
check(try !RecorderConfiguration(directory: directory).enabled())
let fakePairing = try PropertyListSerialization.data(fromPropertyList: ["test": "synthetic-test-only"], format: .binary, options: 0)
try config.savePairing(fakePairing)
check(try config.pairing() == fakePairing)
check(try !config.enabled()) // Credential preparation must not reset Disabled.
let attrs = try FileManager.default.attributesOfItem(atPath: config.pairingURL.path)
precondition((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
try config.setEnabled(true)
check(try RecorderConfiguration(directory: directory).enabled())
try Data("invalid".utf8).write(to: config.preferenceURL)
do { _ = try config.enabled(); fatalError("Corrupt preferences must not silently enable capture") } catch {}
try FileManager.default.removeItem(at: config.preferenceURL)
check(try config.enabled())
print("PASS: default Enabled, durable Disabled/Enabled, pairing preservation and permissions, corrupt preferences fail closed")
