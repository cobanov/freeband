// Prints MiProtocol outputs for fixed inputs; check_vectors.py recomputes them independently.
// Build: swiftc ../../Freeband/Band/MiProtocol.swift ../../Freeband/Band/MiProtocolV1.swift main.swift -o /tmp/mitest
// Run with TZ=UTC: check_vectors.py formats notify_cmd's timestamp in UTC.
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

var rts = PBWriter(); rts.varint(1, 8421); rts.varint(2, 312); rts.varint(3, 5); rts.varint(4, 74); rts.varint(5, 49); rts.varint(6, 9)
var health = PBWriter(); health.message(39, rts)
var liveCmd = PBWriter(); liveCmd.varint(1, 8); liveCmd.varint(2, 47); liveCmd.message(10, health)
let live = MiAuth.liveStats(PBMessage(liveCmd.data)!)!

// BLE V1 (docs/BLE-V1.md): CCM decryption, the V1 nonce, and MiV1Channel scenarios. Each scenario
// step prints the writes, then the events: "w:<hex>", "msg:<hex>", "ack:<bool>", "bad:<n>", "?".
func d(_ s: String) -> Data {
    Data(stride(from: 0, to: s.count, by: 2).map { UInt8(s.dropFirst($0).prefix(2), radix: 16)! })
}
func fmt(_ o: MiV1Channel.Output) -> [String] {
    o.writes.map { "w:" + hex($0) } + o.events.map { (event) -> String in
        switch event {
        case .message(let data): return "msg:" + hex(data)
        case .acknowledged(let ok): return "ack:\(ok)"
        case .undecryptable(let n): return "bad:\(n)"
        case .unexpected: return "?"
        }
    }
}
let v1Keys = confirm.keys
let v1Cipher = MiV1Cipher(keys: v1Keys)
/// What the watch sends: its key and nonce, counter 0.
func fromWatch(_ p: Data) -> Data {
    MiCrypto.ccmEncrypt(key: v1Keys.decryptionKey, nonce: MiV1Cipher.nonce(v1Keys.decryptionNonce, counter: 0), plaintext: p)
}
let longCipher = MiCrypto.ccmEncrypt(key: key, nonce: ccmNonce, plaintext: long)
var tampered = longCipher
tampered[tampered.count - 1] ^= 1
let nonceCmd = MiAuth.nonceCommand(phoneNonce: phone)
let batteryCmd = MiAuth.batteryCommand()
let big = Data(0..<40)
let plain30 = Data(0x80..<0x9E)
let inPlain = Data("watch says hi".utf8)
let inBig = Data((0..<41).map { UInt8(255 - $0) })

// plain single writes, the second waiting for the first one's acknowledgement
var chA = MiV1Channel()
let plainQueue = [fmt(chA.send(nonceCmd)), fmt(chA.send(batteryCmd)), fmt(chA.receive(d("00000300")))]

// encrypted single writes count from 1
var chB = MiV1Channel()
chB.cipher = v1Cipher
chB.authenticated()
let encSingle = [fmt(chB.send(batteryCmd)), fmt(chB.receive(d("00000300"))), fmt(chB.send(batteryCmd))]

// encrypted chunked: start, ready, slices, resend of slice 2, done
var chC = MiV1Channel(maxWrite: 20)
chC.cipher = v1Cipher
chC.authenticated()
let encChunked = [fmt(chC.send(big)), fmt(chC.receive(d("00000101"))), fmt(chC.receive(d("000001050200"))),
                  fmt(chC.receive(d("00000100")))]

// plain chunked, refused
var chD = MiV1Channel(maxWrite: 20)
let plainChunked = [fmt(chD.send(plain30)), fmt(chD.receive(d("00000101"))), fmt(chD.receive(d("00000102")))]

// incoming single writes: plain, encrypted, a bad tag
var chE = MiV1Channel()
chE.cipher = v1Cipher
let inEncFrame = d("00000201") + fromWatch(inPlain)
let inSingle = [fmt(chE.receive(d("00000202") + inPlain)), fmt(chE.receive(inEncFrame)),
                fmt(chE.receive(d("00000201") + Data(repeating: 0x5A, count: 8)))]

// incoming chunked, encrypted: slice 2 first, missing 1 and 3 requested, then the rest
var chF = MiV1Channel(maxWrite: 20)
chF.cipher = v1Cipher
let inCT = [UInt8](fromWatch(inBig))
let inSlices = [d("0100") + Data(inCT[0..<18]), d("0200") + Data(inCT[18..<36]), d("0300") + Data(inCT[36...])]
var inChunked = [fmt(chF.receive(d("000000010300"))), fmt(chF.receive(inSlices[1]))]
inChunked.append(["receiving:\(chF.isReceiving)"])
inChunked.append(fmt(chF.requestMissing()))
inChunked.append(fmt(chF.receive(inSlices[0])))
inChunked.append(fmt(chF.receive(inSlices[2])))
inChunked.append(["receiving:\(chF.isReceiving)"])
inChunked.append(fmt(chF.requestMissing()))

