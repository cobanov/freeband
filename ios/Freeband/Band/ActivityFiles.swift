import Foundation

// Activity files of the Xiaomi Smart Band 10 / 10 Pro: the 7-byte file id, reassembly of the
// decrypted channel-5 packets, the CRC-32 trailer and the payload parsers.
//
// Byte layouts: docs/ACTIVITY.md, sections 3-10. Written from that spec and from the stdlib
// reference parser ios/tests/activity/activity_ref.py; tested against the same fixtures by
// ios/tests/activity/swift/main.swift. Foundation only, so it builds and runs on macOS too.
//
// Defensive by construction: every read of file data goes through ActivityByteReader, which
// throws instead of reading out of range; there are no force unwraps, and arithmetic on values
// taken from a file is done in Int/Int64 or with wrapping operators, so malformed input can
// produce an error or a partial result but never a trap.

// MARK: - Helpers

private let activityHexDigits = Array("0123456789abcdef".utf8)

/// Lowercase hex, two characters per byte.
func activityHexString<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
    var out: [UInt8] = []
    out.reserveCapacity(bytes.underestimatedCount * 2)
    for b in bytes {
        out.append(activityHexDigits[Int(b >> 4)])
        out.append(activityHexDigits[Int(b & 0x0F)])
    }
    return String(decoding: out, as: UTF8.self)
}

private func unixDate(_ seconds: Int64) -> Date {
    Date(timeIntervalSince1970: TimeInterval(seconds))
}

private func hexByte(_ b: UInt8) -> String { "0x" + activityHexString([b]) }

// MARK: - CRC-32

/// Standard CRC-32 (ISO-HDLC / IEEE 802.3 / zlib): reflected polynomial 0xEDB88320,
/// init and final XOR 0xFFFFFFFF. Spec section 4.2.
enum ActivityCRC32 {
    /// CRC of the ASCII bytes "123456789".
    static let checkValue: UInt32 = 0xCBF4_3926

    private static let table: [UInt32] = (0 ..< 256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0 ..< 8 {
            c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1
        }
        return c
    }

    static func checksum<Bytes: Sequence>(_ bytes: Bytes) -> UInt32 where Bytes.Element == UInt8 {
        let table = Self.table
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }

    /// The stored trailer (last 4 bytes, little-endian) and the CRC computed over everything
    /// before it. Nil when there are fewer than 4 bytes.
    static func trailer(of bytes: [UInt8]) -> (stored: UInt32, computed: UInt32)? {
        guard bytes.count >= 4 else { return nil }
        let n = bytes.count - 4
        let stored = UInt32(bytes[n]) | (UInt32(bytes[n + 1]) << 8)
            | (UInt32(bytes[n + 2]) << 16) | (UInt32(bytes[n + 3]) << 24)
        return (stored, checksum(bytes[0 ..< n]))
    }

    static func trailer(of file: Data) -> (stored: UInt32, computed: UInt32)? {
        trailer(of: [UInt8](file))
    }
}

// MARK: - Bounds-checked reader

/// Little-endian (unless noted) reader over bytes[position..<end]. Every read checks the
/// remaining length first and throws ActivityParseError.truncated instead of trapping.
struct ActivityByteReader {
    let bytes: [UInt8]
    private(set) var position: Int
    let end: Int

    init(_ bytes: [UInt8], from start: Int = 0, to end: Int? = nil) {
        self.bytes = bytes
        let e = min(max(end ?? bytes.count, 0), bytes.count)
        self.end = e
        position = min(max(start, 0), e)
    }

    var remaining: Int { end - position }

    mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, n <= remaining else {
            throw ActivityParseError.truncated(offset: position, needed: n, available: remaining)
        }
        let slice = bytes[position ..< position + n]
        position += n
        return slice
    }

    mutating func array(_ n: Int) throws -> [UInt8] { Array(try take(n)) }

    mutating func skip(_ n: Int) throws { _ = try take(n) }

    /// Unsigned little-endian integer of 1...8 bytes.
    mutating func uintLE(_ n: Int) throws -> UInt64 {
        guard (1 ... 8).contains(n) else { throw ActivityParseError.malformed("integer width \(n)") }
        var value: UInt64 = 0
        for (i, b) in try take(n).enumerated() {
            value |= UInt64(b) << UInt64(8 * i)
        }
        return value
    }

    /// Unsigned big-endian integer of 1...8 bytes.
    mutating func uintBE(_ n: Int) throws -> UInt64 {
        guard (1 ... 8).contains(n) else { throw ActivityParseError.malformed("integer width \(n)") }
        var value: UInt64 = 0
        for b in try take(n) {
            value = (value << 8) | UInt64(b)
        }
        return value
    }

    mutating func u8() throws -> UInt8 { UInt8(truncatingIfNeeded: try uintLE(1)) }
    mutating func u16() throws -> UInt16 { UInt16(truncatingIfNeeded: try uintLE(2)) }
    mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }
    mutating func u16BE() throws -> UInt16 { UInt16(truncatingIfNeeded: try uintBE(2)) }
    mutating func u32() throws -> UInt32 { UInt32(truncatingIfNeeded: try uintLE(4)) }
    mutating func i64() throws -> Int64 { Int64(bitPattern: try uintLE(8)) }
    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
}

// MARK: - Errors

enum ActivityParseError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Fewer bytes than id + pad (+ 1 + CRC when the file carries one).
    case fileTooShort(length: Int, minimum: Int)
    case crcMismatch(stored: UInt32, computed: UInt32)
    /// A read ran past the end of the payload; offset is relative to the payload start.
    case truncated(offset: Int, needed: Int, available: Int)
    /// The bytes contradict the layout (bad header byte, out-of-range value, ...).
    case malformed(String)

    var description: String {
        switch self {
        case let .fileTooShort(length, minimum):
            return "file of \(length) bytes is shorter than the \(minimum)-byte minimum"
        case let .crcMismatch(stored, computed):
            return "crc stored \(String(stored, radix: 16)) computed \(String(computed, radix: 16))"
        case let .truncated(offset, needed, available):
            return "need \(needed) byte(s) at payload offset \(offset), \(available) left"
        case let .malformed(message):
            return message
        }
    }
}

// MARK: - File id (spec section 3)

/// What a file id says the file holds, which picks the parser (spec section 3.1).
enum ActivityFileKind: String, Sendable, CaseIterable {
    case dailyDetails = "daily_details"
    case dailySummary = "daily_summary"
    case sleepDetails = "sleep_details"
    case sleepStages = "sleep_stages"
    case manualSamples = "manual_samples"
    case workoutSummary = "workout_summary"
    case workoutDetails = "workout_details"
    case workoutGPS = "workout_gps"
    case unknown

    /// File format versions this module can parse (spec sections 6 and 9). Empty for kinds
    /// that are only stored raw: workouts and unknown files.
    var supportedVersions: Set<UInt8> {
        switch self {
        case .dailyDetails: return [1, 2, 3, 4]
        case .dailySummary: return [3, 4, 5]
        case .sleepDetails: return [1, 2, 3, 4, 5, 6]
        case .sleepStages: return [2]
        case .manualSamples: return [1, 2]
        case .workoutSummary, .workoutDetails, .workoutGPS, .unknown: return []
        }
    }

    var isWorkout: Bool { self == .workoutSummary || self == .workoutDetails || self == .workoutGPS }
}

