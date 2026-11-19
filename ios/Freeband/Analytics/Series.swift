import Foundation

// Plain value types shared by ingest, analytics and storage. Foundation only, so the analytics
// and ingest harnesses (ios/tests/analytics, ios/tests/ingest) compile them with swiftc.

// MARK: - Local day

/// A calendar day in a fixed UTC offset: the band's own offset from the file id (plan section 5:
/// "gün = dosyanın kendi saat dilimindeki yerel gün"). Stored as days since 1970-01-01 so it can
/// be compared and queried as an Int; `string` is the "yyyy-MM-dd" form used in payloads.
struct DayKey: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    /// Days since 1970-01-01 in the local offset.
    let index: Int

    init(index: Int) { self.index = index }

    /// The local day `date` falls on at `offsetMinutes` east of UTC.
    init(date: Date, offsetMinutes: Int) {
        let local = Int64(date.timeIntervalSince1970.rounded(.down)) + Int64(offsetMinutes) * 60
        index = Int(Self.floorDiv(local, 86_400))
    }

    /// "yyyy-MM-dd"; nil when malformed.
    init?(string: String) {
        let parts = string.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1 ... 12).contains(m), (1 ... 31).contains(d) else { return nil }
        index = Self.daysFromCivil(y, m, d)
    }

    /// Today (or the day of `date`) in the phone's current time zone.
    static func current(_ date: Date = Date(), timeZone: TimeZone = .current) -> DayKey {
        DayKey(date: date, offsetMinutes: timeZone.secondsFromGMT(for: date) / 60)
    }

    func adding(days: Int) -> DayKey { DayKey(index: index + days) }

    /// Local midnight of this day, as an instant.
    func start(offsetMinutes: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(Int64(index) * 86_400 - Int64(offsetMinutes) * 60))
    }

    /// Minute of the day (0..<1440) of `date` in this offset; nil when the date is another day.
    func minute(of date: Date, offsetMinutes: Int) -> Int? {
        let seconds = date.timeIntervalSince(start(offsetMinutes: offsetMinutes))
        guard seconds >= 0, seconds < 86_400 else { return nil }
        return Int(seconds / 60)
    }

    var string: String {
        let c = Self.civil(index)
        return "\(c.y)-\(c.m < 10 ? "0" : "")\(c.m)-\(c.d < 10 ? "0" : "")\(c.d)"
    }

    var description: String { string }

    static func < (a: DayKey, b: DayKey) -> Bool { a.index < b.index }

    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let key = DayKey(string: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad day \(s)"))
        }
        self = key
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(string)
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    /// Howard Hinnant's days_from_civil / civil_from_days (proleptic Gregorian).
    private static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civil(_ days: Int) -> (y: Int, m: Int, d: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }
}

// MARK: - Packed arrays

/// Fixed-width little-endian packing for the 1440-slot minute arrays and the RR series.
/// The all-ones value of the width means "no value": 0xFF for UInt8, 0xFFFF for UInt16.
/// Values are clamped into range (0...254 / 0...65534) before packing.
enum Packed {
    static let none8: UInt8 = 0xFF
    static let none16: UInt16 = 0xFFFF

    static func pack8(_ values: [Int?]) -> Data {
        Data(values.map { v -> UInt8 in
            guard let v else { return none8 }
            return UInt8(clamping: min(max(v, 0), 254))
        })
    }

    static func unpack8(_ data: Data, count: Int? = nil) -> [Int?] {
        var out = data.map { $0 == none8 ? nil : Int($0) } as [Int?]
        if let count { out = resize(out, count) }
        return out
    }

    static func pack16(_ values: [Int?]) -> Data {
        var out = Data(capacity: values.count * 2)
        for v in values {
            let w: UInt16 = v.map { UInt16(clamping: min(max($0, 0), 65_534)) } ?? none16
            out.append(UInt8(w & 0xFF))
            out.append(UInt8(w >> 8))
        }
        return out
    }

    static func unpack16(_ data: Data, count: Int? = nil) -> [Int?] {
        let b = [UInt8](data)
        var out: [Int?] = []
        out.reserveCapacity(b.count / 2)
        var i = 0
        while i + 1 < b.count {
            let w = UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
            out.append(w == none16 ? nil : Int(w))
            i += 2
        }
        if let count { out = resize(out, count) }
        return out
    }

    /// Plain UInt16 LE without a "none" value (RR intervals in ms).
    static func packU16(_ values: [Int]) -> Data {
        var out = Data(capacity: values.count * 2)
        for v in values {
            let w = UInt16(clamping: min(max(v, 0), 65_535))
            out.append(UInt8(w & 0xFF))
            out.append(UInt8(w >> 8))
        }
        return out
    }

