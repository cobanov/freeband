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
DEVICE=$(sh "$(dirname "$0")/device-find.sh" "$2")
mkdir -p "$1"
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
  --domain-identifier dev.cobanov.freeband --source "Library/Application Support" --destination "$1" >/dev/null
ls "$1"
