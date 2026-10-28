#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
for tool in git curl python3 cargo rustup go; do
    command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
done
xcrun --sdk iphoneos --show-sdk-path >/dev/null
python3 scripts/configure.py
mkdir -p .build/idevice/Headers
IDEVICE_REV=d32c8189c51c2789496b0768039419c3705498c3
if [[ ! -d .build/idevice-source ]]; then
    git clone --branch v0.1.68 --depth 1 https://github.com/jkcoxson/idevice.git .build/idevice-source
fi
[[ "$(git -C .build/idevice-source rev-parse HEAD)" == "$IDEVICE_REV" ]] || {
    echo 'Unexpected idevice revision; move .build/idevice-source aside and retry.' >&2; exit 1;
}
if [[ ! -d .build/jktcp-0.1.7 ]]; then
    curl --fail --location --retry 3 https://static.crates.io/crates/jktcp/jktcp-0.1.7.crate -o .build/jktcp.crate
    echo '4d3b9e59938be47d261173086c65a9352fe048951bc502109e7595b70b60cd98  .build/jktcp.crate' | shasum -a 256 -c -
    tar -xzf .build/jktcp.crate -C .build
fi
apply_patch_once() {
    local directory="$1" patchfile="$2"
    if (cd "$directory" && git apply --check "$patchfile") 2>/dev/null; then
        (cd "$directory" && git apply "$patchfile")
    elif ! (cd "$directory" && git apply --reverse --check "$patchfile") 2>/dev/null; then
        echo "Patch does not match $directory; inspect local changes before retrying." >&2; exit 1
    fi
}
apply_patch_once .build/idevice-source "$ROOT/transport/idevice-0.1.68.patch"
git init -q .build/jktcp-0.1.7
apply_patch_once .build/jktcp-0.1.7 "$ROOT/transport/jktcp-0.1.7.patch"
export IPHONEOS_DEPLOYMENT_TARGET=27.0
rustup target add aarch64-apple-ios
cargo build --manifest-path .build/idevice-source/Cargo.toml --locked \
    -p idevice-ffi --release --target aarch64-apple-ios \
    --no-default-features --features ring,dvt,core_device,tunnel_tcp_stack
cp .build/idevice-source/target/aarch64-apple-ios/release/libidevice_ffi.a .build/idevice/
cp .build/idevice-source/ffi/idevice.h .build/idevice/Headers/
bash TailscaleCore/build_go.sh --device
printf '\nDependencies built. Open PhantomCaptureProbe.xcodeproj and select PhantomMonitor.\n'
