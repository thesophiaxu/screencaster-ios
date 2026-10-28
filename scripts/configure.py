#!/usr/bin/env python3
"""Generate a local diagnostic token; optionally customize all signing identifiers."""
import argparse
from pathlib import Path
import re
import secrets

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bundle-prefix', help='Replace me.sophiaxu throughout signing identifiers, e.g. com.example')
args = parser.parse_args()
if args.bundle_prefix:
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z][A-Za-z0-9-]*)+', args.bundle_prefix):
        parser.error('bundle prefix must be a reverse-DNS identifier')
    for directory in ['Companion', 'Probe', 'Reflector', 'Shared', 'Signing', 'PhantomCaptureProbe.xcodeproj']:
        for path in (root / directory).rglob('*'):
            if path.is_file() and path.suffix in {'.swift', '.m', '.h', '.plist', '.entitlements', '.pbxproj'}:
                text = path.read_text()
                updated = text.replace('me.sophiaxu', args.bundle_prefix)
                if text != updated:
                    path.write_text(updated)
header = root / 'Shared/MonitorToken.h'
swift = root / 'Companion/MonitorConfig.swift'
if header.exists():
    match = re.search(r'PHANTOM_MONITOR_TOKEN\s+@"([a-f0-9]+)"', header.read_text())
    if not match:
        raise SystemExit('Existing diagnostic token is unrecognized; leave it intact and inspect locally.')
    token = match[1]
else:
    token = secrets.token_hex(32)
header.write_text('#pragma once\n#define PHANTOM_MONITOR_TOKEN @"' + token + '"\n')
swift.write_text('enum MonitorConfig { static let token = "' + token + '" }\n')
header.chmod(0o600)
swift.chmod(0o600)
print('Local configuration ready (diagnostic token files are gitignored).')
