import Foundation

// Tests for ios/Freeband/Band/ActivityFiles.swift against the shared activity fixtures.
//
//   cd ios/tests/activity/swift
//   swiftc ../../../Freeband/Band/ActivityFiles.swift main.swift -o /tmp/activity_swift_tests
//   /tmp/activity_swift_tests [FIXTURE_DIR]
//
// Three groups:
//   fixture  every case in ../fixtures/*.json, with the expectations and matching rules of
//            `activity_ref.py --selftest`
//   diff     every case's complete Swift output against `activity_ref.py --dump` (exact key sets
//            and values), plus CRC vectors the reference checks against zlib; needs python3
//   swift    the API contract BandLink codes against, assembler and parser edge cases the
//            reference does not cover, and crash/hang robustness on truncated and random input
//
// Mapping to the reference's shapes: Dates become Unix seconds; the reference raises for an
// unsupported version where Swift returns .unsupported(.version), so both count as an error
// of class "format"; Swift's assembler verifies the CRC itself, so a CRC failure there is the
// reference's CrcMismatch from parse_file.

// MARK: - JSON

indirect enum JSON: Decodable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSON].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSON].self))
        }
    }

    subscript(_ key: String) -> JSON? {
        if case let .object(o) = self { return o[key] }
        return nil
    }

    var string: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    var bool: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }

    var array: [JSON]? {
        if case let .array(a) = self { return a }
        return nil
    }

    var number: Double? {
        switch self {
        case let .int(i): return Double(i)
        case let .double(d): return d
        default: return nil
        }
    }

    var text: String {
        switch self {
        case .null: return "null"
        case let .bool(b): return b ? "true" : "false"
        case let .int(i): return String(i)
        case let .double(d): return String(d)
        case let .string(s): return "\"\(s)\""
        case let .array(a): return "[" + a.map(\.text).joined(separator: ", ") + "]"
        case let .object(o):
            return "{" + o.keys.sorted().map { "\"\($0)\": \(o[$0]?.text ?? "")" }.joined(separator: ", ") + "}"
        }
    }

    var short: String {
        let t = text
        return t.count > 160 ? String(t.prefix(160)) + "..." : t
    }
}

/// Subset match (exact: false) mirrors activity_ref.py `_match`: only the expected keys are
/// checked, lists must have equal length. Exact match also requires equal key sets. Free-text
/// "error" and "blocks_error" messages are compared by presence only.
func match(_ expected: JSON, _ actual: JSON, exact: Bool, path: String = "$") -> [String] {
    switch expected {
    case let .object(e):
        guard case let .object(a) = actual else { return ["\(path): expected object, got \(actual.short)"] }
        var errors: [String] = []
        for key in e.keys.sorted() {
            guard let ev = e[key] else { continue }
            guard let av = a[key] else {
                errors.append("\(path).\(key): missing")
                continue
            }
            if key == "error" || key == "blocks_error", ev.string != nil, av.string != nil { continue }
            errors += match(ev, av, exact: exact, path: "\(path).\(key)")
        }
        if exact {
            for key in a.keys.sorted() where e[key] == nil {
                errors.append("\(path).\(key): unexpected key (\(a[key]?.short ?? ""))")
            }
        }
        return errors
    case let .array(e):
        guard case let .array(a) = actual, a.count == e.count else {
            return ["\(path): expected list of \(e.count), got \(actual.array.map { "\($0.count)" } ?? actual.short)"]
        }
        var errors: [String] = []
        for (i, pair) in zip(e, a).enumerated() {
            errors += match(pair.0, pair.1, exact: exact, path: "\(path)[\(i)]")
        }
        return errors
    case let .int(ei):
        if case let .int(ai) = actual { return ai == ei ? [] : ["\(path): \(ai) != \(ei)"] }
        if let av = actual.number, av == Double(ei) { return [] }
        return ["\(path): \(actual.short) != \(ei)"]
    case let .double(ed):
        guard let av = actual.number, abs(av - ed) <= 1e-6 else { return ["\(path): \(actual.short) != \(ed)"] }
        return []
    default:
        return actual == expected ? [] : ["\(path): \(actual.short) != \(expected.short)"]
    }
}

// MARK: - Byte helpers

func hexData(_ hex: String) -> Data {
    var out: [UInt8] = []
    var high: UInt8?
    for c in hex.utf8 {
        let v: UInt8
        switch c {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): v = c - UInt8(ascii: "0")
        case UInt8(ascii: "a") ... UInt8(ascii: "f"): v = c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A") ... UInt8(ascii: "F"): v = c - UInt8(ascii: "A") + 10
        default: continue
        }
        if let h = high {
            out.append(h << 4 | v)
            high = nil
        } else {
            high = v
        }
    }
    return Data(out)
}

func hex8(_ v: UInt32) -> String {
    let s = String(v, radix: 16)
    return String(repeating: "0", count: max(0, 8 - s.count)) + s
}

func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }

/// id | pad | body | CRC32 LE.
func makeFile(_ id: ActivityFileID, pad: UInt8 = 0, body: [UInt8], crc: Bool = true) -> Data {
    var b = id.bytes + [pad] + body
    if crc { b += le32(ActivityCRC32.checksum(b)) }
    return Data(b)
}

func chunk(_ total: Int, _ num: Int, _ payload: [UInt8]) -> Data {
    Data([UInt8(total & 0xFF), UInt8(total >> 8), UInt8(num & 0xFF), UInt8(num >> 8)] + payload)
}

func chunked(_ file: Data, size: Int) -> [Data] {
    let b = [UInt8](file)
    let parts = stride(from: 0, to: b.count, by: size).map { Array(b[$0 ..< min($0 + size, b.count)]) }
    return parts.enumerated().map { chunk(parts.count, $0.offset + 1, $0.element) }
}

func unix(_ d: Date) -> Int64 { Int64(exactly: d.timeIntervalSince1970.rounded()) ?? Int64.min }

/// Days-from-civil inverse (proleptic Gregorian), UTC.
func civil(_ seconds: Int64) -> (y: Int64, m: Int64, d: Int64, hh: Int64, mm: Int64, ss: Int64) {
    var days = seconds / 86400
    var rem = seconds % 86400
    if rem < 0 {
        rem += 86400
        days -= 1
    }
    let z = days + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d, rem / 3600, rem % 3600 / 60, rem % 60)
}

func pad2(_ v: Int64) -> String { v < 10 ? "0\(v)" : "\(v)" }

func isoUTC(_ seconds: Int64) -> String {
    let c = civil(seconds)
    return "\(c.y)-\(pad2(c.m))-\(pad2(c.d))T\(pad2(c.hh)):\(pad2(c.mm)):\(pad2(c.ss))Z"
}

/// Local calendar date through the library's TimeZone, so that property is under test too.
func localDate(_ id: ActivityFileID) -> String {
    guard let tz = id.timeZone else {
        let c = civil(Int64(id.timestamp) + Int64(id.utcOffsetMinutes) * 60)
        return "\(c.y)-\(pad2(c.m))-\(pad2(c.d))"
    }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    let c = cal.dateComponents([.year, .month, .day], from: id.ts)
    return "\(c.year ?? 0)-\(pad2(Int64(c.month ?? 0)))-\(pad2(Int64(c.day ?? 0)))"
}

