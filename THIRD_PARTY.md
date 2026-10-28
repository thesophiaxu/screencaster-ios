# Third-party components

- **idevice** — https://github.com/jkcoxson/idevice, version `v0.1.68`, commit `d32c8189c51c2789496b0768039419c3705498c3`. Downloaded by bootstrap and modified by `transport/idevice-0.1.68.patch` for capture and transport handling. MIT; notice in `licenses/idevice-MIT.txt`.
- **jktcp** — https://crates.io/crates/jktcp/0.1.7, crate SHA-256 `4d3b9e59938be47d261173086c65a9352fe048951bc502109e7595b70b60cd98`. Modified by `transport/jktcp-0.1.7.patch`. MIT; notice in `licenses/jktcp-MIT.txt`.
- **AwgScale Go bridge** — https://github.com/LiuTangLei/AwgScale, commit `801e291638a1cc038ced2fd34320fa4d1201fc4c`. Vendored in `TailscaleCore/` with local memory/queue tuning and build changes. Preserve `TailscaleCore/LICENSE`, `PATENTS`, and `UPSTREAM`.
- The Go bridge depends on the Tailscale/WireGuard forks and other modules pinned in `TailscaleCore/go.mod` and `go.sum`; Rust dependencies are pinned by the upstream patched Cargo.lock. Their respective licenses continue to apply. Bootstrap downloads dependency sources rather than committing compiled binaries.

This private source distribution does not assign a new open-source license to the original app code. Preserve applicable third-party notices when redistributing builds.
