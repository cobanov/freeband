import CommonCrypto
import CryptoKit
import Foundation

// Xiaomi wearable protocol over BLE V2 (service FE95, RX 005E, TX 005F).
// Byte layouts and their Gadgetbridge citations are in findings.md, sections 4 and 5.
// Platform independent (Foundation, CryptoKit, CommonCrypto) so it can be tested on the Mac.

enum MiFrame {
    static let kindNack: UInt8 = 0
    static let kindAck: UInt8 = 1
    static let kindSessionConfig: UInt8 = 2
    static let kindData: UInt8 = 3

    struct Packet {
        let kind: UInt8
        let seq: UInt8
        let payload: Data
    }

    /// START_SESSION_REQUEST: opcode 1, then TLVs version 01.00.00, max frame 0xFC00,
    /// TX window 32, send timeout 10000 ms.
    static let startSessionPayload = Data([
        0x01,
        0x01, 0x03, 0x00, 0x01, 0x00, 0x00,
        0x02, 0x02, 0x00, 0x00, 0xFC,
        0x03, 0x02, 0x00, 0x20, 0x00,
        0x04, 0x02, 0x00, 0x10, 0x27,
    ])

    /// The TX window in startSessionPayload: data frames the device may have unacknowledged.
    static let txWindow: UInt8 = 32

    /// The seqs to resend for a NACK carrying `nack` (the seq the device expects next) when `next`
    /// is the seq about to be sent: `nack` up to `next`, across the wrap; none outside the window.
    static func resendSeqs(next: UInt8, nack: UInt8) -> [UInt8] {
        let pending = next &- nack
        guard pending > 0, pending <= txWindow else { return [] }
        return (0..<pending).map { nack &+ $0 }
    }

    /// CRC-16/ARC over the payload only.
    static func crc16arc(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }

    /// a5 a5 | type | seq | len (u16 LE) | crc16 (u16 LE) | payload
    static func encode(kind: UInt8, seq: UInt8, payload: Data) -> Data {
        let len = UInt16(payload.count)
        let crc = crc16arc(payload)
        var out = Data([0xA5, 0xA5, kind & 0x0F, seq])
        out.append(contentsOf: [UInt8(len & 0xFF), UInt8(len >> 8), UInt8(crc & 0xFF), UInt8(crc >> 8)])
        out.append(payload)
        return out
    }

    /// Removes every complete frame from the front of `buffer`. Bytes before a preamble and
    /// frames with a bad checksum are dropped; an incomplete frame stays for the next call.
    static func drain(_ buffer: inout [UInt8]) -> [Packet] {
        var packets: [Packet] = []
        while buffer.count >= 2 {
            guard buffer[0] == 0xA5, buffer[1] == 0xA5 else {
                if let next = buffer.dropFirst().firstIndex(of: 0xA5) {
                    buffer.removeFirst(next)
                } else {
                    buffer.removeAll()
                }
                continue
            }
            guard buffer.count >= 3 else { break }
            // Types are 0-3; anything else means this a5 a5 was not a real preamble.
            guard buffer[2] & 0x0F <= kindData else {
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= 8 else { break }
            let len = Int(buffer[4]) | Int(buffer[5]) << 8
            guard buffer.count >= 8 + len else { break }
            let crc = UInt16(buffer[6]) | UInt16(buffer[7]) << 8
            let payload = Data(buffer[8..<(8 + len)])
            let kind = buffer[2] & 0x0F
            let seq = buffer[3]
            buffer.removeFirst(8 + len)
            if crc16arc(payload) == crc {
                packets.append(Packet(kind: kind, seq: seq, payload: payload))
            }
        }
        return packets
    }
}

/// Minimal proto2 writer: only what the commands below need.
struct PBWriter {
    private(set) var data = Data()

    mutating func varint(_ field: Int, _ value: UInt64) {
        key(field, wire: 0)
        putVarint(value)
    }