    static func unpackU16(_ data: Data) -> [Int] {
        let b = [UInt8](data)
        var out: [Int] = []
        out.reserveCapacity(b.count / 2)
        var i = 0
        while i + 1 < b.count {
            out.append(Int(UInt16(b[i]) | (UInt16(b[i + 1]) << 8)))
            i += 2
        }
        return out
    }

    private static func resize(_ values: [Int?], _ count: Int) -> [Int?] {
        if values.count == count { return values }
        if values.count > count { return Array(values.prefix(count)) }
        return values + Array(repeating: nil, count: count - values.count)
    }

    // Little-endian helpers for the small packed records below.
    static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    static func readLE<T: FixedWidthInteger>(_ type: T.Type, _ bytes: [UInt8], at offset: Int) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset + size <= bytes.count else { return nil }
        var value: T = 0
        for i in 0 ..< size {
            value |= T(truncatingIfNeeded: bytes[offset + i]) << T(truncatingIfNeeded: 8 * i)
        }
        return value
    }
}

// MARK: - Sleep stages

/// Our own stage code (independent of the band's two encodings, ActivityFiles.SleepStage).
enum StageKind: UInt8, Codable, Sendable, CaseIterable {
    case awake = 0, light = 1, deep = 2, rem = 3, notSleep = 4, unknown = 5

    var isSleep: Bool { self == .light || self == .deep || self == .rem }
}

/// One stretch of one stage.
struct StageSegment: Equatable, Codable, Sendable {
    var start: Date
    var minutes: Int
    var stage: StageKind

    var end: Date { start.addingTimeInterval(TimeInterval(minutes * 60)) }

    /// 7 bytes per segment: start u32 (unix s) | minutes u16 | stage u8.
    static func pack(_ segments: [StageSegment]) -> Data {
        var out = Data(capacity: segments.count * 7)
        for s in segments {
            Packed.appendLE(UInt32(clamping: Int64(s.start.timeIntervalSince1970)), to: &out)
            Packed.appendLE(UInt16(clamping: max(s.minutes, 0)), to: &out)
            out.append(s.stage.rawValue)
        }
        return out
    }

    static func unpack(_ data: Data) -> [StageSegment] {
        let b = [UInt8](data)
        var out: [StageSegment] = []
        var i = 0
        while i + 7 <= b.count {
            guard let ts = Packed.readLE(UInt32.self, b, at: i), let m = Packed.readLE(UInt16.self, b, at: i + 4) else { break }
            out.append(StageSegment(start: Date(timeIntervalSince1970: TimeInterval(ts)), minutes: Int(m),
                                    stage: StageKind(rawValue: b[i + 6]) ?? .unknown))
            i += 7
        }
        return out
    }
}

/// A sampled value at a point in time (HR, SpO2 during sleep).
struct TimedValue: Equatable, Codable, Sendable {
    var ts: Date
    var value: Int
}

/// RR intervals that arrived in one packet; `tsRaw` is the packet's i64 time stamp whose unit
/// is not settled (docs/ACTIVITY.md 6.3.2), see HRV.resolveStart.
struct RRSegment: Equatable, Codable, Sendable {
    var tsRaw: Int64
    var intervalsMs: [Int]

    /// Index: 12 bytes per segment, tsRaw i64 | count u32; the intervals go separately as u16.
    static func packIndex(_ segments: [RRSegment]) -> Data {
        var out = Data(capacity: segments.count * 12)
        for s in segments {
            Packed.appendLE(s.tsRaw, to: &out)
            Packed.appendLE(UInt32(clamping: s.intervalsMs.count), to: &out)
        }
        return out
    }

    static func unpack(index: Data, intervals: Data) -> [RRSegment] {
        let b = [UInt8](index)
        let all = Packed.unpackU16(intervals)
        var out: [RRSegment] = []
        var i = 0, cursor = 0
        while i + 12 <= b.count {
            guard let ts = Packed.readLE(Int64.self, b, at: i), let n = Packed.readLE(UInt32.self, b, at: i + 8) else { break }
            let end = min(cursor + Int(n), all.count)
            out.append(RRSegment(tsRaw: ts, intervalsMs: Array(all[cursor ..< end])))
            cursor = end
            i += 12
        }
        return out
    }
}

// MARK: - Valid ranges (plan section 5)

enum ValidRange {
    static let heartRate = 30 ... 220
    static let spo2 = 70 ... 100
    static let stress = 1 ... 100

    static func hr(_ v: Int?) -> Int? { v.flatMap { heartRate.contains($0) ? $0 : nil } }
    static func spo2(_ v: Int?) -> Int? { v.flatMap { spo2.contains($0) ? $0 : nil } }
    static func stress(_ v: Int?) -> Int? { v.flatMap { stress.contains($0) ? $0 : nil } }
}

