# Working on Freeband

Instructions for coding agents (and people) changing this repository. The README says what Freeband is; this file says how work gets done here.

## Ground rules

- **Write the protocol down first, then the code.** Freeband's code is MIT. Gadgetbridge is AGPL-3.0, so never translate its Java (or any other project's code) into Swift. Read the source, write the facts into the docs with `file:line` citations, then write Swift from the docs. `findings.md` §8 and the README's Credits say why.
- **Mark every fact with its source.** `[CODE]` / `[KOD]`: read in a source. `[MEASURED]` / `[ÖLÇÜM]`: seen on a device. `[UNVERIFIED]` / `[TAHMİN]`: inferred. `findings.md` and most of `docs/` are in Turkish; keep a file's language when you edit it. `docs/BLE-V1.md` is in English.
- **A user's data stays out of the repo.** Raw activity files, logs, screenshots and photos of a band are health data. Use them to check the code, then encode what you learned as synthetic test data built from the measured values.
- **A device's identifiers stay out too.** A Bluetooth address (MAC), the four-digit suffix of a band's Bluetooth name (it is the end of the address), a serial number, an auth key and a CoreBluetooth identifier all point at one person's band.
  - In code, tests, docs and commit messages, write a made-up one: `AA:BB:CC:DD:5E:6F`, `XiaomiWatchS1Active 5E6F`. In notes about a measured device, write `XXXX` for the suffix.
  - A log the user shares has them in it (the band's name, the login bytes). Read it, don't paste it.
  - Model codes and firmware versions (`M2116W1`, `1.4.174`) are the same on every unit and belong in the notes.
- **Code never depends on one band's address or ID.** The app finds a band by what is stored for it (`Band.mac`, `macSuffix`, its keys in the Keychain); nothing in the source names a particular device.
- **Protocol code has no I/O.** `MiProtocol.swift`, `MiProtocolV1.swift` and `ActivityFiles.swift` use Foundation only (no CoreBluetooth, no SwiftUI), take bytes in and return bytes and events, so they build and test on the Mac. `BandLink.swift` does the Bluetooth.

## Supporting a new band, or a new part of the protocol

1. **Probe the device before writing code.** A band connected to the iPhone doesn't advertise, so BLE scanners don't see it; Freeband reaches it through iOS's connection. Ask the user to tap Connect with Mi Fitness closed and send the log (Settings → Diagnostics → Share log). The log lists every characteristic under `FE95` with its properties, which tells V2 (`005E`/`005F`) from V1 (`0051`–`0055`).
2. **Write the notes.** Byte layouts with citations, plus a "to check on the device" list. Example: `docs/BLE-V1.md`.
3. **Write the code from the notes**, keeping protocol code free of I/O (see above).
4. **Test on the Mac** (commands below). Each Swift harness prints what the code produced; a Python script recomputes the expected bytes on its own (`check_vectors.py` with `cryptography`'s AESCCM, `activity_ref.py`). Never copy Swift's output into an expectation. Make a value wrong once and check the test fails.
5. **Build the app** for the simulator.
6. **Have the user try it.** Say exactly what to tap and which log lines or screens to send back. Before a first run on a new device, add log lines that make the result decisive (the V1 path logs every value as hex until the login succeeds).
7. **Fix from real data.** Ask for the raw files (Settings → Diagnostics → Share raw files) and for what the band itself shows. Decode a file with `python3 ios/tests/activity/activity_ref.py parse FILE.bin`, run it through the app's own code in a scratch script, and turn the measured values into a synthetic test.
8. **Record the result** in the docs as `[MEASURED]`, with the device, firmware and date.
9. **Bump `ActivityIngest.parserVersion`** (with a comment line saying why) when a change alters what a stored file yields; stored files are parsed again at the next launch.

## Tests

```sh
# protocol vectors (V2 and V1); needs python3 with `cryptography`. TZ=UTC: notify_cmd's expected time is UTC.
cd ios/tests/protocol && swiftc ../../Freeband/Band/MiProtocol.swift ../../Freeband/Band/MiProtocolV1.swift main.swift -o /tmp/mitest && TZ=UTC /tmp/mitest | python3 check_vectors.py

# activity files: Swift against the fixtures and the Python reference, then the reference alone
cd ios/tests/activity/swift && swiftc ../../../Freeband/Band/ActivityFiles.swift main.swift -o /tmp/act && /tmp/act
cd ios/tests/activity && python3 activity_ref.py --selftest

# ingest (parser to records and sleep metrics), then the store
cd ios/tests/ingest && swiftc ../../Freeband/Band/ActivityFiles.swift ../../Freeband/Analytics/*.swift ../../Freeband/Data/IngestMapper.swift ../../Freeband/Data/Calibration.swift main.swift -o /tmp/ingest && /tmp/ingest
cd ios/tests/ingest/store && F=../../../Freeband && swiftc -D DEBUG stub.swift $F/Band/ActivityFiles.swift $F/Analytics/*.swift $F/Data/*.swift $F/App/DemoData.swift main.swift -o /tmp/store && /tmp/store

# analytics
cd ios/tests/analytics && swiftc ../../Freeband/Analytics/*.swift main.swift -o /tmp/an && /tmp/an

# the app: generate the project, then build for the simulator without signing
cd ios && xcodegen generate && xcodebuild -project Freeband.xcodeproj -scheme Freeband -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

# an unsigned Release .ipa for SideStore/AltStore (restores the string catalogs afterwards)
cd ios && sh tools/build-ipa.sh
```

No iOS simulator runtime installed? Typecheck the whole app with `xcrun --sdk iphonesimulator swiftc -typecheck -target arm64-apple-ios17.0-simulator -swift-version 5 -module-name Freeband $(find ios/Freeband -name "*.swift")`, and render a view to PNG through Mac Catalyst (`swiftc -target arm64-apple-ios17.0-macabi` with the iOSSupport frameworks and `ImageRenderer`) to look at a drawing.

The contract test (`ios/tests/contract`) writes into `hub/test/fixtures`; pass it another folder unless you mean to update those fixtures.

## Committing

- **Work on a branch**, not `main`.
- **One feature per commit.** Each commit carries its code, tests and docs, and builds and passes its tests on its own. When several features were developed together, build each commit's version of the shared files, stage only those paths, and run the checks before committing.
- **Check for device identifiers before committing.** Search what you staged for a Bluetooth address, and for the suffix of the band you worked with:
  ```sh
  git diff --cached | grep -nE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}'   # only made-up addresses (AA:BB:CC:DD:…) may show up
  git diff --cached | grep -n 'XXXX'                                  # XXXX = that band's suffix; nothing may show up
  ```
- **Keep generated and personal files out:**
  - `ios/Freeband.xcodeproj` is generated by XcodeGen and ignored (`ios/.gitignore`).
  - Building in Xcode rewrites `ios/Freeband/Resources/Localizable.xcstrings` and `AppShortcuts.xcstrings` (strings marked stale, translations flipped to `needs_review`). Restore them with `git checkout --` unless the change is a deliberate string edit.
  - `ios/project.yml` carries the maintainer's `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER`. A fork's own signing values stay local and are never committed.
- **Commit messages** follow the existing style: a short subject in plain words, then why the change was made and what was checked.