/// The 7-byte activity file id: ts u32 LE | tz i8 (quarter hours) | version u8 |
/// flags u8 = type << 7 | subtype << 2 | detailType.
struct ActivityFileID: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// Unix seconds, UTC.
    let timestamp: UInt32
    /// UTC offset in 15-minute blocks, signed (0xF4 = -12 = UTC-3).
    let tzQuarterHours: Int8
    let version: UInt8
    /// 0 activity, 1 sports (1 bit).
    let type: UInt8
    /// 5 bits; for sports files the workout kind.
    let subtype: UInt8
    /// 0 details, 1 summary, 2 GPS track (2 bits).
    let detailType: UInt8

    enum FileType {
        static let activity: UInt8 = 0
        static let sports: UInt8 = 1
    }

    /// Activity subtypes (type 0).
    enum Subtype {
        static let daily: UInt8 = 0x00
        static let sleepStages: UInt8 = 0x03
        static let manualSamples: UInt8 = 0x06
        static let sleep: UInt8 = 0x08
    }

    enum DetailType {
        static let details: UInt8 = 0
        static let summary: UInt8 = 1
        static let gpsTrack: UInt8 = 2
    }

    /// Sports subtypes (type 1).
    enum Sport: UInt8, CaseIterable, Sendable {
        case outdoorRunning = 0x01
        case outdoorWalkingV1 = 0x02
        case treadmill = 0x03
        case outdoorCyclingV2 = 0x06
        case indoorCycling = 0x07
        case freestyle = 0x08
        case poolSwimming = 0x09
        case elliptical = 0x0B
        case rowing = 0x0D
        case jumpRoping = 0x0E
        case hiit = 0x10
        case outdoorWalkingV2 = 0x16
        case outdoorCycling = 0x17

        var name: String {
            switch self {
            case .outdoorRunning: return "outdoor_running"
            case .outdoorWalkingV1: return "outdoor_walking_v1"
            case .treadmill: return "treadmill"
            case .outdoorCyclingV2: return "outdoor_cycling_v2"
            case .indoorCycling: return "indoor_cycling"
            case .freestyle: return "freestyle"
            case .poolSwimming: return "pool_swimming"
            case .elliptical: return "elliptical"
            case .rowing: return "rowing"
            case .jumpRoping: return "jump_roping"
            case .hiit: return "hiit"
            case .outdoorWalkingV2: return "outdoor_walking_v2"
            case .outdoorCycling: return "outdoor_cycling"
            }
        }
    }

    /// Fields are masked to their bit widths, so every value encodes to exactly one byte string.
    init(timestamp: UInt32, tzQuarterHours: Int8 = 0, version: UInt8, type: UInt8, subtype: UInt8, detailType: UInt8) {
        self.timestamp = timestamp
        self.tzQuarterHours = tzQuarterHours
        self.version = version
        self.type = type & 0x01
        self.subtype = subtype & 0x1F
        self.detailType = detailType & 0x03
    }

    /// Exactly 7 bytes, else nil. Works on Data slices with any start index.
    init?(_ bytes: Data) {
        self.init(bytes: [UInt8](bytes))
    }

    init?<Bytes: Collection>(bytes: Bytes) where Bytes.Element == UInt8 {
        guard bytes.count == 7 else { return nil }
        let b = Array(bytes)
        let flags = b[6]
        self.init(
            timestamp: UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24),
            tzQuarterHours: Int8(bitPattern: b[4]),
            version: b[5],
            type: flags >> 7,
            subtype: (flags & 0x7F) >> 2,
            detailType: flags & 0x03
        )
    }

    var flags: UInt8 { (type << 7) | (subtype << 2) | detailType }

    var bytes: [UInt8] {
        [
            UInt8(truncatingIfNeeded: timestamp), UInt8(truncatingIfNeeded: timestamp >> 8),
            UInt8(truncatingIfNeeded: timestamp >> 16), UInt8(truncatingIfNeeded: timestamp >> 24),
            UInt8(bitPattern: tzQuarterHours), version, flags,
        ]
    }

    /// The 7 bytes, as sent in a fetch request.
    var data: Data { Data(bytes) }

    /// Lowercase, 14 characters.
    var hex: String { activityHexString(bytes) }

    var ts: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }

    var utcOffsetMinutes: Int { Int(tzQuarterHours) * 15 }

    /// The band's UTC offset when it wrote the file; nil if outside what TimeZone accepts.
    /// Times in files are UTC; use this only for day boundaries (spec section 7).
    var timeZone: TimeZone? { TimeZone(secondsFromGMT: utcOffsetMinutes * 60) }

    /// List entries with ts == 0 and version == 0 are placeholders and are never requested.
    var isPlaceholder: Bool { timestamp == 0 && version == 0 }

    var kind: ActivityFileKind {
        if type == FileType.sports {
            switch detailType {
            case DetailType.details: return .workoutDetails
            case DetailType.summary: return .workoutSummary
            case DetailType.gpsTrack: return .workoutGPS
            default: return .unknown
            }
        }
        switch (subtype, detailType) {
        case (Subtype.daily, DetailType.details): return .dailyDetails
        case (Subtype.daily, DetailType.summary): return .dailySummary
        case (Subtype.sleepStages, DetailType.details): return .sleepStages
        case (Subtype.manualSamples, DetailType.details): return .manualSamples
        case (Subtype.sleep, _): return .sleepDetails  // every detail type
        default: return .unknown
        }
    }

    var sport: Sport? { type == FileType.sports ? Sport(rawValue: subtype) : nil }

    var typeName: String { type == FileType.activity ? "activity" : "sports" }

    var subtypeName: String {
        if type == FileType.sports {
            if let sport { return sport.name }
        } else {
            switch subtype {
            case Subtype.daily: return "daily"
            case Subtype.sleepStages: return "sleep_stages"
            case Subtype.manualSamples: return "manual_samples"
            case Subtype.sleep: return "sleep"
            default: break
            }
        }
        return "unknown_" + activityHexString([subtype])
    }

    var detailName: String {
        switch detailType {
        case DetailType.details: return "details"
        case DetailType.summary: return "summary"
        case DetailType.gpsTrack: return "gps_track"
        default: return "unknown"
        }
    }

    /// Summary first, so a workout's summary is at hand when its details arrive.
    var fetchRank: Int {
        switch detailType {
        case DetailType.summary: return 0
        case DetailType.details: return 1
        case DetailType.gpsTrack: return 2
        default: return 3
        }
    }

    /// Fetch order: ts, tz, type, subtype, detail fetch rank, version (spec section 2.5).
    static func < (a: ActivityFileID, b: ActivityFileID) -> Bool {
        (a.timestamp, a.tzQuarterHours, a.type, a.subtype, a.fetchRank, a.version)
            < (b.timestamp, b.tzQuarterHours, b.type, b.subtype, b.fetchRank, b.version)
    }

    /// health.activityRequestFileIds of a list reply: N x 7 bytes. Placeholders are dropped;
    /// a length that is not a multiple of 7 yields [] (the whole list is untrustworthy).
    static func list(_ bytes: Data) -> [ActivityFileID] {
        let raw = [UInt8](bytes)
        guard raw.count % 7 == 0 else { return [] }
        return stride(from: 0, to: raw.count, by: 7).compactMap { i -> ActivityFileID? in
            guard let id = ActivityFileID(bytes: raw[i ..< i + 7]), !id.isPlaceholder else { return nil }
            return id
        }
    }

    var description: String { "\(hex) \(typeName)/\(subtypeName)/\(detailName) v\(version)" }
}