// MARK: - Swift results in the reference's JSON shape

func jInt<T: BinaryInteger>(_ v: T) -> JSON { .int(Int64(clamping: v)) }
func jInt<T: BinaryInteger>(_ v: T?) -> JSON { v.map { jInt($0) } ?? .null }
func jTime(_ d: Date) -> JSON { .int(unix(d)) }
func jTime(_ d: Date?) -> JSON { d.map { jTime($0) } ?? .null }
func jHex<S: Sequence>(_ b: S) -> JSON where S.Element == UInt8 { .string(activityHexString(b)) }

func fileIDJSON(_ id: ActivityFileID) -> [String: JSON] {
    let ts = Int64(id.timestamp)
    return [
        "hex": .string(id.hex), "ts": .int(ts), "iso_utc": .string(isoUTC(ts)),
        "tz_quarters": jInt(id.tzQuarterHours), "utc_offset_min": jInt(id.utcOffsetMinutes),
        "local_date": .string(localDate(id)), "version": jInt(id.version),
        "type": jInt(id.type), "type_name": .string(id.typeName),
        "subtype": jInt(id.subtype), "subtype_name": .string(id.subtypeName),
        "detail": jInt(id.detailType), "detail_name": .string(id.detailName),
    ]
}

func blockJSON<V>(_ b: SleepSampleBlock<V>?, _ value: (V) -> JSON) -> JSON {
    guard let b else { return .null }
    return .object(["unit": jInt(b.unit), "count": jInt(b.count), "first_ts": jTime(b.firstTs), "values": .array(b.values.map(value))])
}

func stageJSON(_ s: SleepStageSample) -> [String: JSON] {
    var o: [String: JSON] = ["ts": jTime(s.ts), "stage": .string(s.stage.rawValue), "raw": jInt(s.raw)]
    if let m = s.durationMinutes { o["duration_min"] = jInt(m) }
    return o
}

func dataJSON(_ payload: ActivityPayload) -> JSON {
    switch payload {
    case let .dailyDetails(d):
        var o: [String: JSON] = [
            "header_hex": jHex(d.header),
            "records": .array(d.records.map { r -> JSON in
                var x: [String: JSON] = [
                    "ts": jTime(r.ts), "steps": jInt(r.steps), "active_calories": jInt(r.activeCalories),
                    "distance_m": jInt(r.distanceMeters), "heart_rate": jInt(r.heartRate), "energy": jInt(r.energy),
                    "spo2": jInt(r.spo2), "stress": jInt(r.stress),
                ]
                if let v = r.extraByte { x["extra_byte"] = jInt(v) }
                if let v = r.lightRaw { x["light_raw"] = jInt(v) }
                if let v = r.bodyMomentumRaw { x["body_momentum_raw"] = jInt(v) }
                return .object(x)
            }),
        ]
        if d.truncatedTail > 0 { o["truncated_tail"] = jInt(d.truncatedTail) }
        return .object(o)

    case let .dailySummary(s):
        var o: [String: JSON] = [
            "bitmap_hex": jHex(s.bitmap), "steps": jInt(s.steps), "active_calories": jInt(s.activeCalories),
            "hr_resting": jInt(s.hrResting), "hr_max": jInt(s.hrMax), "hr_max_ts": jTime(s.hrMaxTs),
            "hr_min": jInt(s.hrMin), "hr_min_ts": jTime(s.hrMinTs), "hr_avg": jInt(s.hrAvg),
            "stress_avg": jInt(s.stressAvg), "stress_max": jInt(s.stressMax), "stress_min": jInt(s.stressMin),
            "standing": jInt(s.standing), "calories": jInt(s.calories), "recovery_hours": jInt(s.recoveryHours),
            "spo2_max": jInt(s.spo2Max), "spo2_max_ts": jTime(s.spo2MaxTs), "spo2_min": jInt(s.spo2Min),
            "spo2_min_ts": jTime(s.spo2MinTs), "spo2_avg": jInt(s.spo2Avg),
            "training_load_day": jInt(s.trainingLoadDay), "training_load_week": jInt(s.trainingLoadWeek),
            "training_load_level": jInt(s.trainingLoadLevel), "vitality_light": jInt(s.vitalityIncreaseLight),
            "vitality_moderate": jInt(s.vitalityIncreaseModerate), "vitality_high": jInt(s.vitalityIncreaseHigh),
            "vitality_current": jInt(s.vitalityCurrent),
        ]
        if let h = s.standingHours { o["standing_hours"] = .array(h.map { jInt($0) }) }
        if s.trailingBytes > 0 { o["trailing_bytes"] = jInt(s.trailingBytes) }
        return .object(o)

    case let .sleepDetails(s):
        var o: [String: JSON] = [
            "bitmap_hex": jHex(s.bitmap), "is_awake": jInt(s.isAwake), "bed_time": jTime(s.bedTime),
            "wakeup_time": jTime(s.wakeTime), "sleep_quality": jInt(s.sleepQuality),
            "hr": blockJSON(s.heartRate) { jInt($0) }, "spo2": blockJSON(s.spo2) { jInt($0) },
            "snore": blockJSON(s.snore) { .double(Double($0)) },
            "skipped_bytes": jInt(s.skippedBytes), "trailing_bytes": jInt(s.trailingBytes),
            "packets": .array(s.packets.map { p -> JSON in
                var x: [String: JSON] = ["type": jInt(p.type), "ts": .int(p.tsRaw), "parity": jInt(p.parity), "header_len": jInt(p.headerLength)]
                if let f = p.flags { x["flags"] = jInt(f) }
                if let l = p.length { x["length"] = jInt(l) }
                let decoded = p.type == 17 || p.type == 1 || (p.type == 16 && (p.length ?? 0) >= 13)
                if let payload = p.payload, !decoded { x["payload_hex"] = jHex(payload) }
                return .object(x)
            }),
            "stages": .array(s.stages.map { .object(stageJSON($0)) }),
            "summaries": .array(s.summaries.map { m -> JSON in
                .object([
                    "ts": jTime(m.ts), "sleep_index": jInt(m.sleepIndex), "wake_count": jInt(m.wakeCount),
                    "sleep_min": jInt(m.sleepMinutes), "awake_min": jInt(m.awakeMinutes), "light_min": jInt(m.lightMinutes),
                    "rem_min": jInt(m.remMinutes), "deep_min": jInt(m.deepMinutes), "flags": jInt(m.flags),
                    "unknown_min": jInt(m.unknownMinutes),
                ])
            }),
            "rr": .array(s.rrIntervals.map { .object(["ts_raw": .int($0.tsRaw), "rr_ms": .array($0.intervalsMs.map { jInt($0) })]) }),
        ]
        if s.version >= 5 {
            o["v5_unknown_hex"] = jHex(s.unknownV5 ?? [])
            o["bed_time2"] = jTime(s.bedTime2)
            o["wakeup_time2"] = jTime(s.wakeTime2)
        }
        if s.version >= 6 { o["v6_unknown_hex"] = jHex(s.unknownV6 ?? []) }
        if let e = s.blocksError { o["blocks_error"] = .string(e) }
        if let e = s.streamError { o["error"] = .string(e) }
        return .object(o)

    case let .sleepStages(s):
        var o: [String: JSON] = [
            "unknown1_hex": jHex(s.unknown1), "total_min": jInt(s.totalMinutes), "bed_time": jTime(s.bedTime),
            "wakeup_time": jTime(s.wakeTime), "unknown2_hex": jHex(s.unknown2), "deep_min": jInt(s.deepMinutes),
            "light_min": jInt(s.lightMinutes), "rem_min": jInt(s.remMinutes), "awake_min": jInt(s.awakeMinutes),
            "no_data": .bool(s.noData), "unknown3": jInt(s.unknown3),
            "stages": .array(s.stages.map { .object(stageJSON($0)) }),
        ]
        if s.trailingBytes > 0 { o["trailing_bytes"] = jInt(s.trailingBytes) }
        return .object(o)

    case let .manualSamples(m):
        var o: [String: JSON] = [
            "samples": .array(m.samples.map { s -> JSON in
                var x: [String: JSON] = ["ts": jTime(s.ts), "type": jInt(s.type), "type_name": .string(s.kind.rawValue), "value": jInt(s.value)]
                if let c = s.celsius { x["celsius"] = .double(c) }
                if let h = s.temperatureHigh16 { x["high16"] = jInt(h) }
                return .object(x)
            }),
        ]
        if m.version >= 2 {
            o["zero_value_records"] = jInt(m.zeroValueRecords)
            if let e = m.stoppedReason { o["error"] = .string(e) }
        }
        return .object(o)

    case .unsupported, .error:
        return .null
    }
}

