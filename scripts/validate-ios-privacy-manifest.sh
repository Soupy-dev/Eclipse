#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 /path/to/Eclipse.app" >&2
    exit 64
fi

app_path=$1
manifest_path="${app_path}/PrivacyInfo.xcprivacy"

if [[ ! -d "$app_path" ]]; then
    echo "error: iOS app bundle does not exist: $app_path" >&2
    exit 1
fi

if [[ ! -f "$manifest_path" ]]; then
    echo "error: PrivacyInfo.xcprivacy is missing from the iOS app bundle." >&2
    exit 1
fi

plutil -lint "$manifest_path" >/dev/null

python3 - "$manifest_path" <<'PY'
import plistlib
import sys

manifest_path = sys.argv[1]
with open(manifest_path, "rb") as handle:
    manifest = plistlib.load(handle)

if manifest.get("NSPrivacyTracking") is not False:
    raise SystemExit("error: iOS privacy manifest must declare NSPrivacyTracking=false.")

if manifest.get("NSPrivacyCollectedDataTypes") != []:
    raise SystemExit("error: iOS privacy manifest must contain an empty NSPrivacyCollectedDataTypes array.")

required = {
    "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1"},
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"C617.1"},
    "NSPrivacyAccessedAPICategoryDiskSpace": {"85F4.1", "E174.1"},
    "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1"},
}
declared = {
    entry.get("NSPrivacyAccessedAPIType"): set(entry.get("NSPrivacyAccessedAPITypeReasons", []))
    for entry in manifest.get("NSPrivacyAccessedAPITypes", [])
    if isinstance(entry, dict)
}

for category, reasons in required.items():
    missing = reasons - declared.get(category, set())
    if missing:
        raise SystemExit(
            f"error: iOS privacy manifest is missing {category} reason(s) {', '.join(sorted(missing))}."
        )
PY

echo "iOS privacy manifest validation passed"