// MARK: - Files stored under another file's id

/// What to do with a stored file whose bytes open with a different id than the one it is stored
/// under.
enum Refile: Equatable, Sendable {
    /// File it under the id it carries.
    case move(to: ActivityFileID)
    /// That id already holds its own bytes, or another stored file moves there first.
    case drop
}

/// Up to 0.5.2 a file was stored under the id the app had asked for, and a band that answers
/// late (Band 10, Redmi Watch 5 Active) left files under another file's id. The file asked for was
/// then never fetched again, which lost a night's sleep (freeband#2). A file opens with its own
/// id, so each misfiled one moves to it, unless that id is already taken by bytes that are its
/// own or by an earlier move. Keyed by the stored hex; files filed correctly, or too short to
/// carry an id, are not in the result. One band's files at a time.
func refilePlan(_ stored: [(hex: String, data: Data)]) -> [String: Refile] {
    var claimed = Set<String>()
    var misfiled: [(hex: String, own: ActivityFileID)] = []
    for file in stored {
        guard let own = ActivityFileID(file.data.prefix(7)) else { continue }
        if own.hex == file.hex { claimed.insert(own.hex) } else { misfiled.append((file.hex, own)) }
    }
    var plan: [String: Refile] = [:]
    for file in misfiled.sorted(by: { $0.hex < $1.hex }) {
        plan[file.hex] = claimed.insert(file.own.hex).inserted ? .move(to: file.own) : .drop
    }
    return plan
}

// MARK: - Chunk reassembly (spec section 4)

enum AssemblerEvent: Equatable, Sendable {
    case needMore
    /// The whole file, id through CRC trailer; the CRC is already verified.
    case complete(Data)
    case failed(String)
}

enum ActivityAssemblyError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Fewer than the 4 header bytes.
    case packetTooShort(length: Int)
    /// A first chunk announcing zero chunks.
    case zeroTotal
    /// Gap, duplicate, reordering, or a chunk while no file is in progress.
    case unexpectedChunk(num: Int, total: Int, expected: Int)
    /// The total changed in the middle of a file.
    case totalChanged(num: Int, total: Int, expectedTotal: Int)
    case fileTooLarge(limit: Int)
    /// Assembled file below id(7) + pad(1) + 1 + CRC(4).
    case fileTooShort(length: Int)
    case crcMismatch(stored: UInt32, computed: UInt32)

    var description: String {
        switch self {
        case let .packetTooShort(length):
            return "chunk of \(length) bytes has no header"
        case .zeroTotal:
            return "first chunk announces a total of 0"
        case let .unexpectedChunk(num, total, expected):
            return "chunk \(num)/\(total) out of sequence, expected \(expected)"
        case let .totalChanged(num, total, expectedTotal):
            return "chunk \(num)/\(total) changes the total from \(expectedTotal)"
        case let .fileTooLarge(limit):
            return "file grew past \(limit) bytes"
        case let .fileTooShort(length):
            return "file of \(length) bytes is shorter than the 13-byte minimum"
        case let .crcMismatch(stored, computed):
            return "crc stored \(String(stored, radix: 16)) computed \(String(computed, radix: 16))"
        }
    }
}

/// Joins decrypted channel-5 packets into one file. Each packet:
/// total u16 LE | num u16 LE (1-based) | next slice of the file; num == total closes the file.
/// Stricter than the band requires: any chunk other than the expected next one, or a change of
/// total, drops the buffer and fails the file. A num == 1 chunk always starts a new file.
struct ActivityAssembler {
    static let minimumFileLength = 13
    static let defaultMaxFileSize = 16 << 20

    let maxFileSize: Int
    private var buffer = Data()
    private var total = 0  // 0: no file in progress
    private var nextNum = 1

    init(maxFileSize: Int = ActivityAssembler.defaultMaxFileSize) {
        self.maxFileSize = maxFileSize
    }

    var isAssembling: Bool { total != 0 }

    /// Chunks received and expected for the file in progress.
    var progress: (received: Int, total: Int)? { isAssembling ? (nextNum - 1, total) : nil }

    /// Drops any partial file (for example after a timeout).
    mutating func reset() {
        buffer = Data()
        total = 0
        nextNum = 1
    }

    mutating func add(_ packet: Data) -> AssemblerEvent {
        switch feed(packet) {
        case .success(nil): return .needMore
        case let .success(file?): return .complete(file)
        case let .failure(error): return .failed(error.description)
        }
    }

    /// Same as add(_:), with a typed error. .success(nil) means more chunks are needed.
    mutating func feed(_ packet: Data) -> Result<Data?, ActivityAssemblyError> {
        let header = [UInt8](packet.prefix(4))
        guard header.count == 4 else {
            reset()
            return .failure(.packetTooShort(length: packet.count))
        }
        let total = Int(header[0]) | (Int(header[1]) << 8)
        let num = Int(header[2]) | (Int(header[3]) << 8)
        if num == 1 {
            reset()
            guard total >= 1 else { return .failure(.zeroTotal) }
            self.total = total
        } else if !isAssembling {
            return .failure(.unexpectedChunk(num: num, total: total, expected: 1))
        } else if total != self.total {
            let expectedTotal = self.total
            reset()
            return .failure(.totalChanged(num: num, total: total, expectedTotal: expectedTotal))
        } else if num != nextNum {
            let expected = nextNum
            reset()
            return .failure(.unexpectedChunk(num: num, total: total, expected: expected))
        }
        let slice = packet.dropFirst(4)
        guard slice.count <= maxFileSize - buffer.count else {
            reset()
            return .failure(.fileTooLarge(limit: maxFileSize))
        }
        buffer.append(contentsOf: slice)
        nextNum = num + 1
        guard num >= self.total else { return .success(nil) }

        let file = buffer
        reset()
        guard file.count >= Self.minimumFileLength else { return .failure(.fileTooShort(length: file.count)) }
        guard let crc = ActivityCRC32.trailer(of: file) else { return .failure(.fileTooShort(length: file.count)) }
        guard crc.stored == crc.computed else {
            return .failure(.crcMismatch(stored: crc.stored, computed: crc.computed))
        }
        return .success(file)
    }
}

// MARK: - Shared payload pieces

/// Validity bitmap, MSB first: field i is bit 7 - i % 8 of bitmap[i / 8] (spec section 5.1).
private func bitValid(_ bitmap: [UInt8], _ index: Int) -> Bool {
    guard index >= 0, index / 8 < bitmap.count else { return false }
    return bitmap[index / 8] & (0x80 >> UInt8(index % 8)) != 0
}

enum SleepStage: String, Sendable, CaseIterable {
    case awake, light, deep, rem
    case notSleep = "not_sleep"
    case unknown

    /// Raw code in a sleep details type-17 packet (spec section 8, first table).
    init(detailsCode code: UInt8) {
        switch code {
        case 0: self = .awake
        case 1: self = .light
        case 2: self = .deep
        case 3: self = .rem
        case 4: self = .notSleep
        default: self = .unknown
        }
    }

    /// Phase byte in a sleep stages file (spec section 8, second table).
    init(storedCode code: UInt8) {
        switch code {
        case 2: self = .deep
        case 3: self = .light
        case 4: self = .rem
        case 5: self = .awake
        default: self = .unknown
        }
    }
}