/// Error class in the reference's terms, or nil when the file parsed (or is a raw-only kind).
func errorClass(_ r: ActivityParseResult) -> String? {
    switch r.payload {
    case .error(.crcMismatch): return "crc"
    case .error(.truncated): return "truncated"
    case .error: return "format"
    case .unsupported(.version): return "format"
    default: return nil
    }
}

func resultJSON(_ r: ActivityParseResult) -> JSON {
    if let c = errorClass(r) { return .object(["error_class": .string(c)]) }
    guard let id = r.fileID else { return .object(["error_class": .string("format")]) }
    var crc = JSON.null
    if let c = r.crc { crc = .object(["stored": .string(hex8(c.stored)), "computed": .string(hex8(c.computed)), "ok": .bool(c.ok)]) }
    return .object([
        "file_id": .object(fileIDJSON(id)),
        "kind": .string(id.kind == .unknown ? "unsupported" : id.kind.rawValue),
        "pad": jInt(r.pad), "crc": crc, "payload_len": jInt(r.payloadLength), "data": dataJSON(r.payload),
    ])
}

enum ChunkOutcome {
    case file(Data)
    case failed(ActivityAssemblyError)
    case incomplete
}

func assemble(_ packets: [Data]) -> ChunkOutcome {
    var asm = ActivityAssembler()
    var done: Data?
    for p in packets {
        switch asm.feed(p) {
        case let .success(file?): done = file
        case .success(nil): break
        case let .failure(e): return .failed(e)
        }
    }
    return done.map { .file($0) } ?? .incomplete
}

// MARK: - Fixture cases

/// Same decisions as activity_ref.py `_run_case`.
func runFixtureCase(_ c: JSON) -> [String] {
    let kind = c["kind"]?.string ?? ""
    let expectError = c["expect_error"]?.bool == true
    switch kind {
    case "fileid":
        let raw = hexData(c["hex"]?.string ?? "")
        guard let id = ActivityFileID(raw.prefix(7)) else { return ["id did not decode"] }
        var o = fileIDJSON(id)
        o["is_empty"] = .bool(id.isPlaceholder)
        var errors = match(c["expect"] ?? .object([:]), .object(o), exact: false)
        if c["roundtrip"]?.bool != false, id.data != raw.prefix(7) {
            errors.append("roundtrip \(id.hex) != \(activityHexString(raw.prefix(7)))")
        }
        return errors
    case "idlist":
        let ids = ActivityFileID.list(hexData(c["hex"]?.string ?? ""))
        return match(c["expect"] ?? .array([]), .array(ids.map { .object(fileIDJSON($0)) }), exact: false)
    case "fetch_order":
        let ids = (c["ids"]?.array ?? []).compactMap { ActivityFileID(hexData($0.string ?? "")) }
        let got = ids.sorted().map { JSON.string($0.hex) }
        return got == c["expect"]?.array ? [] : ["order \(JSON.array(got).text) != \(c["expect"]?.text ?? "")"]
    case "crc":
        let got = hex8(ActivityCRC32.checksum(hexData(c["hex"]?.string ?? "")))
        return got == c["expect"]?.string?.lowercased() ? [] : ["crc \(got) != \(c["expect"]?.text ?? "")"]
    case "chunks":
        let packets = (c["chunks"]?.array ?? []).map { hexData($0.string ?? "") }
        switch assemble(packets) {
        case let .failed(e):
            if case .crcMismatch = e { return c["expect_crc_ok"]?.bool == false ? [] : ["\(e)"] }
            return expectError ? [] : ["assembler error: \(e)"]
        case .incomplete:
            return expectError ? ["expected an assembler error"] : ["no complete file"]
        case let .file(file):
            if expectError { return ["expected an assembler error"] }
            var errors: [String] = []
            if let want = c["expect_file_hex"]?.string, activityHexString(file) != want.lowercased() {
                errors.append("reassembled bytes differ")
            }
            if c["expect_crc_ok"]?.bool == false { errors.append("expected a CRC mismatch") }
            return errors + match(c["expect"] ?? .object([:]), resultJSON(ActivityParser.parse(file)), exact: false)
        }
    case "file":
        let r = ActivityParser.parse(hexData(c["hex"]?.string ?? ""), hasCRC: c["has_crc"]?.bool ?? true, expecting: nil)
        let out = resultJSON(r)
        if out["error_class"] != nil { return expectError ? [] : ["error: \(r.payload)"] }
        if expectError { return ["expected an error, got \(out.short)"] }
        return match(c["expect"] ?? .object([:]), out, exact: false)
    default:
        return ["unknown case kind \(kind)"]
    }
}

/// Same shape as activity_ref.py `_dump_case`.
func dumpCase(_ c: JSON) -> JSON {
    switch c["kind"]?.string ?? "" {
    case "fileid":
        guard let id = ActivityFileID(hexData(c["hex"]?.string ?? "").prefix(7)) else { return .object(["error_class": .string("format")]) }
        var o = fileIDJSON(id)
        o["is_empty"] = .bool(id.isPlaceholder)
        o["encoded"] = .string(id.hex)
        return .object(o)
    case "idlist":
        return .array(ActivityFileID.list(hexData(c["hex"]?.string ?? "")).map { .object(fileIDJSON($0)) })
    case "fetch_order":
        return .array((c["ids"]?.array ?? []).compactMap { ActivityFileID(hexData($0.string ?? "")) }.sorted().map { .string($0.hex) })
    case "crc":
        return .string(hex8(ActivityCRC32.checksum(hexData(c["hex"]?.string ?? ""))))
    case "chunks":
        switch assemble((c["chunks"]?.array ?? []).map { hexData($0.string ?? "") }) {
        case let .failed(e):
            switch e {
            case .crcMismatch: return .object(["error_class": .string("crc")])
            case .fileTooShort: return .object(["error_class": .string("format")])
            default: return .object(["error_class": .string("sequence")])
            }
        case .incomplete:
            return .object(["error_class": .string("incomplete")])
        case let .file(file):
            let parsed = resultJSON(ActivityParser.parse(file))
            if parsed["error_class"] != nil { return parsed }
            return .object(["file_hex": jHex(file), "parsed": parsed])
        }
    case "file":
        return resultJSON(ActivityParser.parse(hexData(c["hex"]?.string ?? ""), hasCRC: c["has_crc"]?.bool ?? true, expecting: nil))
    default:
        return .object(["error_class": .string("unknown case kind")])
    }
}

