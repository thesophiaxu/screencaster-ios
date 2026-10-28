#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests
python3 scripts/configure.py
xcrun clang -fobjc-arc -fblocks -DPHANTOM_EXTENSION=1 \
    -framework Foundation -framework CoreVideo \
    Tests/StatusCheckpoint/main.m Reflector/ExtensionRecordingStore.m \
    -o .build/tests/status-checkpoint
.build/tests/status-checkpoint
xcrun swiftc Shared/RecorderConfiguration.swift Tests/RecorderConfiguration/main.swift -o .build/tests/recorder-policy
.build/tests/recorder-policy
xcrun swiftc Reflector/TailnetRoutes.swift Tests/TailnetRoutes/main.swift -o .build/tests/tailnet-routes
.build/tests/tailnet-routes
python3 Tests/test_monitor_protocol.py