// MARK: - Analytics inputs

/// One local day of per-minute values, 1440 slots each (nil = no value).
struct MinuteSeries: Equatable, Codable, Sendable {
    static let slots = 1440

    var day: DayKey
    var tzOffsetMinutes: Int
    var steps: [Int?]
    var heartRate: [Int?]
    var spo2: [Int?]
    var stress: [Int?]
    var kcal: [Int?]
    var distance: [Int?]
    var energy: [Int?]
    /// The band's activity level per minute (0 quiet ... 5 severe, 7 on a still wrist).
    var activityLevel: [Int?]

    init(day: DayKey, tzOffsetMinutes: Int) {
        self.day = day
        self.tzOffsetMinutes = tzOffsetMinutes
        let empty = [Int?](repeating: nil, count: Self.slots)
        steps = empty
        heartRate = empty
        spo2 = empty
        stress = empty
        kcal = empty
        distance = empty
        energy = empty
        activityLevel = empty
    }

    /// The band's "Moving" minutes as Mi Fitness counts them: minutes at activity level 3...5.
    /// Nil when no minute of the day carries a level (files parsed before the level was read).
    var movingMinutes: Int? {
        guard activityLevel.contains(where: { $0 != nil }) else { return nil }
        return activityLevel.filter { ($0 ?? 0) >= 3 && ($0 ?? 0) <= 5 }.count
    }

    var start: Date { day.start(offsetMinutes: tzOffsetMinutes) }

    func time(ofMinute i: Int) -> Date { start.addingTimeInterval(TimeInterval(i * 60)) }

    /// A minute "has a record" when the band wrote anything for it.
    func hasRecord(_ i: Int) -> Bool {
        steps[i] != nil || heartRate[i] != nil || kcal[i] != nil || distance[i] != nil || stress[i] != nil || spo2[i] != nil
    }

    var recordCount: Int { (0 ..< Self.slots).filter(hasRecord).count }
    var stepTotal: Int { steps.reduce(0) { $0 + ($1 ?? 0) } }
}

/// One sleep session as analytics sees it.
struct SleepInput: Equatable, Sendable {
    var bedTime: Date
    var wakeTime: Date
    var tzOffsetMinutes: Int
    var deepMinutes: Int?
    var lightMinutes: Int?
    var remMinutes: Int?
    var awakeMinutes: Int?
    var segments: [StageSegment]
    var wakeCount: Int?
    var heartRate: [TimedValue]
    var hrIntervalSeconds: Int
    var spo2: [TimedValue]
    var spo2IntervalSeconds: Int
    var rr: [RRSegment]
    var isNap: Bool

    init(bedTime: Date, wakeTime: Date, tzOffsetMinutes: Int = 0, deepMinutes: Int? = nil, lightMinutes: Int? = nil,
         remMinutes: Int? = nil, awakeMinutes: Int? = nil, segments: [StageSegment] = [], wakeCount: Int? = nil,
         heartRate: [TimedValue] = [], hrIntervalSeconds: Int = 60, spo2: [TimedValue] = [], spo2IntervalSeconds: Int = 60,
         rr: [RRSegment] = [], isNap: Bool = false) {
        self.bedTime = bedTime
        self.wakeTime = wakeTime
        self.tzOffsetMinutes = tzOffsetMinutes
        self.deepMinutes = deepMinutes
        self.lightMinutes = lightMinutes
        self.remMinutes = remMinutes
        self.awakeMinutes = awakeMinutes
        self.segments = segments
        self.wakeCount = wakeCount
        self.heartRate = heartRate
        self.hrIntervalSeconds = hrIntervalSeconds
        self.spo2 = spo2
        self.spo2IntervalSeconds = spo2IntervalSeconds
        self.rr = rr
        self.isNap = isNap
    }

    func contains(_ date: Date) -> Bool { date >= bedTime && date < wakeTime }

    var inBedMinutes: Double { max(wakeTime.timeIntervalSince(bedTime), 0) / 60 }
}

// MARK: - Small statistics

enum Stats {
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// Nearest-rank percentile (p in 0...1): sorted[ceil(p * n) - 1].
    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let rank = Int((p * Double(s.count)).rounded(.up))
        return s[min(max(rank - 1, 0), s.count - 1)]
    }

    /// Linear ramp: x0 maps to 0, x1 maps to 100, clamped; works for falling ramps (x1 < x0) too.
    static func ramp(_ x: Double, from x0: Double, to x1: Double) -> Double {
        guard x1 != x0 else { return x >= x1 ? 100 : 0 }
        return min(max((x - x0) / (x1 - x0) * 100, 0), 100)
    }

    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(max(x, lo), hi) }
}