// MARK: - Runner

struct Tally {
    var passed = 0
    var failed = 0
}

var tallies: [String: Tally] = [:]
var groupOrder: [String] = []
var notes: [String] = []

func record(_ group: String, _ name: String, _ errors: [String]) {
    if tallies[group] == nil {
        tallies[group] = Tally()
        groupOrder.append(group)
    }
    if errors.isEmpty {
        tallies[group, default: Tally()].passed += 1
        print("ok   \(group) :: \(name)")
    } else {
        tallies[group, default: Tally()].failed += 1
        print("FAIL \(group) :: \(name)")
        for e in errors.prefix(8) { print("     \(e)") }
    }
}

func check(_ name: String, _ body: () -> [String]) { record("swift", name, body()) }

func expect(_ condition: Bool, _ message: @autoclosure () -> String) -> [String] { condition ? [] : [message()] }

let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let fixtureDir: URL = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], relativeTo: cwd).standardizedFileURL
    : URL(fileURLWithPath: #filePath, relativeTo: cwd).deletingLastPathComponent()
        .appendingPathComponent("../fixtures", isDirectory: true).standardizedFileURL
let referenceScript = fixtureDir.deletingLastPathComponent().appendingPathComponent("activity_ref.py")

let fixtureFiles = ((try? FileManager.default.contentsOfDirectory(atPath: fixtureDir.path)) ?? [])
    .filter { $0.hasSuffix(".json") }.sorted()
guard !fixtureFiles.isEmpty else {
    print("no fixtures in \(fixtureDir.path)")
    exit(2)
}

var fixtureCases: [(file: String, name: String, json: JSON)] = []
for file in fixtureFiles {
    guard let data = FileManager.default.contents(atPath: fixtureDir.appendingPathComponent(file).path),
          let suite = try? JSONDecoder().decode(JSON.self, from: data) else {
        print("cannot read \(file)")
        exit(2)
    }
    for c in suite["cases"]?.array ?? [] {
        fixtureCases.append((file, c["name"]?.string ?? "?", c))
    }
}

func fixture(_ prefix: String) -> JSON? { fixtureCases.first { $0.name.hasPrefix(prefix) }?.json }
func fixtureBytes(_ prefix: String) -> Data { hexData(fixture(prefix)?["hex"]?.string ?? "") }

// MARK: fixture group

for c in fixtureCases {
    record("fixture", "\(c.file) :: \(c.name)", runFixtureCase(c.json))
}

// MARK: diff group

func runReferenceDump() -> JSON? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["python3", "-I", referenceScript.path, "--dump", fixtureDir.path]
    let out = Pipe()
    p.standardOutput = out
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return try? JSONDecoder().decode(JSON.self, from: data)
}

if let reference = runReferenceDump() {
    for v in reference["crc_vectors"]?.array ?? [] {
        let blob = hexData(v["hex"]?.string ?? "")
        let got = hex8(ActivityCRC32.checksum(blob))
        record("diff", "crc32 of \(blob.count) bytes vs zlib", expect(got == v["crc"]?.string, "\(got) != \(v["crc"]?.text ?? "")"))
    }
    let refCases = reference["cases"]?.array ?? []
    if refCases.count != fixtureCases.count {
        record("diff", "reference case count", ["reference has \(refCases.count), fixtures \(fixtureCases.count)"])
    }
    for (c, ref) in zip(fixtureCases, refCases) {
        guard ref["name"]?.string == c.name else {
            record("diff", "\(c.file) :: \(c.name)", ["reference case is \(ref["name"]?.text ?? "?")"])
            continue
        }
        record("diff", "\(c.file) :: \(c.name)", match(ref["output"] ?? .null, dumpCase(c.json), exact: true))
    }
} else {
    notes.append("diff group skipped: `python3 -I \(referenceScript.path) --dump` did not run")
}

// MARK: swift group: file id

check("CRC-32 check value '123456789' = cbf43926, empty input = 0") {
    expect(ActivityCRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926, "check value")
        + expect(ActivityCRC32.checkValue == 0xCBF4_3926, "constant")
        + expect(ActivityCRC32.checksum([UInt8]()) == 0, "empty")
}

check("file id 21F328650403A0: SPORTS/FREESTYLE/DETAILS v3, tz +1h") {
    guard let id = ActivityFileID(hexData("21F328650403A0")) else { return ["nil"] }
    return expect(id.timestamp == 1_697_182_497 && id.ts == Date(timeIntervalSince1970: 1_697_182_497), "ts")
        + expect(id.tzQuarterHours == 4 && id.utcOffsetMinutes == 60 && id.timeZone?.secondsFromGMT() == 3600, "tz")
        + expect(id.version == 3 && id.type == 1 && id.subtype == 8 && id.detailType == 0, "fields")
        + expect(id.sport == .freestyle && id.kind == .workoutDetails && id.subtypeName == "freestyle", "kind")
        + expect(id.hex == "21f328650403a0" && id.data == hexData("21F328650403A0"), "encode \(id.hex)")
        + expect(!id.isPlaceholder, "placeholder")
}

check("file id 21F3286504008C: SPORTS/TREADMILL v0 round-trips") {
    guard let id = ActivityFileID(hexData("21F3286504008C")) else { return ["nil"] }
    return expect(id.subtype == 3 && id.sport == .treadmill && id.version == 0 && id.detailType == 0, "fields")
        + expect(id.hex == "21f3286504008c", "encode \(id.hex)") + expect(!id.isPlaceholder, "ts != 0 is not a placeholder")
}

check("file id 00000000000000 is a placeholder") {
    guard let id = ActivityFileID(Data(count: 7)) else { return ["nil"] }
    return expect(id.isPlaceholder && id.kind == .dailyDetails && id.hex == "00000000000000", "\(id)")
}

check("encoder masks out-of-range fields (type 3, subtype 0x23, detail 8 -> 8c)") {
    let id = ActivityFileID(timestamp: 1_697_182_497, tzQuarterHours: 4, version: 0, type: 3, subtype: 0x23, detailType: 8)
    return expect(id.type == 1 && id.subtype == 3 && id.detailType == 0, "masked fields")
        + expect(id.hex == "21f3286504008c", id.hex)
        + expect(id == ActivityFileID(hexData("21F3286504008C")), "equal to the decoded id")
}