struct SleepStageSample: Equatable, Sendable {
    let ts: Date
    let stage: SleepStage
    /// The byte as the band sent it (its meaning depends on the file kind).
    let raw: UInt8
    /// Set in sleep details (each word carries its own duration); nil in sleep stages files,
    /// where a phase lasts until the next change.
    let durationMinutes: Int?
}

/// One night (or nap) as the band bounds it: bedTime ... wakeTime.
struct SleepSession: Equatable, Sendable {
    let bedTime: Date
    let wakeTime: Date
    let deepMinutes: Int?
    let lightMinutes: Int?
    let remMinutes: Int?
    let awakeMinutes: Int?
    let stages: [SleepStageSample]

    /// Several files can describe the same sleep: same bedTime, growing wakeTime. Keeps the one
    /// with the latest wakeTime per bedTime (spec section 8), sorted by bedTime.
    static func merge(_ sessions: [SleepSession]) -> [SleepSession] {
        var latest: [Date: SleepSession] = [:]
        for session in sessions {
            if let kept = latest[session.bedTime], kept.wakeTime >= session.wakeTime { continue }
            latest[session.bedTime] = session
        }
        return latest.values.sorted { $0.bedTime < $1.bedTime }
    }
}

// MARK: - Daily details (spec section 6.1)

/// ACTIVITY / DAILY / DETAILS: one record per minute.
struct DailyDetails: Equatable, Sendable {
    /// Nibble header length per version.
    static let headerLengths: [UInt8: Int] = [1: 4, 2: 4, 3: 5, 4: 6]

    struct Record: Equatable, Sendable {
        /// fileID.ts + 60 s * index.
        var ts: Date
        var steps: Int?
        /// Raw value; [spec: probably kcal].
        var activeCalories: Int?
        var distanceMeters: Int?
        /// Raw bpm; 0 likely means not measured (the app should keep 10...250).
        var heartRate: Int?
        /// Body energy, raw.
        var energy: Int?
        /// v3+; 0 means none.
        var spo2: Int?
        /// v3+; 255 (none) is already mapped to nil, 0 means none.
        var stress: Int?
        /// The byte flagged by g0 bit 14; meaning unknown.
        var extraByte: UInt8?
        /// v4 "light value", not decoded.
        var lightRaw: Int?
        /// v4 "body momentum", not decoded.
        var bodyMomentumRaw: Int?
    }

    let version: UInt8
    /// The nibble header shared by every record.
    let header: [UInt8]
    let records: [Record]
    /// Bytes of a partial record at the end (or bytes left unread), 0 when the body ended cleanly.
    let truncatedTail: Int

    private struct Group {
        let raw: UInt64
        let width: Int
        let nibble: UInt8

        /// Nibble bits 2, 1, 0 = slots 0, 1, 2 valid.
        func valid(_ slot: Int) -> Bool { nibble & (0x4 >> UInt8(slot)) != 0 }

        /// count bits starting `start` bits below the most significant bit.
        func bits(_ start: Int, _ count: Int) -> Int {
            Int((raw >> UInt64(width - start - count)) & ((1 << UInt64(count)) - 1))
        }
    }

    private struct Groups {
        let header: [UInt8]
        var index = 0

        /// Next group, read from the record if its nibble has the presence bit (0x8); an absent
        /// group takes no bytes. Groups beyond the header count as absent.
        mutating func next(_ width: Int, _ reader: inout ActivityByteReader) throws -> Group? {
            let i = index
            index += 1
            guard i / 2 < header.count else { return nil }
            let b = header[i / 2]
            let nibble = i % 2 == 0 ? b >> 4 : b & 0x0F
            guard nibble & 0x8 != 0 else { return nil }
            return Group(raw: try reader.uintLE(width / 8), width: width, nibble: nibble)
        }
    }

    private static func record(_ version: UInt8, _ header: [UInt8], _ r: inout ActivityByteReader, ts: Date) throws -> Record {
        var g = Groups(header: header)
        var rec = Record(ts: ts)
        var extra = false
        if let x = try g.next(16, &r) {  // g0: [15] unknown | [14] extra-byte flag | [13..0] steps
            if x.valid(1) { extra = x.bits(1, 1) == 1 }
            if x.valid(2) { rec.steps = x.bits(2, 14) }
        }
        if let x = try g.next(8, &r), x.valid(1) { rec.activeCalories = x.bits(2, 6) }  // g1
        _ = try g.next(8, &r)  // g2: unknown
        if let x = try g.next(16, &r), x.valid(0) { rec.distanceMeters = Int(x.raw) }  // g3
        if let x = try g.next(8, &r), x.valid(0) { rec.heartRate = Int(x.raw) }  // g4
        if let x = try g.next(8, &r), x.valid(0) { rec.energy = Int(x.raw) }  // g5
        _ = try g.next(16, &r)  // g6: unknown
        if version >= 3 {
            if let x = try g.next(8, &r), x.valid(0) { rec.spo2 = Int(x.raw) }  // g7
            if let x = try g.next(8, &r), x.valid(0), x.raw != 0xFF { rec.stress = Int(x.raw) }  // g8
        }
        if extra { rec.extraByte = try r.u8() }  // after g6 (v1/v2) or g8 (v3+), before g9
        if version >= 4 {
            if let x = try g.next(16, &r), x.valid(0) { rec.lightRaw = Int(x.raw) }  // g9
            if let x = try g.next(16, &r), x.valid(0) { rec.bodyMomentumRaw = Int(x.raw) }  // g10
        }
        return rec
    }

    static func parse(body: [UInt8], fileID: ActivityFileID, warnings: inout [String]) throws -> DailyDetails {
        guard let headerLength = headerLengths[fileID.version] else {
            throw ActivityParseError.malformed("daily details version \(fileID.version) unsupported")
        }
        var r = ActivityByteReader(body)
        let header = try r.array(headerLength)
        let base = Int64(fileID.timestamp)
        var records: [Record] = []
        var tail = 0
        while r.remaining > 0 {
            let start = r.position
            let ts = unixDate(base + 60 * Int64(records.count))
            let rec: Record
            do {
                rec = try record(fileID.version, header, &r, ts: ts)
            } catch {
                tail = r.end - start
                warnings.append("daily details: partial record of \(tail) byte(s) after \(records.count) record(s)")
                break
            }
            guard r.position > start else {
                // No group present: records would take no bytes. Stop rather than loop forever.
                tail = r.remaining
                warnings.append("daily details: header \(activityHexString(header)) marks no group present, \(tail) byte(s) unread")
                break
            }
            records.append(rec)
        }
        return DailyDetails(version: fileID.version, header: header, records: records, truncatedTail: tail)
    }
}

// MARK: - Daily summary (spec section 6.2)

/// ACTIVITY / DAILY / SUMMARY: one record for the day. Every slot is consumed whatever its
/// validity bit says; the bit only decides whether the value is used.
struct DailySummary: Equatable, Sendable {
    /// Bytes per slot, slots 0-31 (21-31 exist from version 5 on).
    static let slotSizes = [4, 2, 1, 1, 1, 4, 1, 4, 1, 1, 1, 1, 3, 2, 2, 1, 1, 4, 1, 4, 1,
                            2, 2, 1, 1, 1, 1, 2, 1, 1, 2, 2]
    static let layouts: [UInt8: (bitmapBytes: Int, slots: Int)] = [3: (3, 21), 4: (3, 21), 5: (4, 32)]
    /// A Band 10 Pro v5 file stops after slot 29 (its bitmap marks 30 and 31 invalid), so slots
    /// past the v3/v4 set may be missing when the body ends cleanly on a slot boundary.
    static let baseSlots = 21

