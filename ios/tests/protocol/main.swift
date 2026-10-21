// Prints MiProtocol outputs for fixed inputs; check_vectors.py recomputes them independently.
// Build: swiftc ../../Freeband/Band/MiProtocol.swift main.swift -o /tmp/mitest
import Foundation

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

let key = Data(0..<16)
let phone = Data(16..<32)
let watch = Data(32..<48)
let ccmNonce = Data(48..<60)
let short = Data("hello".utf8)
let long = Data("BandProbe companion device test vector!".utf8)
let ctrIn = Data((0..<40).map { UInt8($0 * 7 & 0xFF) })

let okm = MiCrypto.sessionKeyMaterial(authKey: key, phoneNonce: phone, watchNonce: watch)
let o = [UInt8](okm)
let watchHmac = MiCrypto.hmacSHA256(key: Data(o[0..<16]), watch + phone)
let confirm = MiAuth.confirmCommand(authKey: key, phoneNonce: phone, watchNonce: watch, watchHmac: watchHmac, deviceName: "BandProbe")!
let wrong = MiAuth.confirmCommand(authKey: Data(count: 16), phoneNonce: phone, watchNonce: watch, watchHmac: watchHmac, deviceName: "BandProbe")

var buf = [UInt8](Data([0x00, 0xA5]) + MiFrame.encode(kind: 3, seq: 7, payload: Data([1, 2, 0xAA])) + MiFrame.encode(kind: 1, seq: 9, payload: Data()) + Data([0xA5, 0xA5, 3]))
let drained = MiFrame.drain(&buf)

var battery = PBWriter(); battery.varint(1, 87)
var power = PBWriter(); power.message(1, battery)
var system = PBWriter(); system.message(2, power)
var resp = PBWriter(); resp.varint(1, 2); resp.varint(2, 1); resp.message(4, system)

var rts = PBWriter(); rts.varint(1, 8421); rts.varint(2, 312); rts.varint(3, 5); rts.varint(4, 74); rts.varint(6, 9)
var health = PBWriter(); health.message(39, rts)
var liveCmd = PBWriter(); liveCmd.varint(1, 8); liveCmd.varint(2, 47); liveCmd.message(10, health)
let live = MiAuth.liveStats(PBMessage(liveCmd.data)!)!

let out: [String: Any] = [
    "crc_123456789": String(format: "%04x", MiFrame.crc16arc(Data("123456789".utf8))),
    "okm": hex(okm),
    "ccm_short": hex(MiCrypto.ccmEncrypt(key: key, nonce: ccmNonce, plaintext: short)),
    "ccm_long": hex(MiCrypto.ccmEncrypt(key: key, nonce: ccmNonce, plaintext: long)),
    "ctr": hex(MiCrypto.ctr(key: key, ctrIn)),
    "nonce_cmd": hex(MiAuth.nonceCommand(phoneNonce: phone)),
    "confirm_cmd": hex(confirm.command),
    "wrong_key_rejected": wrong == nil,
    "session_frame": hex(MiFrame.encode(kind: 2, seq: 0, payload: MiFrame.startSessionPayload)),
    "drained": drained.map { "\($0.kind):\($0.seq):\(hex($0.payload))" },
    "leftover": hex(Data(buf)),
    "battery_parsed": MiAuth.batteryLevel(PBMessage(resp.data)!) ?? 0,
    "battery_cmd": hex(MiAuth.batteryCommand()),
    "realtime_start": hex(MiAuth.realtimeCommand(start: true)),
    "realtime_stop": hex(MiAuth.realtimeCommand(start: false)),
    "notify_cmd": hex(MiAuth.notificationCommand(id: 42, appName: "Freeband", title: "Başlık", body: "Merhaba", date: Date(timeIntervalSince1970: 1_760_000_000))),
    "find_start": hex(MiAuth.findBandCommand(start: true)),
    "find_stop": hex(MiAuth.findBandCommand(start: false)),
    "activity_today": hex(MiAuth.activityListCommand(today: true)),
    "activity_past": hex(MiAuth.activityListCommand(today: false)),
    "activity_fetch": hex(MiAuth.activityFetchCommand(Data([0x00, 0xF1, 0x53, 0x65, 0x04, 0x00, 0x01]))),
    "clock_istanbul": hex(MiAuth.clockCommand(now: Date(timeIntervalSince1970: 1_760_000_000), timeZone: TimeZone(identifier: "Europe/Istanbul")!, is24Hour: true)),
    "clock_newyork_12h": hex(MiAuth.clockCommand(now: Date(timeIntervalSince1970: 1_760_000_000), timeZone: TimeZone(identifier: "America/New_York")!, is24Hour: false)),
    "live_parsed": "\(live.steps)/\(live.calories)/\(live.heartRate)/\(live.standingHours)",
    "resend_seqs": [(10, 10), (10, 7), (3, 250), (40, 8), (40, 7), (10, 11)].map { MiFrame.resendSeqs(next: $0.0, nack: $0.1) },
]
print(String(data: try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .prettyPrinted]), encoding: .utf8)!)