    mutating func bytes(_ field: Int, _ value: Data) {
        key(field, wire: 2)
        putVarint(UInt64(value.count))
        data.append(value)
    }

    /// sint32/sint64: zigzag-encoded varint.
    mutating func sint(_ field: Int, _ value: Int64) {
        varint(field, UInt64(bitPattern: (value << 1) ^ (value >> 63)))
    }

    mutating func bool(_ field: Int, _ value: Bool) {
        varint(field, value ? 1 : 0)
    }

    mutating func string(_ field: Int, _ value: String) {
        bytes(field, Data(value.utf8))
    }

    mutating func message(_ field: Int, _ value: PBWriter) {
        bytes(field, value.data)
    }

    private mutating func key(_ field: Int, wire: UInt64) {
        putVarint(UInt64(field) << 3 | wire)
    }

    private mutating func putVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }
}

/// Minimal proto2 reader: keeps the last varint and the last length-delimited value per field.
struct PBMessage {
    private(set) var varints: [Int: UInt64] = [:]
    private(set) var blobs: [Int: Data] = [:]
    private(set) var fieldNumbers: [Int] = []

    init?(_ data: Data) {
        let b = [UInt8](data)
        var i = 0
        func readVarint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while i < b.count, shift < 64 {
                let x = b[i]
                i += 1
                result |= UInt64(x & 0x7F) << shift
                if x & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }
        while i < b.count {
            guard let key = readVarint() else { return nil }
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let v = readVarint() else { return nil }
                varints[field] = v
            case 1:
                guard b.count - i >= 8 else { return nil }
                i += 8
            case 2:
                guard let n = readVarint(), n <= UInt64(b.count - i) else { return nil }
                blobs[field] = Data(b[i..<(i + Int(n))])
                i += Int(n)
            case 5:
                guard b.count - i >= 4 else { return nil }
                i += 4
            default:
                return nil
            }
            fieldNumbers.append(field)
        }
    }

    func message(_ field: Int) -> PBMessage? {
        blobs[field].flatMap(PBMessage.init)
    }
}

enum MiCrypto {
    static func hmacSHA256(key: Data, _ message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    /// HKDF-SHA256 with salt = phoneNonce ‖ watchNonce, IKM = auth key, info = "miwear-auth", 64 bytes.
    static func sessionKeyMaterial(authKey: Data, phoneNonce: Data, watchNonce: Data) -> Data {
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: authKey),
                                         salt: phoneNonce + watchNonce,
                                         info: Data("miwear-auth".utf8),
                                         outputByteCount: 64)
        return okm.withUnsafeBytes { Data($0) }
    }

    static func aesBlock(key: Data, _ block: Data) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let status = key.withUnsafeBytes { k in
            block.withUnsafeBytes { b in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                        k.baseAddress, key.count, nil, b.baseAddress, 16, &out, 16, &moved)
            }
        }
        precondition(status == kCCSuccess, "AES block failed: \(status)")
        return out
    }

    /// AES-128-CCM (RFC 3610) with a 12-byte nonce, 4-byte tag and no associated data.
    /// Returns ciphertext ‖ tag. Apple frameworks have no CCM, so it is built on AES-ECB.
    static func ccmEncrypt(key: Data, nonce: Data, plaintext: Data) -> Data {
        precondition(nonce.count == 12)
        let tagLength = 4
        let lengthSize = 15 - nonce.count
        let p = [UInt8](plaintext)

        func counterBlock(_ counter: Int) -> Data {
            Data([UInt8(lengthSize - 1)]) + nonce
                + Data([UInt8((counter >> 16) & 0xFF), UInt8((counter >> 8) & 0xFF), UInt8(counter & 0xFF)])
        }

        // CBC-MAC over B0 and the zero-padded plaintext
        var b0 = Data([UInt8(((tagLength - 2) / 2) << 3 | (lengthSize - 1))]) + nonce
        b0.append(contentsOf: [UInt8((p.count >> 16) & 0xFF), UInt8((p.count >> 8) & 0xFF), UInt8(p.count & 0xFF)])
        var mac = aesBlock(key: key, b0)
        for start in stride(from: 0, to: p.count, by: 16) {
            var block = mac
            for j in 0..<min(16, p.count - start) { block[j] ^= p[start + j] }
            mac = aesBlock(key: key, Data(block))
        }

        var out = Data()
        for (n, start) in stride(from: 0, to: p.count, by: 16).enumerated() {
            let s = aesBlock(key: key, counterBlock(n + 1))
            for j in 0..<min(16, p.count - start) { out.append(p[start + j] ^ s[j]) }
        }
        let s0 = aesBlock(key: key, counterBlock(0))
        for j in 0..<tagLength { out.append(mac[j] ^ s0[j]) }
        return out
    }

    /// AES-128-CTR with the key reused as the initial counter block (the V2 channel cipher;
    /// the counter restarts for every message).
    static func ctr(key: Data, _ input: Data) -> Data {
        var cryptor: CCCryptorRef?
        let created = key.withUnsafeBytes { k in
            CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                    CCPadding(ccNoPadding), k.baseAddress, k.baseAddress, key.count,
                                    nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
        }
        precondition(created == kCCSuccess, "CTR init failed: \(created)")
        defer { CCCryptorRelease(cryptor) }
        var out = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let status = input.withUnsafeBytes { i in
            CCCryptorUpdate(cryptor, i.baseAddress, input.count, &out, out.count, &moved)
        }
        precondition(status == kCCSuccess, "CTR update failed: \(status)")
        return Data(out)
    }
}