check("tz -12 encodes as f4 (UTC-3)") {
    let id = ActivityFileID(timestamp: 0x6A85_B9EF, tzQuarterHours: -12, version: 1, type: 0, subtype: 6, detailType: 0)
    return expect(id.bytes[4] == 0xF4 && id.utcOffsetMinutes == -180, "tz byte")
        + expect(id.timeZone?.secondsFromGMT() == -10800, "timeZone")
        + expect(ActivityFileID(id.data) == id && id.kind == .manualSamples, "round trip")
}

check("init? wants exactly 7 bytes and accepts a Data slice") {
    let raw = hexData("ffff21F328650403A0ee")
    let slice = raw[raw.startIndex + 2 ..< raw.startIndex + 9]
    return expect(ActivityFileID(Data()) == nil && ActivityFileID(Data(count: 6)) == nil && ActivityFileID(Data(count: 8)) == nil, "length")
        + expect(ActivityFileID(slice)?.hex == "21f328650403a0", "slice")
        + expect(ActivityFileID(raw.dropFirst(2).prefix(7))?.hex == "21f328650403a0", "dropFirst slice")
}

check("list: N x 7 bytes, placeholders dropped, bad length -> []") {
    let two = hexData("21F328650403A0" + "00000000000000" + "21F3286504008C")
    return expect(ActivityFileID.list(two).map(\.hex) == ["21f328650403a0", "21f3286504008c"], "list")
        + expect(ActivityFileID.list(Data()).isEmpty, "empty")
        + expect(ActivityFileID.list(two.dropLast()).isEmpty, "length 20")
        + expect(ActivityFileID.list(two.dropFirst(7)).count == 1, "slice input")
}

check("Set dedupes ids across lists and sorted() is the fetch order") {
    let ids = ["5068ed680c0402", "5068ed680c0400", "5068ed680c0401", "ec67ed680c0521", "5068ed680c0400"]
        .compactMap { ActivityFileID(hexData($0)) }
    let today = Array(ids.prefix(3)), past = Array(ids.suffix(3))
    let queue = Array(Set(today + past)).sorted()
    let tz = ActivityFileID(timestamp: 100, tzQuarterHours: -4, version: 1, type: 0, subtype: 0, detailType: 0)
    let tzLater = ActivityFileID(timestamp: 100, tzQuarterHours: 4, version: 1, type: 0, subtype: 0, detailType: 0)
    let v1 = ActivityFileID(timestamp: 100, version: 1, type: 0, subtype: 0, detailType: 3)
    let v2 = ActivityFileID(timestamp: 100, version: 2, type: 0, subtype: 0, detailType: 3)
    return expect(queue.map(\.hex) == ["ec67ed680c0521", "5068ed680c0401", "5068ed680c0400", "5068ed680c0402"], queue.map(\.hex).joined(separator: " "))
        + expect(tz < tzLater && v1 < v2 && !(v2 < v1), "tz and version tie-breakers")
}

check("kind mapping for every type/subtype/detail") {
    func kind(_ t: UInt8, _ s: UInt8, _ d: UInt8) -> ActivityFileKind {
        ActivityFileID(timestamp: 1, version: 1, type: t, subtype: s, detailType: d).kind
    }
    var e: [String] = []
    e += expect(kind(0, 0, 0) == .dailyDetails && kind(0, 0, 1) == .dailySummary && kind(0, 0, 2) == .unknown, "daily")
    e += expect(kind(0, 3, 0) == .sleepStages && kind(0, 3, 1) == .unknown, "sleep stages")
    e += expect(kind(0, 6, 0) == .manualSamples && kind(0, 6, 1) == .unknown, "manual")
    e += expect((0 ... 3).allSatisfy { kind(0, 8, UInt8($0)) == .sleepDetails }, "sleep, every detail type")
    e += expect(kind(1, 8, 0) == .workoutDetails && kind(1, 8, 1) == .workoutSummary && kind(1, 8, 2) == .workoutGPS && kind(1, 8, 3) == .unknown, "sports")
    e += expect(kind(0, 0x1F, 0) == .unknown, "unknown activity subtype")
    let unknown = ActivityFileID(timestamp: 1, version: 1, type: 0, subtype: 0x1F, detailType: 3)
    e += expect(unknown.subtypeName == "unknown_1f" && unknown.detailName == "unknown", unknown.description)
    e += expect(ActivityFileID.Sport.allCases.count == 13, "13 sports")
    return e
}

// MARK: swift group: assembler

let manualV1File = fixtureBytes("v1 SpO2 97")

check("contract: add() gives needMore, needMore, complete(file) with CRC verified") {
    var asm = ActivityAssembler()
    let packets = chunked(manualV1File, size: 8)
    let events = packets.map { asm.add($0) }
    return expect(packets.count == 3, "\(packets.count) chunks")
        + expect(events == [.needMore, .needMore, .complete(manualV1File)], "\(events)")
        + expect(!asm.isAssembling && asm.progress == nil, "idle after completion")
}

check("assembler: progress while assembling, reset() drops the file") {
    var asm = ActivityAssembler()
    let packets = chunked(manualV1File, size: 8)
    _ = asm.add(packets[0])
    let progress = asm.progress
    asm.reset()
    let afterReset = asm.add(packets[1])
    return expect(progress?.received == 1 && progress?.total == 3, "progress \(String(describing: progress))")
        + expect(afterReset == .failed(ActivityAssemblyError.unexpectedChunk(num: 2, total: 3, expected: 1).description), "\(afterReset)")
}

check("assembler: a gap fails the file") {
    var asm = ActivityAssembler()
    let p = chunked(manualV1File, size: 8)
    _ = asm.feed(p[0])
    let r = asm.feed(p[2])
    return expect(r == .failure(.unexpectedChunk(num: 3, total: 3, expected: 2)), "\(r)")
}

check("assembler: a duplicate chunk fails the file") {
    var asm = ActivityAssembler()
    let p = chunked(manualV1File, size: 8)
    _ = asm.feed(p[0])
    _ = asm.feed(p[1])
    let r = asm.feed(p[1])
    return expect(r == .failure(.unexpectedChunk(num: 2, total: 3, expected: 3)), "\(r)")
}

check("assembler: a change of total fails the file") {
    var asm = ActivityAssembler()
    _ = asm.feed(chunk(3, 1, [1, 2, 3]))
    let r = asm.feed(chunk(4, 2, [4, 5, 6]))
    return expect(r == .failure(.totalChanged(num: 2, total: 4, expectedTotal: 3)), "\(r)")
}

check("assembler: a chunk with no file in progress fails") {
    var asm = ActivityAssembler()
    let r = asm.feed(chunk(3, 2, [1]))
    return expect(r == .failure(.unexpectedChunk(num: 2, total: 3, expected: 1)), "\(r)")
}

check("assembler: num 1 in the middle of a file starts over") {
    var asm = ActivityAssembler()
    _ = asm.feed(chunk(3, 1, [9, 9, 9]))
    _ = asm.feed(chunk(3, 2, [9, 9, 9]))
    let p = chunked(manualV1File, size: 10)
    let a = asm.feed(p[0]), b = asm.feed(p[1])
    return expect(a == .success(nil) && b == .success(manualV1File), "\(a) \(b)")
}

