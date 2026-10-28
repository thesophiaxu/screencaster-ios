# screencaster-ios

> [!NOTE]
> **Entirely vibe-coded**
>
> This app is entirely vibe-coded. Currently it's very buggy, so you should use it at your discretion. I'll fix bugs as I encounter them.
>
> Below is the AI-generated README.

An experimental, on-device iPhone screen recorder for personal and internal use, using on-device developer tools for always-on and imperceptible recording. A Packet Tunnel VPN extension captures only the active display while unlocked, at up to **1 fps**, downsamples to half width and height, and saves local hardware-encoded HEVC clips. optional Tailscale routing and browser sign-in run in the same extension. at a mostly acceptible cost to battery life.

## Prerequisites

- A physical iPhone running **iOS 27+**. Device testing so far used an iPhone Duo on iOS 27.1; other models and OS versions are unverified.
- A Mac with **Xcode 27**, its iOS SDK, Git, Python 3, Rust/Cargo with the `aarch64-apple-ios` target, and Go. The build script selects **Go 1.27.3** and pinned gomobile dependencies; Rust 1.97.1 was used for validation.
- Apple signing/provisioning that permits **App Groups** and a **Packet Tunnel Network Extension**, with matching identifiers in the app and extension. This is a development/internal prototype using private developer-service APIs, not an App Store-ready or turnkey enterprise deployment.
- **Developer Mode**, a trusted device/Mac pairing, a mounted Developer Disk Image, and a device-specific **RemotePairing** record provisioned as described below. A normal lockdown pairing record is not interchangeable with RemotePairing.
- Approval of the app's VPN configuration on the phone. Disconnect any separate global VPN (including the standalone Tailscale app); use this app's integrated Tailscale connection if needed. A Tailscale account is optional for recording.

Before capturing, the extension calls `requestDisableMemoryLimitsForPid:` for its own process through the developer service. On the tested device, the observed memory allowance rose from about 50 MiB to 3.3 GiB. Capture waits/retries if this preflight fails. This is an observed private API behavior, not a portable entitlement or a guarantee against memory pressure. Reboot recovery also depends on first unlock and developer services becoming available; unattended all-day/reboot reliability has not been established.

## Build and install

```sh
# Adjust to your installed Xcode location.
export DEVELOPER_DIR="$HOME/Downloads/Xcode.app/Contents/Developer"
./scripts/bootstrap.sh
./scripts/test.sh
open PhantomCaptureProbe.xcodeproj
```

Bootstrap downloads pinned `idevice` and `jktcp` sources, applies the checked-in transport patches, builds the iOS static library, and builds the vendored Tailscale bridge. Downloads require network access. Generated dependencies live in `.build/` and `TailscaleCore/Libtailscale.xcframework/`; neither is committed. It also generates a local token for the retained legacy diagnostic monitor; token files are ignored by Git.

For your own signing identifiers, run `python3 scripts/configure.py --bundle-prefix com.yourname` on a fresh checkout. This replaces the original `me.sophiaxu` prefix consistently across bundle identifiers, App Groups and runtime lookups. Select your development team for **PhantomMonitor** and **PhantomReflector**, register/enable their capabilities, select the **PhantomMonitor** scheme, then build/install on the phone. The legacy XCTest and signing targets are not required for the current VPN recorder.

An unsigned compile check, without installing or starting capture:

```sh
xcodebuild -project PhantomCaptureProbe.xcodeproj -scheme PhantomMonitor \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

### Provision developer pairing

Connect the trusted, unlocked phone to the Mac and let Xcode prepare developer support. Obtain a valid RemotePairing plist for this device. The pinned `idevice` source includes a USB pairing command; for example:

```sh
cargo build --manifest-path .build/idevice-source/Cargo.toml --locked \
  -p idevice-tools --bin idevice-tools --release --no-default-features --features ring
mkdir -p private
chmod 700 private
umask 077
.build/idevice-source/target/release/idevice-tools --udid YOUR_DEVICE_UDID \
  rppairing pair screencaster-ios private/pairing.plist
```

Approve any Trust prompt on the phone. Transfer the resulting record to the installed host app (substitute your bundle identifier if customized):

```sh
xcrun devicectl device copy to --device YOUR_DEVICE_UDID \
  --domain-type appDataContainer --domain-identifier me.sophiaxu.phantommonitor \
  --source private/pairing.plist \
  --destination 'Library/Application Support/PhantomTunnel/pairing.plist'
```

Launch the app after provisioning. It copies the record into its protected shared container, prepares the default Enabled preference, and can start recording when the VPN connects. Accept the VPN configuration prompt. The **Recording enabled** switch persists across extension restarts; disabling recording leaves Tailscale available. Use the Tailscale tab for optional browser sign-in and device management. Pairing records and Tailscale credentials are device/account secrets and are not included in this repository.

## Battery life impact

Expect a meaningful battery cost. Logs from one Duo on October 25, 2026 showed the following **whole-phone** drain during ordinary use, with the screen on almost continuously:

| Capture state | Duration | Battery change | Approximate drain |
| --- | ---: | ---: | ---: |
| Recording | 25.0 min | 92% → 82% | 24.0 percentage points/hour |
| Recording disabled | 31.1 min | 82% → 75% | 13.5 percentage points/hour |
| Recording | 27.1 min | 75% → 68% | 15.5 percentage points/hour |

The recording windows were roughly **2–10 percentage points/hour higher** than the adjacent disabled window, but these were not controlled A/B runs: app content, brightness, networking and workload were not held constant. They cannot establish recorder-only consumption or predict a full day's runtime. An earlier recording window measured about 8.9 points/hour, starting at 100%, where the battery indicator plateau makes extrapolation especially weak. The first recording row excludes an 18-minute developer-connection retry period with no captured frames.

These measurements precede the October 26 status-write optimization: live status now stays in memory, routine disk checkpoints occur once per minute, and diagnostics/history are buffered. Those changes reduce frequent writes, but their battery benefit has **not been measured**. Full-resolution screenshots still arrive from the system before decoding/subsampling, and the worker's CPU metric excludes system capture services. This is not yet a demonstrated 24/7 battery solution.

## Storage and limitations

Clips, manifests and history remain in the app group's `Documents/Capture` directory until managed in the app; there is no automatic retention limit. Capture pauses on lock and waits briefly after unlock, and clips rotate across display/size changes and reconnects. Protected content, developer-service interruptions, or process termination can leave gaps or an unfinished clip. Up to a minute of buffered status/history may be lost on an abrupt exit; finalized clips and their manifests are persisted separately. No audio is recorded. Integrated Tailscale supplies network connectivity; it does not automatically upload recordings.

`Companion/` contains the UI, `Reflector/` the VPN/capture worker, `Probe/VideoRecorder.m` the video writer, `Shared/` recording policy, and `transport/` the developer-service patches. Legacy probes and benchmark scripts are retained for development, without personal recordings, device logs, or credentials. See [THIRD_PARTY.md](THIRD_PARTY.md) for dependency provenance and licenses.
