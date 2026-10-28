"""Prepare a separately copied XCTest runner for a direct-launch experiment.

Usage: python3 prepare_runner.py BUILT_RUNNER_APP OUTPUT_RUNNER_APP
The original build is preserved. The output must not already exist.
"""
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

source, output = map(Path, sys.argv[1:3])
signing_host = Path(sys.argv[3]) if len(sys.argv)>3 else None
if output.exists():
    raise SystemExit(f"Output already exists: {output}")
signature = subprocess.run(
    ["codesign", "-dvv", str(source)], capture_output=True, text=True, check=True
).stderr
identity = re.search(r"^Authority=(.+)$", signature, re.MULTILINE)
if not identity:
    raise SystemExit("Cannot identify the existing development signer")
shutil.copytree(source, output)

runner_plist = output / "Info.plist"
info = plistlib.loads(runner_plist.read_bytes())
info.update(CFBundleDisplayName="Phantom Probe", UIFileSharingEnabled=True,
            LSSupportsOpeningDocumentsInPlace=True,
            CFBundleURLTypes=[{"CFBundleURLSchemes":["phantom-worker"]}],
            LSApplicationQueriesSchemes=["phantom-monitor"])
runner_plist.write_bytes(plistlib.dumps(info))
plugins = list((output / "PlugIns").glob("*.xctest"))
if len(plugins) != 1:
    raise SystemExit("Expected exactly one test bundle")
plugin = plugins[0]
plugin_plist = plugin / "Info.plist"
bundle = plistlib.loads(plugin_plist.read_bytes())
bundle["CFBundleIdentifier"] = info["CFBundleIdentifier"]
plugin_plist.write_bytes(plistlib.dumps(bundle))
subprocess.run(["codesign", "--force", "--sign", identity[1], str(plugin)], check=True)
if signing_host:
    host_entitlements = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(signing_host)], capture_output=True, check=True).stdout
    host_info = plistlib.loads(host_entitlements)
    if host_info.get("application-identifier", "").split(".",1)[-1] != info["CFBundleIdentifier"]:
        raise SystemExit("Signing host bundle ID does not match runner")
    shutil.copy2(signing_host / "embedded.mobileprovision", output / "embedded.mobileprovision")
    entitlement_path = output.parent / "runner.entitlements"
    entitlement_path.write_bytes(host_entitlements)
    subprocess.run(["codesign", "--force", "--sign", identity[1], "--entitlements", str(entitlement_path), str(output)], check=True)
else:
    subprocess.run(["codesign", "--force", "--sign", identity[1], "--preserve-metadata=entitlements", str(output)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(output)], check=True)
print(f"Prepared {output}; bundle ID {info['CFBundleIdentifier']}")