// out of place: an acknowledgement and a ready with nothing in flight, a slice with no start, a short value
var chG = MiV1Channel()
let unexpected = [fmt(chG.receive(d("00000300"))), fmt(chG.receive(d("00000101"))), fmt(chG.receive(d("0500aa"))),
                  fmt(chG.receive(d("0000")))]

// authentication drops the plain message in flight; the next goes out encrypted with counter 1
var chH = MiV1Channel()
chH.cipher = v1Cipher
var authReset = [fmt(chH.send(nonceCmd))]
chH.authenticated()
authReset.append(fmt(chH.send(batteryCmd)))

// Find Phone (docs/STAY-CONNECTED.md section 1): start, stop, a missing value, no system field, another subtype
func findPhone(_ build: (inout PBWriter) -> Void, subtype: UInt64 = 17) -> String {
    var command = PBWriter(); command.varint(1, 2); command.varint(2, subtype); build(&command)
    return MiAuth.findPhoneRequest(PBMessage(command.data)!).map { "\($0)" } ?? "nil"
}
let findPhoneParsed = [
    findPhone { var s = PBWriter(); s.varint(5, 0); $0.message(4, s) },
    findPhone { var s = PBWriter(); s.varint(5, 1); $0.message(4, s) },
    findPhone { $0.message(4, PBWriter()) },
    findPhone { _ in },
    findPhone({ var s = PBWriter(); s.varint(5, 0); $0.message(4, s) }, subtype: 18),
]

let v1: [String: Any] = [
    "ccm_decrypt": hex(MiCrypto.ccmDecrypt(key: key, nonce: ccmNonce, ciphertextAndTag: longCipher) ?? Data()),
    "ccm_decrypt_empty": MiCrypto.ccmDecrypt(key: key, nonce: ccmNonce,
                                             ciphertextAndTag: MiCrypto.ccmEncrypt(key: key, nonce: ccmNonce, plaintext: Data())).map(hex) ?? "nil",
    "ccm_decrypt_rejects": [MiCrypto.ccmDecrypt(key: key, nonce: ccmNonce, ciphertextAndTag: tampered) == nil,
                            MiCrypto.ccmDecrypt(key: key, nonce: ccmNonce, ciphertextAndTag: Data([1, 2, 3])) == nil],
    "v1_nonce": hex(MiV1Cipher.nonce(Data([1, 2, 3, 4]), counter: 0x0A0B_0C0D)),
    "v1_plain_queue": plainQueue,
    "v1_enc_single": encSingle,
    "v1_enc_chunked": encChunked,
    "v1_plain_chunked": plainChunked,
    "v1_in_single": inSingle,
    "v1_in_enc_frame": hex(inEncFrame),
    "v1_in_slices": inSlices.map(hex),
    "v1_in_chunked": inChunked,
    "v1_unexpected": unexpected,
    "v1_auth_reset": authReset,
]

// Health monitoring settings (docs/CAPABILITIES.md §9.1-9.3). hrBody is what a band could
// return, with fields the app doesn't know (20, 21, a fixed32 22) that must come back unchanged.
func pb(_ build: (inout PBWriter) -> Void) -> PBWriter { var w = PBWriter(); build(&w); return w }
let hrBody = pb {
    $0.varint(1, 0); $0.varint(2, 30); $0.varint(3, 1); $0.varint(4, 120)
    $0.message(5, pb { $0.varint(1, 1) }); $0.varint(7, 1)
    $0.message(8, pb { $0.varint(1, 0); $0.varint(2, 40) })
    $0.varint(9, 2); $0.varint(10, 0); $0.varint(11, 1); $0.varint(20, 300); $0.string(21, "ab")
}.data + Data([0xB5, 0x01, 1, 2, 3, 4])
let spo2Body = pb { $0.varint(1, 1); $0.varint(2, 0); $0.message(4, pb { $0.varint(1, 1); $0.varint(2, 90) }) }.data
let stressBody = pb { $0.varint(1, 0); $0.message(2, pb { $0.varint(1, 1); $0.varint(2, 0) }) }.data
let hrReply = pb { $0.varint(1, 8); $0.varint(2, 10); $0.message(10, pb { $0.bytes(8, hrBody) }) }.data
func hrSet(_ body: Data, _ mode: MiMonitoring.HeartRateMode?, _ sleep: Bool? = nil) -> String {
    MiMonitoring.heartRate(body, mode: mode, sleep: sleep).map { hex(MiMonitoring.set(.heartRate, $0)) } ?? "nil"
}
let monitoring: [String: Any] = [
    "mon_get": MiMonitoring.Setting.allCases.map { hex(MiMonitoring.get($0)) },
    "mon_reply": hex(MiMonitoring.reply(PBMessage(hrReply)!, .heartRate) ?? Data()),
    "mon_reply_other": MiMonitoring.reply(PBMessage(hrReply)!, .spo2) == nil,
    "mon_hr_parsed": "\(MiMonitoring.heartRateMode(hrBody)!)/\(MiMonitoring.sleepHeartRate(hrBody)!)",
    "mon_hr_1min": hrSet(hrBody, .every(1)),
    "mon_hr_off": hrSet(hrBody, .off),
    "mon_hr_smart_nosleep": hrSet(hrBody, .smart, false),
    "mon_hr_empty_smart": hrSet(Data(), .smart),
    "mon_hr_garbage": hrSet(Data([0x0A, 0x05, 0x01]), .smart),
    "mon_spo2_parsed": MiMonitoring.spo2Mode(spo2Body) ?? -1,
    "mon_spo2_allday": hex(MiMonitoring.set(.spo2, MiMonitoring.spo2(spo2Body, mode: 2)!)),
    "mon_stress_parsed": MiMonitoring.stressAllDay(stressBody) ?? true,
    "mon_stress_on": hex(MiMonitoring.set(.stress, MiMonitoring.stress(stressBody, allDay: true)!)),
]