enum MiAuth {
    static let commandTypeAuth: UInt64 = 1
    static let subtypeNonce: UInt64 = 26
    static let subtypeAuth: UInt64 = 27

    struct SessionKeys {
        let decryptionKey: Data
        let encryptionKey: Data
        let decryptionNonce: Data
        let encryptionNonce: Data
    }

    /// Step 1: Command{type 1, subtype 26, auth.appVerify{nonce}}
    static func nonceCommand(phoneNonce: Data) -> Data {
        var verify = PBWriter()
        verify.bytes(1, phoneNonce)
        var account = PBWriter()
        account.message(30, verify)
        var command = PBWriter()
        command.varint(1, commandTypeAuth)
        command.varint(2, subtypeNonce)
        command.message(3, account)
        return command.data
    }

    /// Step 3: derives the session keys, checks the watch's HMAC (nil means the auth key is
    /// wrong) and builds Command{type 1, subtype 27, auth.appConfirm{...}}.
    static func confirmCommand(authKey: Data, phoneNonce: Data, watchNonce: Data, watchHmac: Data,
                               deviceName: String) -> (command: Data, keys: SessionKeys)? {
        let okm = [UInt8](MiCrypto.sessionKeyMaterial(authKey: authKey, phoneNonce: phoneNonce, watchNonce: watchNonce))
        let keys = SessionKeys(decryptionKey: Data(okm[0..<16]),
                               encryptionKey: Data(okm[16..<32]),
                               decryptionNonce: Data(okm[32..<36]),
                               encryptionNonce: Data(okm[36..<40]))

        guard MiCrypto.hmacSHA256(key: keys.decryptionKey, watchNonce + phoneNonce) == watchHmac else {
            return nil
        }

        // CompanionDevice as AstroBox sends it over BLE on iOS: device_type IOS (1, always
        // serialized), device_name, app_capability 0xFFFFFFFF.
        var companion = PBWriter()
        companion.varint(1, 1)
        companion.string(3, deviceName)
        companion.varint(4, 0xFFFF_FFFF)

        let ccmNonce = keys.encryptionNonce + Data(count: 8)
        var confirm = PBWriter()
        confirm.bytes(1, MiCrypto.hmacSHA256(key: keys.encryptionKey, phoneNonce + watchNonce))
        confirm.bytes(2, MiCrypto.ccmEncrypt(key: keys.encryptionKey, nonce: ccmNonce, plaintext: companion.data))
        var account = PBWriter()
        account.message(32, confirm)
        var command = PBWriter()
        command.varint(1, commandTypeAuth)
        command.varint(2, subtypeAuth)
        command.message(3, account)
        return (command.data, keys)
    }