    let version: UInt8
    /// fileID.ts.
    let day: Date
    let tzQuarterHours: Int8
    let bitmap: [UInt8]
    /// Raw unsigned value per slot (32 entries, reserved slots included); nil when the validity
    /// bit is clear or the slot does not exist in this version.
    let slots: [Int?]
    /// Bytes after the last slot (0 normally).
    let trailingBytes: Int

    func slot(_ index: Int) -> Int? { index >= 0 && index < slots.count ? slots[index] : nil }
    private func time(_ index: Int) -> Date? { slot(index).map { unixDate(Int64($0)) } }

    var steps: Int? { slot(0) }
    var activeCalories: Int? { slot(1) }
    var hrResting: Int? { slot(3) }
    var hrMax: Int? { slot(4) }
    var hrMaxTs: Date? { time(5) }
    var hrMin: Int? { slot(6) }
    var hrMinTs: Date? { time(7) }
    var hrAvg: Int? { slot(8) }
    var stressAvg: Int? { slot(9) }
    var stressMax: Int? { slot(10) }
    var stressMin: Int? { slot(11) }
    /// 24-bit mask: bit h set = stood during hour h.
    var standing: Int? { slot(12) }
    var standingHours: [Int]? { standing.map { mask in (0 ..< 24).filter { (mask >> $0) & 1 == 1 } } }
    var calories: Int? { slot(13) }
    var recoveryHours: Int? { slot(14) }
    var spo2Max: Int? { slot(16) }
    var spo2MaxTs: Date? { time(17) }
    var spo2Min: Int? { slot(18) }
    var spo2MinTs: Date? { time(19) }
    var spo2Avg: Int? { slot(20) }
    var trainingLoadDay: Int? { slot(21) }
    var trainingLoadWeek: Int? { slot(22) }
    var trainingLoadLevel: Int? { slot(23) }
    var vitalityIncreaseLight: Int? { slot(24) }
    var vitalityIncreaseModerate: Int? { slot(25) }
    var vitalityIncreaseHigh: Int? { slot(26) }
    var vitalityCurrent: Int? { slot(27) }

    static func parse(body: [UInt8], fileID: ActivityFileID) throws -> DailySummary {
        guard let layout = layouts[fileID.version] else {
            throw ActivityParseError.malformed("daily summary version \(fileID.version) unsupported")
        }
        var r = ActivityByteReader(body)
        let bitmap = try r.array(layout.bitmapBytes)
        var slots = [Int?](repeating: nil, count: slotSizes.count)
        for i in 0 ..< min(layout.slots, slotSizes.count) {
            if i >= baseSlots, r.remaining == 0 { break }
            let value = try r.uintLE(slotSizes[i])
            slots[i] = bitValid(bitmap, i) ? Int(value) : nil
        }
        return DailySummary(version: fileID.version, day: fileID.ts, tzQuarterHours: fileID.tzQuarterHours,
                            bitmap: bitmap, slots: slots, trailingBytes: r.remaining)
    }
}

// MARK: - Sleep details (spec section 6.3)

/// unit i16 | count i16 | first ts u32 (count > 0 and v2+; v1 uses bedTime) | count values.
struct SleepSampleBlock<Value: Equatable & Sendable>: Equatable, Sendable {
    /// Seconds between samples [spec: probably].
    let unit: Int
    let count: Int
    let firstTs: Date?
    let values: [Value]

    var samples: [(ts: Date, value: Value)] {
        guard let firstTs else { return [] }
        return values.enumerated().map { (firstTs.addingTimeInterval(TimeInterval(unit * $0.offset)), $0.element) }
    }
}

/// One packet of the magic-synchronised stream at the end of a sleep details file.
struct SleepPacket: Equatable, Sendable {
    let type: UInt8
    /// i64; seconds for types 16 and 17, unit unclear for others (type 1 looks like ms).
    let tsRaw: Int64
    let parity: UInt8
    let headerLength: UInt8
    /// The length field of payload-less types (2, 3, 9, 12-15), which is a flag there.
    let flags: UInt16?
    /// Payload length of the other types; nil when the packet ran past the end.
    let length: Int?
    let payload: Data?
}

/// Type 16 packet, big-endian. Durations [spec: probably minutes].
struct SleepSummaryPacket: Equatable, Sendable {
    let ts: Date
    let sleepIndex: Int
    let wakeCount: Int
    let sleepMinutes: Int
    let awakeMinutes: Int
    let lightMinutes: Int
    let remMinutes: Int
    let deepMinutes: Int
    /// Raw; the upstream reading of these bits is doubtful (spec section 6.3.2).
    let flags: UInt8
    let unknownMinutes: Int
}

/// Type 1 packet: one RR interval per byte, 10 ms units.
struct SleepRRPacket: Equatable, Sendable {
    let tsRaw: Int64
    let intervalsMs: [Int]
}

/// ACTIVITY / SLEEP / any detail type.
struct SleepDetails: Equatable, Sendable {
    static let bitmapLengths: [UInt8: Int] = [1: 1, 2: 1, 3: 1, 4: 1, 5: 2, 6: 3]
    /// v6: unknown fields between the second wake time and the HR block.
    static let v6ExtraLength = 24
    static let packetMagic: [UInt8] = [0xFB, 0xFA, 0xFC, 0xFF]
    static let packetHeaderLength = 17
    static let payloadlessPacketTypes: Set<UInt8> = [2, 3, 9, 12, 13, 14, 15, 18, 19]

    let version: UInt8
    let bitmap: [UInt8]
    /// Raw 0/1; which value means "sleep finished" is not settled (spec section 8).
    let isAwake: UInt8
    let bedTime: Date
    let wakeTime: Date
    /// v4+, when its bit is set.
    let sleepQuality: Int?
    /// v5: 9 unknown bytes, then a second bed and wake time.
    let unknownV5: [UInt8]?
    let bedTime2: Date?
    let wakeTime2: Date?
    /// v6: 24 unknown bytes after the second wake time.
    let unknownV6: [UInt8]?
    let heartRate: SleepSampleBlock<Int>?
    let spo2: SleepSampleBlock<Int>?
    /// v3+; float32 up to v5, u16 in v6.
    let snore: SleepSampleBlock<Float>?
    /// v6: the sample blocks did not line up with the packet stream and were dropped.
    let blocksError: String?
    let packets: [SleepPacket]
    /// From type-17 packets, in stream order.
    let stages: [SleepStageSample]
    /// The night's stages: the band re-sends the whole night in a new type-17 packet with the
    /// same ts as it goes (a v6 file had one at 06:59 and the final one at wake), so only the
    /// last packet per ts counts. Ordered by packet ts.
    let nightStages: [SleepStageSample]
    let summaries: [SleepSummaryPacket]
    let rrIntervals: [SleepRRPacket]
    /// Bytes skipped while looking for the packet magic.
    let skippedBytes: Int
    /// Bytes after the last packet (too few for a header, or no magic found).
    let trailingBytes: Int
    /// Set when a packet ran past the end of the file; packets before it are kept.
    let streamError: String?