// The band's state. batteryReply and basicState have the shape a Band 10 Pro sent (firmware 3.201.026).
func batteryReply(_ state: UInt64?) -> PBMessage {
    let battery = pb { $0.varint(1, 82); if let state { $0.varint(2, state) }; $0.message(3, pb { $0.varint(1, 3); $0.varint(2, 1_760_000_000) }) }
    return PBMessage(pb { $0.varint(1, 2); $0.varint(2, 1); $0.message(4, pb { $0.message(2, pb { $0.message(1, battery) }) }) }.data)!
}
let basicState = pb { $0.varint(1, 2); $0.varint(2, 78); $0.message(4, pb { $0.message(48, pb { $0.varint(1, 1); $0.varint(2, 0); $0.varint(3, 0); $0.varint(4, 0) }) }) }.data
let pushedState = pb { $0.varint(1, 2); $0.varint(2, 79); $0.message(4, pb { $0.message(49, pb { $0.varint(1, 2); $0.varint(2, 1); $0.varint(3, 2) }) }) }.data
let pushedCharging = pb { $0.varint(1, 2); $0.varint(2, 79); $0.message(4, pb { $0.message(49, pb { $0.varint(1, 2) }) }) }.data
func stateText(_ s: MiAuth.DeviceStateChange?) -> String {
    func t(_ b: Bool?) -> String { b.map { "\($0)" } ?? "nil" }
    return s.map { "\(t($0.charging))/\(t($0.worn))/\(t($0.asleep))" } ?? "nil"
}
let bandState: [String: Any] = [
    "battery_charging": [batteryReply(2), batteryReply(1), batteryReply(3), batteryReply(nil)].map { MiAuth.batteryCharging($0).map { "\($0)" } ?? "nil" },
    "battery_level_with_state": MiAuth.batteryLevel(batteryReply(2)) ?? 0,
    "state_basic_not_read": stateText(MiAuth.deviceStateChange(PBMessage(basicState)!)),
    "state_pushed": stateText(MiAuth.deviceStateChange(PBMessage(pushedState)!)),
    "state_pushed_one_field": stateText(MiAuth.deviceStateChange(PBMessage(pushedCharging)!)),
]

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
    "find_phone_stop": hex(MiAuth.findPhoneStopCommand()),
    "find_phone_parsed": findPhoneParsed,
    "activity_today": hex(MiAuth.activityListCommand(today: true)),
    "activity_past": hex(MiAuth.activityListCommand(today: false)),
    "activity_ack": hex(MiAuth.activityAckCommand(Data([0x00, 0xF1, 0x53, 0x65, 0x04, 0x00, 0x01]))),
    "activity_fetch": hex(MiAuth.activityFetchCommand(Data([0x00, 0xF1, 0x53, 0x65, 0x04, 0x00, 0x01]))),
    "clock_istanbul": hex(MiAuth.clockCommand(now: Date(timeIntervalSince1970: 1_760_000_000), timeZone: TimeZone(identifier: "Europe/Istanbul")!, is24Hour: true)),
    "clock_newyork_12h": hex(MiAuth.clockCommand(now: Date(timeIntervalSince1970: 1_760_000_000), timeZone: TimeZone(identifier: "America/New_York")!, is24Hour: false)),
    "live_parsed": "\(live.steps)/\(live.calories)/\(live.heartRate)/\(live.standingHours)",
    "live_moving": live.movingMinutes.map { Int($0) } ?? -1,
    "resend_seqs": [(10, 10), (10, 7), (3, 250), (40, 8), (40, 7), (10, 11)].map { MiFrame.resendSeqs(next: $0.0, nack: $0.1) },
]
print(String(data: try! JSONSerialization.data(withJSONObject: out.merging(v1) { $1 }.merging(monitoring) { $1 }.merging(bandState) { $1 }, options: [.sortedKeys, .prettyPrinted]), encoding: .utf8)!)