    /// Command{type 2 (System), subtype 1}: battery request.
    static func batteryCommand() -> Data {
        var command = PBWriter()
        command.varint(1, 2)
        command.varint(2, 1)
        return command.data
    }

    /// Command.system(4).power(2).battery(1).level(1)
    static func batteryLevel(_ command: PBMessage) -> UInt64? {
        command.message(4)?.message(2)?.message(1)?.varints[1]
    }
}

extension MiAuth {
    struct LiveStats: Equatable {
        let steps: UInt64
        let calories: UInt64
        let heartRate: UInt64
        let standingHours: UInt64
    }

    /// Command{type 8 (Health), subtype 45 start | 46 stop}: the band then sends subtype 47
    /// events with today's totals and the current heart rate.
    static func realtimeCommand(start: Bool) -> Data {
        var command = PBWriter()
        command.varint(1, 8)
        command.varint(2, start ? 45 : 46)
        return command.data
    }

    /// Command.health(10).realTimeStats(39){steps 1, calories 2, heartRate 4, standingHours 6}
    static func liveStats(_ command: PBMessage) -> LiveStats? {
        guard let stats = command.message(10)?.message(39) else { return nil }
        return LiveStats(steps: stats.varints[1] ?? 0, calories: stats.varints[2] ?? 0,
                         heartRate: stats.varints[4] ?? 0, standingHours: stats.varints[6] ?? 0)
    }
}

extension MiAuth {
    /// Command{7, 0}: a notification shown on the band.
    /// notification(9).notification2(3).notification3(1){package 1, appName 2, title 3,
    /// unknown4 4 (""), body 5, timestamp 6 "yyyyMMdd'T'HHmmss" (local), id 7}
    static func notificationCommand(id: UInt32, appName: String, title: String, body: String, date: Date = Date()) -> Data {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyyMMdd'T'HHmmss"
        var n3 = PBWriter()
        n3.string(1, "dev.cobanov.freeband")
        n3.string(2, appName)
        n3.string(3, title)
        n3.string(4, "")
        n3.string(5, body)
        n3.string(6, format.string(from: date))
        n3.varint(7, UInt64(id))
        var n2 = PBWriter()
        n2.message(1, n3)
        var notification = PBWriter()
        notification.message(3, n2)
        var command = PBWriter()
        command.varint(1, 7)
        command.varint(2, 0)
        command.message(9, notification)
        return command.data
    }

    /// Command{2, 18, system(4).findDevice(5)}: 0 starts vibrating, 1 stops.
    static func findBandCommand(start: Bool) -> Data {
        var system = PBWriter()
        system.varint(5, start ? 0 : 1)
        var command = PBWriter()
        command.varint(1, 2)
        command.varint(2, 18)
        command.message(4, system)
        return command.data
    }
}

extension MiAuth {
    /// Command{8,1, health(10).activitySyncRequestToday(5){unknown1: 0}}, or Command{8,2} for past files.
    static func activityListCommand(today: Bool) -> Data {
        var command = PBWriter()
        command.varint(1, 8)
        command.varint(2, today ? 1 : 2)
        if today {
            var request = PBWriter()
            request.varint(1, 0)
            var health = PBWriter()
            health.message(5, request)
            command.message(10, health)
        }
        return command.data
    }