    /// Minutes come from the last type-16 summary (several can appear; the last one wins), else
    /// from summing the type-17 stage durations, else nil. Nil when bed or wake time is 0 or
    /// the wake time precedes the bed time.
    var session: SleepSession? {
        guard bedTime.timeIntervalSince1970 > 0, wakeTime.timeIntervalSince1970 > 0, wakeTime >= bedTime else { return nil }
        var deep: Int?, light: Int?, rem: Int?, awake: Int?
        if let s = summaries.last {
            deep = s.deepMinutes
            light = s.lightMinutes
            rem = s.remMinutes
            awake = s.awakeMinutes
        } else if !nightStages.isEmpty {
            func total(_ stage: SleepStage) -> Int {
                nightStages.filter { $0.stage == stage }.reduce(0) { $0 + ($1.durationMinutes ?? 0) }
            }
            deep = total(.deep)
            light = total(.light)
            rem = total(.rem)
            awake = total(.awake)
        }
        return SleepSession(bedTime: bedTime, wakeTime: wakeTime, deepMinutes: deep, lightMinutes: light,
                            remMinutes: rem, awakeMinutes: awake, stages: nightStages)
    }

    private static func block<V: Equatable & Sendable>(_ version: UInt8, bedTime: UInt32, _ r: inout ActivityByteReader,
                                 _ read: (inout ActivityByteReader) throws -> V) throws -> SleepSampleBlock<V> {
        let unit = Int(try r.i16())
        let count = Int(try r.i16())
        guard count >= 0 else { throw ActivityParseError.malformed("sleep sample block count \(count)") }
        guard count > 0 else { return SleepSampleBlock(unit: unit, count: 0, firstTs: nil, values: []) }
        let first = version >= 2 ? try r.u32() : bedTime
        var values: [V] = []
        values.reserveCapacity(min(count, r.remaining))
        for _ in 0 ..< count {
            values.append(try read(&r))
        }
        return SleepSampleBlock(unit: unit, count: count, firstTs: unixDate(Int64(first)), values: values)
    }

    static func parse(body: [UInt8], fileID: ActivityFileID, warnings: inout [String]) throws -> SleepDetails {
        let v = fileID.version
        guard let bitmapLength = bitmapLengths[v] else {
            throw ActivityParseError.malformed("sleep details version \(v) unsupported")
        }
        var r = ActivityByteReader(body)
        let bitmap = try r.array(bitmapLength)
        let isAwake = try r.u8()  // bitmap index 0, always present
        let bed = try r.u32()  // index 1
        let wake = try r.u32()  // index 2
        var idx = 3
        var quality: Int?
        if v >= 4 {
            if bitValid(bitmap, idx) { quality = Int(try r.u8()) }  // no byte when the bit is clear
            idx += 1
        }
        var unknownV5: [UInt8]?, bed2: Date?, wake2: Date?
        if v >= 5 {
            unknownV5 = try r.array(9)
            bed2 = unixDate(Int64(try r.u32()))
            wake2 = unixDate(Int64(try r.u32()))
            idx += 5
        }
        var unknownV6: [UInt8]?
        if v >= 6 { unknownV6 = try r.array(v6ExtraLength) }
        let blocksStart = r
        var hr: SleepSampleBlock<Int>?, spo2: SleepSampleBlock<Int>?, snore: SleepSampleBlock<Float>?
        var blocksError: String?
        do {
            if bitValid(bitmap, idx) { hr = try block(v, bedTime: bed, &r) { Int(try $0.u8()) } }
            idx += 1
            if bitValid(bitmap, idx) { spo2 = try block(v, bedTime: bed, &r) { Int(try $0.u8()) } }
            idx += 1
            if v >= 3 {
                if bitValid(bitmap, idx) {
                    snore = try block(v, bedTime: bed, &r) { v >= 6 ? Float(try $0.u16()) : try $0.f32() }
                }
                idx += 1
            }
            if v >= 6, r.remaining > 0, magic(in: body, from: r.position, end: r.end) != r.position {
                throw ActivityParseError.malformed("sample blocks end at offset \(r.position), not at a packet")
            }
        } catch let error as ActivityParseError where v >= 6 {
            // v6 field bits are a guess (spec section 6.3.1); keep the stream rather than lose the night
            blocksError = error.description
            warnings.append("sleep details v6: sample blocks dropped: \(error)")
            hr = nil
            spo2 = nil
            snore = nil
            r = blocksStart
        }

        let stream = scan(body, from: r.position, to: r.end)
        if let error = stream.error { warnings.append("sleep details: \(error)") }
        return SleepDetails(
            version: v, bitmap: bitmap, isAwake: isAwake,
            bedTime: unixDate(Int64(bed)), wakeTime: unixDate(Int64(wake)), sleepQuality: quality,
            unknownV5: unknownV5, bedTime2: bed2, wakeTime2: wake2, unknownV6: unknownV6,
            heartRate: hr, spo2: spo2, snore: snore, blocksError: blocksError,
            packets: stream.packets, stages: stream.stages,
            nightStages: stream.lastStagesByTs.keys.sorted().flatMap { stream.lastStagesByTs[$0] ?? [] },
            summaries: stream.summaries, rrIntervals: stream.rr,
            skippedBytes: stream.skipped, trailingBytes: stream.trailing, streamError: stream.error
        )
    }

    private struct Stream {
        var packets: [SleepPacket] = []
        var stages: [SleepStageSample] = []
        var lastStagesByTs: [Int64: [SleepStageSample]] = [:]
        var summaries: [SleepSummaryPacket] = []
        var rr: [SleepRRPacket] = []
        var skipped = 0
        var trailing = 0
        var error: String?
    }

    /// First magic at or after `from` whose packet header fits before `end`.
    private static func magic(in d: [UInt8], from: Int, end: Int) -> Int? {
        let last = end - packetHeaderLength
        guard from >= 0, from <= last, end <= d.count else { return nil }
        var i = from
        while i <= last {
            if d[i] == 0xFB, d[i + 1] == 0xFA, d[i + 2] == 0xFC, d[i + 3] == 0xFF { return i }
            i += 1
        }
        return nil
    }

