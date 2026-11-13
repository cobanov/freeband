#!/bin/sh
# Copies the app's database off an iPhone that runs a development-signed Freeband
# (tools/device-install.sh), to look at what the band really sent.
#
#   sh tools/device-pull.sh <folder> <device name>
#
# The folder gets `default.store` (SQLite, with -wal and -shm) and the newest calibration
# report. It is health data: keep it in out/ (ignored), never in the repo. Tables are
# ZACTIVITYBLOB (the raw files; a small ZDATA starts with a 0x01 marker byte that is not part
# of the file), ZDAYSUMMARY, ZMINUTEDAY, ZSLEEPRECORD, ZMANUALREADING, ZDAILYSCORE, ZSAMPLE.
# A copy from TestFlight or the App Store does not allow this. The iPhone has to be unlocked:
# locked, iOS refuses the files ("Failed to open ... POSIX error code 1").
set -e
[ -n "$1" ] || { echo "usage: device-pull.sh <folder> <device name>" >&2; exit 1; }
LIST=$(mktemp)
xcrun devicectl list devices --json-output "$LIST" >/dev/null 2>&1
DEVICE=$(python3 -I - "$LIST" "$2" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
want = sys.argv[2] if len(sys.argv) > 2 else ""
for d in devices:
    name = d.get("deviceProperties", {}).get("name", "")
    if d.get("hardwareProperties", {}).get("deviceType") != "iPhone": continue
    if d.get("hardwareProperties", {}).get("reality") != "physical": continue
    if name == want: print(d["identifier"]); break
    if not want: print("  " + name, file=sys.stderr)
PY
)
rm -f "$LIST"
[ -n "$DEVICE" ] || { echo "name one of the iPhones above${2:+: no iPhone is called $2}" >&2; exit 1; }
mkdir -p "$1"
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
  --domain-identifier dev.cobanov.freeband --source "Library/Application Support" --destination "$1" >/dev/null
ls "$1"