    /// Command{8,3, health(10).activityRequestFileIds(2) = 7-byte id}: the file arrives on channel 5.
    static func activityFetchCommand(_ id: Data) -> Data {
        var health = PBWriter()
        health.bytes(2, id)
        var command = PBWriter()
        command.varint(1, 8)
        command.varint(2, 3)
        command.message(10, health)
        return command.data
    }

    /// The N×7-byte id list in a {8,1} or {8,2} reply (health(10).activityRequestFileIds(2)).
    static func activityFileIDBytes(_ command: PBMessage) -> Data {
        command.message(10)?.blobs[2] ?? Data()
    }
}

extension MiAuth {
    /// Command{2,3}: system(4).clock(4){date 1{year, month, day}, time 2{hour, minute, second, ms},
    /// timezone 3{zoneOffset 1 sint32, dstOffset 2 sint32 (15-minute blocks), name 3}, isNot24hour 4}.
    /// Date and time are local.
    static func clockCommand(now: Date = Date(), timeZone: TimeZone = .current, is24Hour: Bool) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: now)
        var date = PBWriter()
        date.varint(1, UInt64(c.year ?? 2000))
        date.varint(2, UInt64(c.month ?? 1))
        date.varint(3, UInt64(c.day ?? 1))
        var time = PBWriter()
        time.varint(1, UInt64(c.hour ?? 0))
        time.varint(2, UInt64(c.minute ?? 0))
        time.varint(3, UInt64(c.second ?? 0))
        time.varint(4, UInt64((c.nanosecond ?? 0) / 1_000_000))
        let dst = Int64(timeZone.daylightSavingTimeOffset(for: now))
        let standard = Int64(timeZone.secondsFromGMT(for: now)) - dst
        var zone = PBWriter()
        zone.sint(1, standard / 900)
        zone.sint(2, dst / 900)
        zone.string(3, timeZone.identifier)
        var clock = PBWriter()
        clock.message(1, date)
        clock.message(2, time)
        clock.message(3, zone)
        clock.bool(4, !is24Hour)
        var system = PBWriter()
        system.message(4, clock)
        var command = PBWriter()
        command.varint(1, 2)
        command.varint(2, 3)
        command.message(4, system)
        return command.data
    }

    /// Whether the phone shows 24-hour time.
    static var phoneUses24Hour: Bool {
        !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")
    }

    static func systemGet(_ subtype: UInt64) -> Data {
        var command = PBWriter()
        command.varint(1, 2)
        command.varint(2, subtype)
        return command.data
    }

    struct DeviceInfo: Equatable {
        let serial: String
        let firmware: String
        let model: String
    }

    /// Reply to Command{2,2}: system(4).deviceInfo(3){serialNumber 1, firmware 2, model 4}.
    static func deviceInfo(_ command: PBMessage) -> DeviceInfo? {
        guard let info = command.message(4)?.message(3) else { return nil }
        func text(_ f: Int) -> String { info.blobs[f].map { String(decoding: $0, as: UTF8.self) } ?? "" }
        return DeviceInfo(serial: text(1), firmware: text(2), model: text(4))
    }

    struct DeviceState: Equatable {
        let charging: Bool
        let worn: Bool
        let asleep: Bool
    }

    /// Reply to Command{2,78}: system(4).basicDeviceState(48){isCharging 1, battery 2, isWorn 3, isUserAsleep 4}.
    /// The band also pushes Command{2,79}: system(4).deviceState(49){charging 1 (1 yes, 2 no), wearing 2, sleep 3}.
    static func deviceState(_ command: PBMessage) -> DeviceState? {
        let system = command.message(4)
        if let basic = system?.message(48) {
            return DeviceState(charging: basic.varints[1] == 1, worn: basic.varints[3] == 1, asleep: basic.varints[4] == 1)
        }
        if let pushed = system?.message(49) {
            return DeviceState(charging: pushed.varints[1] == 1, worn: pushed.varints[2] == 1, asleep: pushed.varints[3] == 1)
        }
        return nil
    }
}