    /// Packet: magic FB FA FC FF | header length u8 | ts i64 LE | parity u8 | type u8 |
    /// length u16 BE | payload (big-endian contents).
    private static func scan(_ d: [UInt8], from start: Int, to end: Int) -> Stream {
        var s = Stream()
        var pos = start
        do {
            while end - pos >= packetHeaderLength {
                guard let at = magic(in: d, from: pos, end: end) else { break }
                s.skipped += at - pos
                var h = ActivityByteReader(d, from: at + 4, to: end)
                let headerLength = try h.u8()
                let ts = try h.i64()
                let parity = try h.u8()
                let type = try h.u8()
                let lengthField = try h.u16BE()
                pos = h.position
                if payloadlessPacketTypes.contains(type) {
                    s.packets.append(SleepPacket(type: type, tsRaw: ts, parity: parity, headerLength: headerLength,
                                                 flags: lengthField, length: nil, payload: nil))
                    continue
                }
                let length = Int(lengthField)
                guard length <= end - pos else {
                    s.packets.append(SleepPacket(type: type, tsRaw: ts, parity: parity, headerLength: headerLength,
                                                 flags: nil, length: nil, payload: nil))
                    s.error = "packet type \(type) wants \(length) bytes, \(end - pos) left"
                    pos = end
                    break
                }
                var p = ActivityByteReader(d, from: pos, to: pos + length)
                pos += length
                let payload = Array(d[p.position ..< p.end])
                s.packets.append(SleepPacket(type: type, tsRaw: ts, parity: parity, headerLength: headerLength,
                                             flags: nil, length: length, payload: Data(payload)))
                switch type {
                case 17:  // stages: u16 BE words, stage = top 4 bits, minutes = low 12 bits
                    var t = ts
                    var run: [SleepStageSample] = []
                    while p.remaining >= 2 {
                        let word = try p.u16BE()
                        let code = UInt8(truncatingIfNeeded: word >> 12)
                        let minutes = Int(word & 0x0FFF)
                        run.append(SleepStageSample(ts: unixDate(t), stage: SleepStage(detailsCode: code),
                                                    raw: code, durationMinutes: minutes))
                        t = t &+ Int64(minutes) &* 60
                    }
                    s.stages += run
                    s.lastStagesByTs[ts] = run
                case 16 where length >= 13:  // summary
                    let b0 = try p.u8()
                    s.summaries.append(SleepSummaryPacket(
                        ts: unixDate(ts), sleepIndex: Int(b0 >> 4), wakeCount: Int(b0 & 0x0F),
                        sleepMinutes: Int(try p.u16BE()), awakeMinutes: Int(try p.u16BE()),
                        lightMinutes: Int(try p.u16BE()), remMinutes: Int(try p.u16BE()),
                        deepMinutes: Int(try p.u16BE()), flags: try p.u8(), unknownMinutes: Int(try p.u8())
                    ))
                case 1:  // RR intervals, 10 ms per unit
                    s.rr.append(SleepRRPacket(tsRaw: ts, intervalsMs: payload.map { Int($0) * 10 }))
                default:
                    break
                }
            }
        } catch {
            s.error = String(describing: error)
        }
        s.trailing = max(end - pos, 0)
        return s
    }
}

// MARK: - Sleep stages (spec section 6.4)

/// ACTIVITY / SLEEP_STAGES / DETAILS, version 2 only. Durations are kept raw (i16); the session
/// treats negative ones as missing.
struct SleepStages: Equatable, Sendable {
    let version: UInt8
    /// 7 bytes; the first two are usually FF FF.
    let unknown1: [UInt8]
    let totalMinutes: Int
    let bedTime: Date
    let wakeTime: Date
    let unknown2: [UInt8]
    let deepMinutes: Int
    let lightMinutes: Int
    let remMinutes: Int
    let awakeMinutes: Int
    let unknown3: UInt8
    /// Bed time, wake time or total is 0: the band had nothing to report.
    let noData: Bool
    /// Phase changes; a phase lasts until the next change, the last one until wakeTime.
    let stages: [SleepStageSample]
    let trailingBytes: Int

    var session: SleepSession? {
        guard !noData else { return nil }
        func minutes(_ m: Int) -> Int? { m >= 0 ? m : nil }
        return SleepSession(bedTime: bedTime, wakeTime: wakeTime, deepMinutes: minutes(deepMinutes),
                            lightMinutes: minutes(lightMinutes), remMinutes: minutes(remMinutes),
                            awakeMinutes: minutes(awakeMinutes), stages: stages)
    }

    static func parse(body: [UInt8], fileID: ActivityFileID) throws -> SleepStages {
        guard fileID.version == 2 else {
            throw ActivityParseError.malformed("sleep stages version \(fileID.version) unsupported")
        }
        var r = ActivityByteReader(body)
        let unknown1 = try r.array(7)
        let total = Int(try r.i16())
        let bed = try r.u32()
        let wake = try r.u32()
        let unknown2 = try r.array(3)
        let deep = Int(try r.i16())
        let light = Int(try r.i16())
        let rem = Int(try r.i16())
        let awake = Int(try r.i16())
        let unknown3 = try r.u8()
        var stages: [SleepStageSample] = []
        while r.remaining >= 5 {
            let ts = try r.u32()
            let code = try r.u8()
            stages.append(SleepStageSample(ts: unixDate(Int64(ts)), stage: SleepStage(storedCode: code),
                                           raw: code, durationMinutes: nil))
        }
        return SleepStages(
            version: fileID.version, unknown1: unknown1, totalMinutes: total,
            bedTime: unixDate(Int64(bed)), wakeTime: unixDate(Int64(wake)), unknown2: unknown2,
            deepMinutes: deep, lightMinutes: light, remMinutes: rem, awakeMinutes: awake, unknown3: unknown3,
            noData: bed == 0 || wake == 0 || total == 0, stages: stages, trailingBytes: r.remaining
        )
    }
}

// MARK: - Manual samples (spec section 6.5)

struct ManualSample: Equatable, Sendable {
    enum Kind: String, Sendable {
        case heartRate = "heart_rate"
        case spo2
        case stress
        case temperature
    }

    static let typeHeartRate: UInt8 = 0x11
    static let typeSpO2: UInt8 = 0x12
    static let typeStress: UInt8 = 0x13
    static let typeTemperature: UInt8 = 0x44

    let ts: Date
    /// Version-2 type code (version-1 codes are mapped to these).
    let type: UInt8
    let kind: Kind
    /// Raw value: bpm, %, stress 0-100, or the temperature u32.
    let value: Int

    /// Low 16 bits / 100.
    var celsius: Double? { kind == .temperature ? Double(value & 0xFFFF) / 100 : nil }
    /// High 16 bits of a temperature value; meaning unknown.
    var temperatureHigh16: Int? { kind == .temperature ? value >> 16 : nil }
}

/// ACTIVITY / MANUAL_SAMPLES / DETAILS, versions 1 and 2.
struct ManualSamples: Equatable, Sendable {
    let version: UInt8
    let samples: [ManualSample]
    /// v2 records with value 0, skipped.
    let zeroValueRecords: Int
    /// v2: why parsing stopped early (unknown type, whose length is unknown, or a partial
    /// record); the samples before it are kept.
    let stoppedReason: String?
    /// v2: bytes left unread when parsing stopped early.
    let trailingBytes: Int

    private static func kind(_ type: UInt8) -> ManualSample.Kind? {
        switch type {
        case ManualSample.typeHeartRate: return .heartRate
        case ManualSample.typeSpO2: return .spo2
        case ManualSample.typeStress: return .stress
        case ManualSample.typeTemperature: return .temperature
        default: return nil
        }
    }