check("assembler: total 0, packet without header, file under 13 bytes, CRC mismatch") {
    var asm = ActivityAssembler()
    var e: [String] = []
    e += expect(asm.feed(chunk(0, 1, [1, 2])) == .failure(.zeroTotal), "zero total")
    _ = asm.feed(chunk(2, 1, [1]))
    e += expect(asm.feed(Data([2, 0, 2])) == .failure(.packetTooShort(length: 3)), "short packet")
    e += expect(!asm.isAssembling, "short packet drops the file")
    let tiny = makeFile(ActivityFileID(timestamp: 1, version: 1, type: 0, subtype: 0, detailType: 0), body: [])
    e += expect(asm.feed(chunk(1, 1, Array(tiny))) == .failure(.fileTooShort(length: 12)), "12-byte file")
    var bad = [UInt8](manualV1File)
    bad[10] ^= 0x01
    let crc = ActivityCRC32.trailer(of: bad)
    let r = asm.feed(chunk(1, 1, bad))
    e += expect(r == .failure(.crcMismatch(stored: crc?.stored ?? 0, computed: crc?.computed ?? 0)) && crc?.stored != crc?.computed, "\(r)")
    e += expect(asm.add(chunk(1, 1, bad)) == .failed(ActivityAssemblyError.crcMismatch(stored: crc?.stored ?? 0, computed: crc?.computed ?? 0).description), "add() failed(String)")
    return e
}

check("assembler: size limit, and recovery with the next num 1") {
    var asm = ActivityAssembler(maxFileSize: 15)
    let p = chunked(manualV1File, size: 8)  // 19 bytes
    let first = asm.feed(p[0])
    let over = asm.feed(p[1])
    let small = makeFile(ActivityFileID(timestamp: 1, version: 2, type: 0, subtype: 6, detailType: 0), body: [0])  // 13 bytes
    let recovered = chunked(small, size: 5).map { asm.feed($0) }.last
    var exact = ActivityAssembler(maxFileSize: manualV1File.count)
    let fits = chunked(manualV1File, size: 8).map { exact.feed($0) }.last
    return expect(first == .success(nil) && over == .failure(.fileTooLarge(limit: 15)) && !asm.isAssembling, "\(first) \(over)")
        + expect(recovered == .success(small), "recovery: \(String(describing: recovered))")
        + expect(fits == .success(manualV1File), "a file of exactly the limit")
}

// MARK: swift group: parser

func parsed(_ file: Data, crc: Bool = true, expecting: ActivityFileID? = nil) -> ActivityParseResult {
    ActivityParser.parse(file, hasCRC: crc, expecting: expecting)
}

let ddV4 = fixtureBytes("daily details v4")
let ddV2 = fixtureBytes("daily details v2")
let sleepV5 = fixtureBytes("sleep details v5")
let sleepV2 = fixtureBytes("sleep details v2")
let sleepV6 = fixtureBytes("sleep details v6 (")
let sleepV6Misaligned = fixtureBytes("sleep details v6, snore bit set")
let summaryV5Short = fixtureBytes("daily summary v5 ending after slot 29")
let stagesV2 = fixtureBytes("sleep stages v2, five")
let stagesNoData = fixtureBytes("sleep stages v2 with no data")
let manualV2 = fixtureBytes("manual samples v2")
let summaryV5 = fixtureBytes("v5 all bits set")

/// Body of a fixture file that carries a CRC.
func body(_ file: Data) -> [UInt8] { Array([UInt8](file).dropFirst(8).dropLast(4)) }
func fid(_ file: Data) -> ActivityFileID? { ActivityFileID(file.prefix(7)) }

check("parse(_:) checks the CRC; parse(hasCRC: false) reads a trailer-less file") {
    let r = ActivityParser.parse(ddV4)
    let noCRC = parsed(summaryV5, crc: false)
    let withCRC = parsed(summaryV5)
    return expect(r.isParsed && r.crc?.ok == true && r.warnings.isEmpty && r.kind == .dailyDetails, r.description)
        + expect(noCRC.isParsed && noCRC.crc == nil, noCRC.description)
        + expect(withCRC.error != nil, "a trailer-less file read as having a CRC must fail: \(withCRC.description)")
}

check("CRC mismatch is an error and the result keeps the id") {
    var b = [UInt8](ddV4)
    b[9] ^= 0x40
    let r = parsed(Data(b))
    guard case .error(.crcMismatch) = r.payload else { return ["\(r.payload)"] }
    return expect(r.crc?.ok == false && r.fileID == fid(ddV4), "crc/id")
}

check("files under the minimum length are errors, never traps") {
    var e: [String] = []
    for n in 0 ..< 13 {
        let r = parsed(ddV4.prefix(n))
        guard case .error(.fileTooShort(n, 13)) = r.payload else { e.append("length \(n): \(r.payload)"); continue }
        e += expect((r.fileID == nil) == (n < 7), "length \(n) id")
    }
    let r = parsed(Data([1, 2, 3, 4, 5, 6, 7]), crc: false)
    e += expect(r.error == .fileTooShort(length: 7, minimum: 8), "no-CRC minimum")
    return e
}

check("requested id differs from the file's own id: warning, parsed by its own id") {
    let other = ActivityFileID(timestamp: 1, version: 4, type: 0, subtype: 0, detailType: 0)
    let r = parsed(ddV4, expecting: other)
    let same = parsed(ddV4, expecting: fid(ddV4))
    return expect(r.isParsed && r.warnings.count == 1 && r.fileID == fid(ddV4), r.description)
        + expect(same.warnings.isEmpty, same.description)
}

check("pad byte != 0 warns but parses (except manual samples v1)") {
    guard let id = fid(ddV4) else { return ["id"] }
    let r = parsed(makeFile(id, pad: 0x55, body: body(ddV4)))
    var v1 = [UInt8](manualV1File)
    v1[7] = 1
    let rejected = parsed(makeFile(ActivityFileID(bytes: v1[0 ..< 7]) ?? id, pad: 1, body: Array(v1[8 ..< v1.count - 4])))
    return expect(r.isParsed && r.warnings.contains { $0.contains("pad") }, r.description)
        + expect(rejected.error != nil, rejected.description)
}

check("workouts and unknown kinds are .unsupported(.kind), with the envelope checked") {
    var e: [String] = []
    for (t, s, d, k) in [(UInt8(1), UInt8(8), UInt8(1), ActivityFileKind.workoutSummary), (1, 3, 0, .workoutDetails),
                         (1, 23, 2, .workoutGPS), (1, 23, 3, .unknown), (0, 0x1F, 0, .unknown), (0, 0, 2, .unknown)] {
        let id = ActivityFileID(timestamp: 1_760_000_000, version: 9, type: t, subtype: s, detailType: d)
        let r = parsed(makeFile(id, body: [1, 2, 3]))
        e += expect(r.payload == .unsupported(.kind(k)) && r.crc?.ok == true && r.payloadLength == 3, "\(id): \(r.payload)")
    }
    return e
}

check("unknown versions of every parsed kind are .unsupported(.version)") {
    var e: [String] = []
    for (s, d, k) in [(UInt8(0), UInt8(0), ActivityFileKind.dailyDetails), (0, 1, .dailySummary), (8, 1, .sleepDetails),
                      (3, 0, .sleepStages), (6, 0, .manualSamples)] {
        for v: UInt8 in [0, 6, 99, 255] where !k.supportedVersions.contains(v) {
            let id = ActivityFileID(timestamp: 1, version: v, type: 0, subtype: s, detailType: d)
            let r = parsed(makeFile(id, body: Array(repeating: 0xFF, count: 40)))
            e += expect(r.payload == .unsupported(.version(k, v)), "\(id): \(r.payload)")
        }
    }
    return e
}

