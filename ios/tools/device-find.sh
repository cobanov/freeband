#!/bin/sh
# Prints the CoreDevice identifier of the paired iPhone with the given name, as
# `xcrun devicectl list devices` shows it. Without a name, or with one that matches nothing,
# lists the iPhones on stderr and fails. Used by device-install.sh and device-pull.sh.
LIST=$(mktemp)
xcrun devicectl list devices --json-output "$LIST" >/dev/null 2>&1
DEVICE=$(python3 -I - "$LIST" "$1" <<'PY'
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
[ -n "$DEVICE" ] || { echo "name one of the iPhones above${1:+: no iPhone is called $1}" >&2; exit 1; }
echo "$DEVICE"