    static func parse(body: [UInt8], fileID: ActivityFileID, pad: UInt8, warnings: inout [String]) throws -> ManualSamples {
        var r = ActivityByteReader(body)
        switch fileID.version {
        case 1:
            // Strict, as upstream: any deviation rejects the whole file.
            guard pad == 0 else { throw ActivityParseError.malformed("manual samples v1 pad byte \(hexByte(pad))") }
            guard try r.u8() == 0xFF else { throw ActivityParseError.malformed("manual samples v1 header byte is not 0xff") }
            guard r.remaining > 0, r.remaining % 6 == 0 else {
                throw ActivityParseError.malformed("manual samples v1 payload of \(r.remaining) bytes")
            }
            var samples: [ManualSample] = []
            while r.remaining > 0 {
                let ts = try r.u32()
                let code = try r.u8()
                let value = try r.u8()
                let type: UInt8
                switch code {
                case 0x02: type = ManualSample.typeSpO2
                case 0x03: type = ManualSample.typeStress
                default: throw ActivityParseError.malformed("manual samples v1 type \(hexByte(code))")
                }
                guard (1 ... 100).contains(value) else {
                    throw ActivityParseError.malformed("manual samples v1 value \(value)")
                }
                let k: ManualSample.Kind = type == ManualSample.typeSpO2 ? .spo2 : .stress
                samples.append(ManualSample(ts: unixDate(Int64(ts)), type: type, kind: k, value: Int(value)))
            }
            return ManualSamples(version: 1, samples: samples, zeroValueRecords: 0, stoppedReason: nil, trailingBytes: 0)

        case 2:
            var samples: [ManualSample] = []
            var zero = 0
            var stopped: String?
            var trailing = 0
            records: while r.remaining > 0 {
                let at = r.position
                do {
                    let ts = try r.u32()
                    let type = try r.u8()
                    guard let k = kind(type) else {
                        stopped = "unknown sample type \(hexByte(type)) at payload offset \(at)"
                        trailing = r.end - at
                        break records
                    }
                    let value = try k == .temperature ? Int(r.u32()) : Int(r.u8())
                    if value == 0 {
                        zero += 1
                        continue
                    }
                    samples.append(ManualSample(ts: unixDate(Int64(ts)), type: type, kind: k, value: value))
                } catch {
                    stopped = "partial record of \(r.end - at) byte(s) at payload offset \(at)"
                    trailing = r.end - at
                    break records
                }
            }
            if let stopped { warnings.append("manual samples: \(stopped)") }
            return ManualSamples(version: 2, samples: samples, zeroValueRecords: zero, stoppedReason: stopped, trailingBytes: trailing)

        default:
            throw ActivityParseError.malformed("manual samples version \(fileID.version) unsupported")
        }
    }
}

// MARK: - Dispatch

enum ActivityUnsupported: Equatable, Sendable, CustomStringConvertible {
    /// Workouts and unknown kinds: keep the raw file.
    case kind(ActivityFileKind)
    /// A known kind in a version this module does not know.
    case version(ActivityFileKind, UInt8)

    var description: String {
        switch self {
        case let .kind(kind): return "\(kind.rawValue) files are not parsed"
        case let .version(kind, version): return "\(kind.rawValue) version \(version) is not supported"
        }
    }
}

enum ActivityPayload: Equatable, Sendable {
    case dailyDetails(DailyDetails)
    case dailySummary(DailySummary)
    case sleepDetails(SleepDetails)
    case sleepStages(SleepStages)
    case manualSamples(ManualSamples)
    case unsupported(ActivityUnsupported)
    case error(ActivityParseError)
}

struct ActivityParseResult: Sendable, CustomStringConvertible {
    struct CRCCheck: Equatable, Sendable {
        let stored: UInt32
        let computed: UInt32
        var ok: Bool { stored == computed }
    }

    /// From the file's own first 7 bytes; nil when the file is shorter than that.
    let fileID: ActivityFileID?
    let pad: UInt8?
    /// Nil when parsed without a CRC trailer or when the file was too short to have one.
    let crc: CRCCheck?
    /// Body length: after id and pad, before the CRC.
    let payloadLength: Int
    let payload: ActivityPayload
    let warnings: [String]

    var kind: ActivityFileKind { fileID?.kind ?? .unknown }

    var isParsed: Bool {
        switch payload {
        case .unsupported, .error: return false
        default: return true
        }
    }

    var error: ActivityParseError? {
        if case let .error(e) = payload { return e }
        return nil
    }

    var description: String {
        let id = fileID.map { "\($0.kind.rawValue) v\($0.version)" } ?? "?"
        let body: String
        switch payload {
        case let .dailyDetails(d): body = "\(d.records.count) minute record(s)"
        case let .dailySummary(d): body = "steps \(d.steps.map { String($0) } ?? "-")"
        case let .sleepDetails(d): body = "\(d.stages.count) stage(s), \(d.packets.count) packet(s)"
        case let .sleepStages(d): body = d.noData ? "no data" : "\(d.stages.count) phase change(s)"
        case let .manualSamples(d): body = "\(d.samples.count) sample(s)"
        case let .unsupported(u): body = u.description
        case let .error(e): body = "error: \(e)"
        }
        return warnings.isEmpty ? "\(id): \(body)" : "\(id): \(body) (\(warnings.joined(separator: "; ")))"
    }
}

enum ActivityParser {
    /// A whole file as the assembler returns it: id(7) | pad(1) | body | CRC32 LE(4).
    static func parse(_ file: Data) -> ActivityParseResult {
        parse(file, hasCRC: true, expecting: nil)
    }

    /// hasCRC false parses a file without the trailer (test vectors). With `expecting`, a file
    /// whose own id differs gets a warning; it is still parsed by its own id.
    static func parse(_ file: Data, hasCRC: Bool, expecting expected: ActivityFileID?) -> ActivityParseResult {
        let bytes = [UInt8](file)
        let fileID = bytes.count >= 7 ? ActivityFileID(bytes: bytes[0 ..< 7]) : nil
        let minimum = hasCRC ? ActivityAssembler.minimumFileLength : 8
        guard bytes.count >= minimum, let id = fileID else {
            return ActivityParseResult(fileID: fileID, pad: bytes.count >= 8 ? bytes[7] : nil, crc: nil, payloadLength: 0,
                                       payload: .error(.fileTooShort(length: bytes.count, minimum: minimum)), warnings: [])
        }
        let pad = bytes[7]
        var end = bytes.count
        var crc: ActivityParseResult.CRCCheck?
        if hasCRC, let trailer = ActivityCRC32.trailer(of: bytes) {
            crc = ActivityParseResult.CRCCheck(stored: trailer.stored, computed: trailer.computed)
            end -= 4
        }
        let body = Array(bytes[8 ..< end])
        if let crc, !crc.ok {
            return ActivityParseResult(fileID: id, pad: pad, crc: crc, payloadLength: body.count,
                                       payload: .error(.crcMismatch(stored: crc.stored, computed: crc.computed)), warnings: [])
        }

        var warnings: [String] = []
        if let expected, expected != id {
            warnings.append("file carries id \(id.hex), \(expected.hex) was requested")
        }
        if pad != 0 {
            warnings.append("pad byte \(hexByte(pad)) is not 0")
        }

        let kind = id.kind
        let payload: ActivityPayload
        if kind.supportedVersions.isEmpty {
            payload = .unsupported(.kind(kind))
        } else if !kind.supportedVersions.contains(id.version) {
            payload = .unsupported(.version(kind, id.version))
        } else {
            func run(_ parse: () throws -> ActivityPayload) -> ActivityPayload {
                do {
                    return try parse()
                } catch let error as ActivityParseError {
                    return .error(error)
                } catch {
                    return .error(.malformed(String(describing: error)))
                }
            }
            switch kind {
            case .dailyDetails:
                payload = run { .dailyDetails(try DailyDetails.parse(body: body, fileID: id, warnings: &warnings)) }
            case .dailySummary:
                payload = run { .dailySummary(try DailySummary.parse(body: body, fileID: id)) }
            case .sleepDetails:
                payload = run { .sleepDetails(try SleepDetails.parse(body: body, fileID: id, warnings: &warnings)) }
            case .sleepStages:
                payload = run { .sleepStages(try SleepStages.parse(body: body, fileID: id)) }
            case .manualSamples:
                payload = run { .manualSamples(try ManualSamples.parse(body: body, fileID: id, pad: pad, warnings: &warnings)) }
            case .workoutSummary, .workoutDetails, .workoutGPS, .unknown:
                payload = .unsupported(.kind(kind))
            }
        }
        return ActivityParseResult(fileID: id, pad: pad, crc: crc, payloadLength: body.count, payload: payload, warnings: warnings)
    }
}