check("daily details: every prefix keeps the whole records before the cut") {
    guard case let .dailyDetails(full) = parsed(ddV4).payload else { return ["full parse"] }
    let all = [UInt8](ddV4.dropLast(4))
    var e: [String] = []
    var boundary = 8 + 6  // end of the last whole record seen so far
    var seen = 0
    for n in 8 ... all.count {
        let r = parsed(Data(all.prefix(n)), crc: false)
        if n < 8 + 6 {
            e += expect(r.error != nil, "prefix \(n) has no full header but parsed")
            continue
        }
        guard case let .dailyDetails(d) = r.payload else { e.append("prefix \(n): \(r.payload)"); continue }
        let records = Array(full.records.prefix(d.records.count))
        e += expect(d.records == records, "prefix \(n): records differ")
        if d.records.count > seen {
            seen = d.records.count
            boundary = n
        }
        e += expect(d.truncatedTail == n - boundary, "prefix \(n): tail \(d.truncatedTail), expected \(n - boundary)")
        e += expect((d.truncatedTail > 0) == !r.warnings.isEmpty, "prefix \(n): warning")
    }
    return e + expect(seen == full.records.count && boundary == all.count, "full file: \(seen) records, last boundary \(boundary)")
}

check("daily details: header with no group present stops instead of looping") {
    let id = ActivityFileID(timestamp: 1_760_000_000, version: 4, type: 0, subtype: 0, detailType: 0)
    let r = parsed(makeFile(id, body: [0, 0, 0, 0, 0, 0] + Array(repeating: 7, count: 10)))
    guard case let .dailyDetails(d) = r.payload else { return ["\(r.payload)"] }
    return expect(d.records.isEmpty && d.truncatedTail == 10 && r.warnings.count == 1, r.description)
}

check("daily details v2: record times are ts + 60 s * index") {
    guard case let .dailyDetails(d) = parsed(ddV2).payload, let id = fid(ddV2) else { return ["parse"] }
    return expect(d.records.enumerated().allSatisfy { $0.element.ts == id.ts.addingTimeInterval(60 * Double($0.offset)) }, "times")
}

check("daily summary accessors (v5 all bits set)") {
    guard case let .dailySummary(s) = parsed(summaryV5, crc: false).payload else { return ["parse"] }
    return expect(s.steps == 12345 && s.calories == 2200 && s.hrResting == 60 && s.hrAvg == 80, "values")
        + expect(s.hrMaxTs == Date(timeIntervalSince1970: 1_700_001_000) && s.spo2MinTs == Date(timeIntervalSince1970: 1_700_004_000), "times")
        + expect(s.standingHours == [0, 8, 16] && s.vitalityCurrent == 280 && s.slots.count == 32, "standing \(String(describing: s.standingHours))")
        + expect(s.day == fid(summaryV5)?.ts && s.tzQuarterHours == 4, "day")
}

check("sleep details v5: session minutes from the type-16 summary, stages with durations") {
    guard case let .sleepDetails(s) = parsed(sleepV5).payload, let session = s.session else { return ["parse"] }
    return expect(session.deepMinutes == 45 && session.lightMinutes == 70 && session.remMinutes == 20 && session.awakeMinutes == 5, "\(session)")
        + expect(session.stages.map(\.stage) == [.light, .deep, .rem, .awake, .light] && session.bedTime == s.bedTime, "stages")
        + expect(s.heartRate?.samples.map(\.value) == [58, 55, 60] && s.heartRate?.samples.last?.ts == Date(timeIntervalSince1970: 1_760_469_720), "hr samples")
}

check("sleep details v2: without a summary, minutes are summed from stage durations") {
    guard case let .sleepDetails(s) = parsed(sleepV2).payload, let session = s.session else { return ["parse"] }
    return expect(session.deepMinutes == 50 && session.lightMinutes == 60 && session.remMinutes == 0 && session.awakeMinutes == 0, "\(session)")
}

check("sleep details v6: the night sent twice counts once, from the last packet") {
    guard case let .sleepDetails(s) = parsed(sleepV6).payload, let session = s.session else { return ["parse"] }
    return expect(s.stages.count == 11 && s.nightStages.count == 7, "stages \(s.stages.count) night \(s.nightStages.count)")
        + expect(session.stages == s.nightStages && session.stages.map(\.stage) == [.light, .deep, .rem, .light, .awake, .deep, .rem], "session stages")
        + expect(session.lightMinutes == 115 && session.deepMinutes == 30 && session.remMinutes == 15 && session.awakeMinutes == 20, "\(session)")
        + expect(s.snore?.values == [57, 45] && s.blocksError == nil && s.unknownV6?.count == 24, "blocks")
}

check("sleep details v6: misaligned sample blocks are dropped with a warning, the night is kept") {
    let r = parsed(sleepV6Misaligned)
    guard case let .sleepDetails(s) = r.payload, let session = s.session else { return ["\(r.payload)"] }
    return expect(s.heartRate == nil && s.spo2 == nil && s.snore == nil && s.blocksError != nil, "blocks")
        + expect(session.lightMinutes == 115 && s.nightStages.count == 7 && s.skippedBytes > 0, "night")
        + expect(r.warnings.contains { $0.contains("sample blocks dropped") }, r.description)
}

check("daily summary v5 ending after slot 29: slots 30-31 nil, nothing trailing") {
    guard case let .dailySummary(s) = parsed(summaryV5Short).payload else { return ["parse"] }
    return expect(s.steps == 12345 && s.vitalityCurrent == 280 && s.slots[30] == nil && s.slots[31] == nil && s.trailingBytes == 0, "values")
}

check("sleep details: a packet longer than the file keeps the packets before it") {
    guard let id = fid(sleepV5), case let .sleepDetails(full) = parsed(sleepV5).payload else { return ["parse"] }
    let extra: [UInt8] = [0xFB, 0xFA, 0xFC, 0xFF, 17] + [UInt8](repeating: 0, count: 8) + [0, 17, 0x01, 0x00, 0x10, 0x20]
    let r = parsed(makeFile(id, pad: 0x21, body: body(sleepV5) + extra))
    guard case let .sleepDetails(s) = r.payload else { return ["\(r.payload)"] }
    return expect(s.stages == full.stages && s.packets.count == full.packets.count + 1, "kept")
        + expect(s.streamError != nil && s.trailingBytes == 0 && r.warnings.contains { $0.contains("wants 256") }, r.description)
}

check("sleep stages: session from the file, none when there is no data") {
    guard case let .sleepStages(s) = parsed(stagesV2).payload, let session = s.session,
          case let .sleepStages(empty) = parsed(stagesNoData).payload else { return ["parse"] }
    return expect(session.deepMinutes == 90 && session.lightMinutes == 240 && session.stages.count == 5 && session.wakeTime == s.wakeTime, "\(session)")
        + expect(empty.noData && empty.session == nil, "no data")
}

check("SleepSession.merge keeps the latest wake time per bed time") {
    func session(_ bed: Double, _ wake: Double) -> SleepSession {
        SleepSession(bedTime: Date(timeIntervalSince1970: bed), wakeTime: Date(timeIntervalSince1970: wake),
                     deepMinutes: nil, lightMinutes: nil, remMinutes: nil, awakeMinutes: nil, stages: [])
    }
    let merged = SleepSession.merge([session(100, 200), session(50, 60), session(100, 400), session(100, 300)])
    return expect(merged == [session(50, 60), session(100, 400)], "\(merged.map { ($0.bedTime.timeIntervalSince1970, $0.wakeTime.timeIntervalSince1970) })")
}

check("manual samples v2: partial trailing record and unknown type keep earlier samples") {
    guard let id = fid(manualV2), case let .manualSamples(full) = parsed(manualV2).payload else { return ["parse"] }
    let partial = parsed(makeFile(id, body: body(manualV2) + [1, 2, 3]))
    let unknown = parsed(makeFile(id, body: body(manualV2) + [1, 2, 3, 4, 0x99, 5, 6]))
    guard case let .manualSamples(p) = partial.payload, case let .manualSamples(u) = unknown.payload else { return ["parse"] }
    return expect(p.samples == full.samples && p.trailingBytes == 3 && p.stoppedReason != nil && !partial.warnings.isEmpty, partial.description)
        + expect(u.samples == full.samples && u.trailingBytes == 7 && (u.stoppedReason ?? "").contains("0x99"), unknown.description)
        + expect(full.samples.compactMap(\.celsius) == [36.74, 36.73] && full.samples.first?.kind == .spo2, "values")
}

// MARK: swift group: robustness

struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func below(_ n: Int) -> Int { n <= 1 ? 0 : Int(next() % UInt64(n)) }
    mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
    mutating func bytes(_ n: Int) -> [UInt8] { (0 ..< n).map { _ in byte() } }
}

let fixtureFilesBytes: [Data] = fixtureCases.compactMap { c in
    c.json["kind"]?.string == "file" ? hexData(c.json["hex"]?.string ?? "") : nil
}

check("every prefix of every fixture file parses without a trap, with and without the CRC flag") {
    var e: [String] = []
    var runs = 0
    for file in fixtureFilesBytes {
        for n in 0 ... file.count {
            for crc in [true, false] {
                let r = parsed(file.prefix(n), crc: crc)
                runs += 1
                if (r.fileID == nil) != (n < 7) { e.append("prefix \(n): id presence") }
            }
        }
    }
    notes.append("prefix sweep: \(runs) parses")
    return e
}

check("random single-byte mutations of fixture files (CRC recomputed) never trap") {
    var rng = SplitMix64(state: 0xF4EE_BA4D)
    var runs = 0
    for file in fixtureFilesBytes where file.count > 12 {
        let raw = [UInt8](file.dropLast(4))
        for _ in 0 ..< 300 {
            var b = raw
            for _ in 0 ... rng.below(3) { b[8 + rng.below(b.count - 8)] = rng.byte() }
            if rng.below(4) == 0 { b.removeLast(rng.below(b.count - 8)) }
            b += le32(ActivityCRC32.checksum(b))
            _ = parsed(Data(b))
            runs += 1
        }
    }
    notes.append("mutation fuzz: \(runs) parses")
    return []
}

check("random bodies for every kind and version, stage magic sprinkled in, never trap") {
    var rng = SplitMix64(state: 0x5EED)
    let kinds: [(UInt8, UInt8, UInt8)] = [(0, 0, 0), (0, 0, 1), (0, 8, 0), (0, 8, 1), (0, 8, 3), (0, 3, 0), (0, 6, 0), (1, 8, 1), (0, 0x1F, 0)]
    var e: [String] = []
    var runs = 0
    for (t, s, d) in kinds {
        for v in UInt8(0) ... 6 {
            for _ in 0 ..< 400 {
                var body: [UInt8] = []
                let length = rng.below(260)
                while body.count < length {
                    if rng.below(5) == 0 {
                        body += [0xFB, 0xFA, 0xFC, 0xFF, 17] + rng.bytes(8) + [rng.byte(), UInt8(rng.below(20)), 0, UInt8(rng.below(40))]
                    } else {
                        body += rng.bytes(1 + rng.below(16))
                    }
                }
                let id = ActivityFileID(timestamp: UInt32(truncatingIfNeeded: rng.next()), tzQuarterHours: Int8(truncatingIfNeeded: rng.byte()),
                                        version: v, type: t, subtype: s, detailType: d)
                let r = parsed(makeFile(id, pad: rng.below(8) == 0 ? rng.byte() : 0, body: body))
                runs += 1
                if r.fileID != id || r.payloadLength != body.count { e.append("\(id): envelope \(r.payloadLength) vs \(body.count)") }
                if case let .dailyDetails(dd) = r.payload, dd.records.count > body.count { e.append("\(id): more records than bytes") }
            }
        }
    }
    notes.append("random-body fuzz: \(runs) parses")
    return Array(e.prefix(8))
}

check("random packets into the assembler never trap; completions always pass the CRC") {
    var rng = SplitMix64(state: 0xA55E)
    var asm = ActivityAssembler(maxFileSize: 4096)
    var e: [String] = []
    var completions = 0
    for _ in 0 ..< 20000 {
        let packet: Data
        switch rng.below(4) {
        case 0: packet = Data(rng.bytes(rng.below(6)))
        case 1: packet = chunk(rng.below(4), rng.below(4), rng.bytes(rng.below(30)))
        default:
            let file = makeFile(ActivityFileID(timestamp: 1, version: 1, type: 0, subtype: 6, detailType: 0), body: rng.bytes(rng.below(40)))
            packet = chunk(1, 1, Array(file))
        }
        if case let .complete(file) = asm.add(packet) {
            completions += 1
            if let c = ActivityCRC32.trailer(of: file), c.stored != c.computed { e.append("bad CRC passed") }
            if file.count < 13 { e.append("short file passed") }
        }
    }
    return e + expect(completions > 0, "no completions")
}

check("available file list is fetched when the other list is missing") {
    let today = ActivityFileID(timestamp: 100, version: 4, type: 0, subtype: 0, detailType: 0)
    let past = ActivityFileID(timestamp: 200, version: 6, type: 0, subtype: 8, detailType: 1)
    var errors = expect(ActivitySyncPlan.queue(today: [today], past: [], hasFile: { _ in false }) == [today], "missing past list lost today files")
    errors += expect(ActivitySyncPlan.queue(today: [], past: [past], hasFile: { _ in false }) == [past], "missing today list lost past files")
    errors += expect(ActivitySyncPlan.queue(today: [today], past: [today, past], hasFile: { $0 == past }) == [today], "duplicate or already stored file")
    return errors
}

// MARK: - Summary

print("")
var total = 0
var failed = 0
for group in groupOrder {
    let t = tallies[group, default: Tally()]
    total += t.passed + t.failed
    failed += t.failed
    print("\(group): \(t.passed)/\(t.passed + t.failed) passed")
}
for note in notes { print("note: \(note)") }
print("\(total - failed)/\(total) cases passed (\(fixtureFiles.count) fixture files)")
exit(failed == 0 ? 0 : 1)
