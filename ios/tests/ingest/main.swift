import Foundation

// Ingest tests: the fixture files of ios/tests/activity/fixtures through ActivityParser and
// IngestMapper (Data/IngestMapper.swift), idempotence, minute merging, nap classification,
// the sleep merge rule and the calibration checks (Data/Calibration.swift).
//
//   cd ios/tests/ingest
//   swiftc ../../Freeband/Band/ActivityFiles.swift ../../Freeband/Analytics/*.swift \
//          ../../Freeband/Data/IngestMapper.swift ../../Freeband/Data/Calibration.swift \
//          main.swift -o /tmp/ingest_tests
//   /tmp/ingest_tests [FIXTURE_DIR]

// MARK: - Runner

var passed = 0
var failed = 0
var group = ""

func section(_ name: String) {
    group = name
    print("-- \(name)")
}

func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok {
        passed += 1
    } else {
        failed += 1
        print("FAIL \(group) :: \(name) \(detail())")
    }
}

func equal<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    check(name, got == want, "got \(got) want \(want)")
}

// MARK: - Fixtures

struct FixtureCase {
    let file: String
    let name: String
    let hex: String
    let hasCRC: Bool
    let expectError: Bool
}

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

let fixtureDir: URL = {
    if CommandLine.arguments.count > 1 { return URL(fileURLWithPath: CommandLine.arguments[1]) }
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    return here.appendingPathComponent("../activity/fixtures").standardized
}()

func loadCases() -> [FixtureCase] {
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: fixtureDir.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
    var out: [FixtureCase] = []
    for f in files {
        guard let data = try? Data(contentsOf: fixtureDir.appendingPathComponent(f)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cases = json["cases"] as? [[String: Any]] else { continue }
        for c in cases where (c["kind"] as? String) == "file" {
            out.append(FixtureCase(file: f, name: c["name"] as? String ?? "?", hex: c["hex"] as? String ?? "",
                                   hasCRC: c["has_crc"] as? Bool ?? true, expectError: c["expect_error"] as? Bool ?? false))
        }
    }
    return out
}

let cases = loadCases()

func parse(_ c: FixtureCase) -> ActivityParseResult {
    ActivityParser.parse(hexData(c.hex), hasCRC: c.hasCRC, expecting: nil)
}

func output(_ nameContains: String) -> (ActivityParseResult, IngestOutput)? {
    guard let c = cases.first(where: { $0.name.contains(nameContains) }) else { return nil }
    let r = parse(c)
    return (r, IngestMapper.map(r))
}

// MARK: - Every fixture file

section("all fixtures")
check("fixtures found", cases.count >= 30, "found \(cases.count) in \(fixtureDir.path)")
var statusCounts: [ParseStatus: Int] = [:]
var allOutputs: [(ActivityParseResult, IngestOutput, Int)] = []
for c in cases {
    let result = parse(c)
    let out = IngestMapper.map(result)
    statusCounts[out.status, default: 0] += 1
    allOutputs.append((result, out, hexData(c.hex).count))
    let failedParse = out.status == .error || out.status == .crc || out.status == .unsupported
    if c.expectError {
        check("\(c.file) \(c.name): error status", failedParse, "status \(out.status)")
        check("\(c.file) \(c.name): no drafts", out.minuteParts.isEmpty && out.summary == nil && out.sleeps.isEmpty && out.manual.isEmpty)
    } else {
        check("\(c.file) \(c.name): status", out.status != .error && out.status != .crc, "status \(out.status): \(out.note)")
    }
    if result.kind.isWorkout {
        equal("\(c.name): workouts are raw only", out.status, .unsupported)
    }
    // Idempotence: the same file mapped twice gives the same drafts.
    let again = IngestMapper.map(result)
    check("\(c.name): idempotent minutes", again.minuteParts == out.minuteParts)
    check("\(c.name): idempotent summary", again.summary == out.summary)
    check("\(c.name): idempotent sleeps", again.sleeps == out.sleeps)
    check("\(c.name): idempotent manual", again.manual == out.manual)
    equal("\(c.name): idempotent status", again.status, out.status)
    // Parsing the bytes again from scratch gives the same drafts too.
    let fresh = IngestMapper.map(parse(c))
    check("\(c.name): reparse identical", fresh.minuteParts == out.minuteParts && fresh.sleeps == out.sleeps
        && fresh.summary == out.summary && fresh.manual == out.manual)
}
print("   statuses: \(statusCounts.map { "\($0.key.rawValue) \($0.value)" }.sorted().joined(separator: ", "))")
check("some parsed", (statusCounts[.parsed] ?? 0) > 10)
check("workouts unsupported", (statusCounts[.unsupported] ?? 0) >= 13)

// MARK: - Daily details

section("daily details")
if let (r, out) = output("daily details v4") {
    guard case let .dailyDetails(d) = r.payload else { fatalError("v4 did not parse") }
    equal("one day", out.minuteParts.count, 1)
    let part = out.minuteParts[0]
    // id 5068ed68 0c: 2025-10-13T21:00Z at UTC+3 -> local 2025-10-14 00:00.
    equal("local day", part.day.string, "2025-10-14")
    equal("offset", part.series.tzOffsetMinutes, 180)
    equal("record count", out.minuteRecords, d.records.count)
    equal("minutes with a record", part.recordCount, d.records.count)
    equal("steps", Array(part.series.steps.prefix(2)), [12, 16383])
    equal("heart rate", Array(part.series.heartRate.prefix(2)), [72, 180])
    equal("spo2 0 is no value", part.series.spo2[1], nil)
    equal("stress", part.series.stress[0], 30)
    equal("kcal", part.series.kcal[0], 3)
    equal("distance", part.series.distance[1], 1234)
    equal("energy", part.series.energy[0], 65)
    equal("source", part.sourceFileIDs, [r.fileID!.hex])
    equal("status", out.status, .parsed)
    check("touches the day", out.touchedDays == [part.day])
}
if let (_, out) = output("daily details v2") {
    let s = out.minuteParts[0].series
    equal("zero steps kept", s.steps[1], 0)
    equal("heart rate 0 is not measured", s.heartRate[1], nil)
    equal("heart rate", s.heartRate[0], 95)
    equal("absent energy", s.energy[0], nil)
}
if let (_, out) = output("daily details v3") {
    equal("stray bytes -> partial", out.status, .partial)
    equal("whole record kept", out.minuteRecords, 1)
    check("warning carried", !out.warnings.isEmpty)
}

// Minute merging: a later file overwrites only where it has a value.
section("minute merge")
if let (_, out) = output("daily details v4") {
    let part = out.minuteParts[0]
    let twice = IngestMapper.mergeMinuteParts([part, part])
    check("merging a part with itself", twice?.series == part.series)
    equal("sources not repeated", twice?.sourceFileIDs, part.sourceFileIDs)
    // A later "file" (larger time stamp in the hex id) with only minute 1 and 2.
    var later = MinuteSeries(day: part.day, tzOffsetMinutes: 180)
    later.steps[1] = 7
    later.steps[2] = 9
    let laterHex = "6068ed680c0400"  // ts 0x68ed6860 > 0x68ed6850
    let merged = IngestMapper.mergeMinuteParts([MinuteDayDraft(series: later, sourceFileIDs: [laterHex]), part])!
    equal("file order by time stamp", merged.sourceFileIDs, [part.sourceFileIDs[0], laterHex])
    equal("later file wins where it has values", Array(merged.series.steps.prefix(3)), [12, 7, 9])
    equal("earlier values kept elsewhere", merged.series.heartRate[1], 180)
    let other = MinuteDayDraft(series: MinuteSeries(day: part.day.adding(days: 1), tzOffsetMinutes: 180), sourceFileIDs: ["x"])
    check("different days do not merge", IngestMapper.mergeMinuteParts([part, other]) == nil)
    equal("hex time stamp", IngestMapper.fileOrder("5068ed680c0400"), 0x68ED_6850)
}

// MARK: - Daily summary and manual samples

section("summary and manual")
if let (_, out) = output("v5 all bits set") {
    equal("summary steps", out.summary?.steps, 12345)
    equal("summary version", out.summary?.fileVersion, 5)
    check("summary has resting HR", out.summary?.hrResting != nil)
    equal("summary day", out.summary.map { $0.day }, out.touchedDays.first)
}
if let (_, out) = output("manual samples v2") {
    equal("four readings", out.manual.count, 4)
    equal("kinds", out.manual.map(\.kind), ["spo2", "stress", "temperature", "temperature"])
    equal("celsius", out.manual[2].celsius, 36.74)
    // 1705611402 = 2024-01-18T20:56:42Z, UTC+1 -> 21:56 on the 18th.
    equal("reading day", out.manual[0].day.string, "2024-01-18")
}
if let (_, out) = output("v1 SpO2 97") {
    equal("real capture: one SpO2", out.manual.map(\.value), [97])
    equal("real capture: kind", out.manual.first?.kind, "spo2")
}

// MARK: - Sleep

section("sleep")
var fixtureSleeps: [SleepDraft] = []
if let (_, out) = output("sleep details v5") {
    equal("one sleep", out.sleeps.count, 1)
    let s = out.sleeps[0]
    fixtureSleeps.append(s)
    equal("kind", s.kind, .details)
    // Bed 2025-10-14T19:20Z (22:20 at UTC+3), wake 21:40Z (00:40 on the 15th): the night
    // belongs to the day it ends on.
    equal("wake day", s.day.string, "2025-10-15")
    check("22:20 is not a nap", !s.isNap)
    equal("stage minutes from the summary packet", [s.deepMinutes, s.lightMinutes, s.remMinutes, s.awakeMinutes], [45, 70, 20, 5])
    equal("wake count", s.wakeCount, 2)
    equal("segments", s.segments.map(\.minutes), [30, 45, 20, 5, 40])
    equal("segment stages", s.segments.map(\.stage), [.light, .deep, .rem, .awake, .light])
    equal("hr series", s.hrValues, [58, 55, 60])
    equal("spo2 interval", s.spo2IntervalSeconds, 300)
    equal("rr beats", s.rrBeats, 4)
    equal("rr kept raw", s.rr.first?.tsRaw, 1_760_469_600_000)
    equal("quality", s.sleepQuality, 78)
    // As analytics input: the ms time stamp places the RR packet at bed time.
    let input = s.input
    equal("input hr samples", input.heartRate.map(\.value), [58, 55, 60])
    check("rr resolves", HRV.resolveStart(tsRaw: s.rr[0].tsRaw, bedTime: s.bedTime, wakeTime: s.wakeTime) == s.bedTime)
}
if let (_, out) = output("sleep details v2") {
    let s = out.sleeps[0]
    fixtureSleeps.append(s)
    // Bed 18:26:40Z = 21:26 local: after 20:00, so not a nap even at 1 h 50 min.
    check("21:26 for 110 min is not a nap", !s.isNap)
    equal("minutes from stage words", [s.deepMinutes, s.lightMinutes], [50, 60])
    check("empty HR block", s.hrValues.isEmpty)
}
if let (_, out) = output("sleep stages v2, five") {
    let s = out.sleeps[0]
    fixtureSleeps.append(s)
    equal("stages kind", s.kind, .stages)
    // Changes at +0, +60, +150, +180 min and 1760415000; wake 1760415200.
    equal("durations to the next change", s.segments.map(\.minutes), [60, 90, 30, 237, 3])
    equal("stages day", s.day.string, "2025-10-14")
    equal("band minutes", [s.deepMinutes, s.lightMinutes, s.remMinutes, s.awakeMinutes], [90, 240, 70, 20])
}
if let (_, out) = output("sleep stages v2 with no data") {
    check("no data, no sleep", out.sleeps.isEmpty)
    equal("still parsed", out.status, .parsed)
}

section("naps")
let noonUTC = DayKey(string: "2026-10-14")!.start(offsetMinutes: 0)
func nap(_ hour: Double, minutes: Double, tz: Int = 0) -> Bool {
    let bed = noonUTC.addingTimeInterval(hour * 3600)
    return IngestMapper.isNap(bedTime: bed, wakeTime: bed.addingTimeInterval(minutes * 60), tzOffsetMinutes: tz)
}
check("14:00 for 40 min", nap(14, minutes: 40))
check("10:00 starts the window", nap(10, minutes: 30))
check("09:59 is too early", !nap(9 + 59.0 / 60, minutes: 30))
check("19:59 is inside", nap(19 + 59.0 / 60, minutes: 60))
check("20:00 is the night", !nap(20, minutes: 60))
check("3 h is not under 3 h", !nap(12, minutes: 180))
check("2 h 59 min is", nap(12, minutes: 179))
check("23:00 night", !nap(23, minutes: 480))
check("local time decides: 11:00 UTC at +3 is 14:00", nap(11, minutes: 40, tz: 180))
check("local time decides: 14:00 UTC at +8 is 22:00", !nap(14, minutes: 40, tz: 480))

section("sleep merge rule")
if fixtureSleeps.count == 3 {
    let stages = fixtureSleeps[2]
    // A details file for the same night (overlapping, different bed time, earlier wake).
    var details = stages
    details.kind = .details
    details.sourceFileID = "aa"
    details.bedTime = stages.bedTime.addingTimeInterval(600)
    details.wakeTime = stages.wakeTime.addingTimeInterval(-1800)
    equal("details beats stages", IngestMapper.primaryFlags([stages, details]), [false, true])
    // Same bed time, two details files: the later wake time wins.
    var grown = details
    grown.sourceFileID = "bb"
    grown.wakeTime = details.wakeTime.addingTimeInterval(1200)
    equal("latest wake wins", IngestMapper.primaryFlags([details, grown]), [false, true])
    equal("order does not matter", IngestMapper.primaryFlags([grown, details]), [true, false])
    // A nap the same afternoon does not overlap the night: both stay.
    var napDraft = details
    napDraft.bedTime = stages.wakeTime.addingTimeInterval(6 * 3600)
    napDraft.wakeTime = napDraft.bedTime.addingTimeInterval(1800)
    napDraft.isNap = true
    equal("separate sleeps both primary", IngestMapper.primaryFlags([details, napDraft]), [true, true])
    equal("three files of one night", IngestMapper.primaryFlags([stages, details, grown]), [false, false, true])
    // Applying the rule twice gives the same answer.
    let all = [stages, details, grown, napDraft]
    equal("rule is stable", IngestMapper.primaryFlags(all), IngestMapper.primaryFlags(all))
}

// MARK: - Calibration

section("calibration")
let day = DayKey(string: "2025-10-14")!
var minutes = MinuteSeries(day: day, tzOffsetMinutes: 180)
minutes.steps[0] = 600
minutes.steps[1] = 400
let minuteDraft = MinuteDayDraft(series: minutes, sourceFileIDs: ["m"])
func summary(_ steps: Int?) -> DaySummaryDraft {
    DaySummaryDraft(day: day, tzOffsetMinutes: 180, sourceFileID: "s", fileVersion: 5, steps: steps)
}
// 1000 vs 1015: -1.5% -> pass; vs 1030: -2.9% -> fail; tolerance never below 10 steps.
equal("steps within 2%", Calibration.stepsCheck(minutes: minuteDraft, summary: summary(1015)).status, .pass)
equal("steps beyond 2%", Calibration.stepsCheck(minutes: minuteDraft, summary: summary(1030)).status, .fail)
equal("summary without steps", Calibration.stepsCheck(minutes: minuteDraft, summary: summary(nil)).status, .skip)
var tiny = MinuteSeries(day: day, tzOffsetMinutes: 180)
tiny.steps[0] = 5
equal("10-step floor", Calibration.stepsCheck(minutes: MinuteDayDraft(series: tiny, sourceFileIDs: []), summary: summary(14)).status, .pass)
var badHR = minutes
badHR.heartRate[0] = 250
badHR.heartRate[1] = 60
equal("HR outside 30-220", Calibration.heartRateCheck(minuteDays: [MinuteDayDraft(series: badHR, sourceFileIDs: [])], sleeps: []).status, .fail)
equal("HR inside", Calibration.heartRateCheck(minuteDays: [minuteDraft], sleeps: fixtureSleeps).status, .pass)
if let (r, out) = output("daily details v4"), let id = r.fileID, let records = out.minuteRecords {
    // Fetched `records` minutes and 30 s after the file start: expected = records.
    let fetched = id.ts.addingTimeInterval(TimeInterval(records * 60 + 30))
    equal("records match elapsed", Calibration.recordCountCheck(fileID: id, records: records, fetchedAt: fetched).status, .pass)
    equal("records far short", Calibration.recordCountCheck(fileID: id, records: records, fetchedAt: id.ts.addingTimeInterval(600 * 60)).status, .fail)
    // A past day: expected ends at the local day end (1440 minutes after a midnight start).
    let check1440 = Calibration.recordCountCheck(fileID: id, records: 1440, fetchedAt: id.ts.addingTimeInterval(3 * 86_400))
    equal("past day expects the whole day", check1440.status, .pass)
}
for s in fixtureSleeps {
    equal("sleep plausible \(s.sourceFileID)", Calibration.sleepCheck(s, fetchedAt: s.wakeTime.addingTimeInterval(3600)).status, .pass)
}
if let s = fixtureSleeps.first {
    equal("wake after the fetch", Calibration.sleepCheck(s, fetchedAt: s.wakeTime.addingTimeInterval(-3600)).status, .fail)
    var long = s
    long.wakeTime = s.bedTime.addingTimeInterval(20 * 3600)
    long.deepMinutes = nil
    long.lightMinutes = nil
    long.remMinutes = nil
    long.awakeMinutes = nil
    equal("20 h sleep", Calibration.sleepCheck(long, fetchedAt: nil).status, .fail)
}
equal("rr present", Calibration.rrCheck(fixtureSleeps).status, .pass)
equal("rr absent", Calibration.rrCheck(Array(fixtureSleeps.dropFirst())).status, .warn)
equal("no sleep files", Calibration.rrCheck([]).status, .skip)

// The whole report from every fixture, as a sync would produce it.
let entries = allOutputs.map { Calibration.fileEntry($0.0, output: $0.1, size: $0.2, fetchedAt: nil) }
let minuteFiles = allOutputs.compactMap { o -> Calibration.MinuteFile? in
    guard let id = o.0.fileID, let n = o.1.minuteRecords else { return nil }
    return Calibration.MinuteFile(fileID: id, records: n, fetchedAt: id.ts.addingTimeInterval(TimeInterval(n * 60 + 30)))
}
let report = Calibration.build(files: entries, minuteFiles: minuteFiles, minuteDays: allOutputs.flatMap { $0.1.minuteParts },
                               summaries: allOutputs.compactMap { $0.1.summary }, sleeps: allOutputs.flatMap { $0.1.sleeps },
                               bandID: "test", outcome: "complete", parserVersion: 1, algoVersion: 1)
equal("every file listed", report.files.count, cases.count)
check("crc recorded", report.files.contains { $0.crcOK == true && $0.crcStored == $0.crcComputed })
// A flipped body byte breaks the CRC: status crc, the stored and computed values differ, no drafts.
if let c = cases.first(where: { $0.name.contains("daily details v4") }) {
    var bytes = [UInt8](hexData(c.hex))
    bytes[10] ^= 0x40
    let broken = ActivityParser.parse(Data(bytes))
    let out = IngestMapper.map(broken)
    equal("crc status", out.status, .crc)
    check("crc mismatch is no data", out.minuteParts.isEmpty && out.touchedDays.isEmpty)
    let entry = Calibration.fileEntry(broken, output: out, size: bytes.count, fetchedAt: nil)
    check("crc failure recorded", entry.crcOK == false && entry.crcStored != entry.crcComputed && entry.status == "crc")
}
check("check kinds", Set(report.checks.map(\.name)).isSuperset(of: ["heart_rate_range", "records_vs_elapsed", "sleep_plausible", "rr_present"]))
equal("record checks pass", report.checks.filter { $0.name == "records_vs_elapsed" }.map(\.status), Array(repeating: .pass, count: minuteFiles.count))
let decoded = CalibrationReport.decode(report.json())
check("JSON round trip", decoded?.files == report.files && decoded?.checks == report.checks)
check("JSON is an object", (try? JSONSerialization.jsonObject(with: report.json())) is [String: Any])

// MARK: - Into analytics

section("into analytics")
// The fixture night as a scored day: nothing crashes and the sleep is scored from it.
if let s = fixtureSleeps.first {
    let result = ScoreEngine.score(DayInputs(day: s.day, sleeps: [s.input]), history: [], profile: .unknown)
    check("fixture night scored", result.sleep.score != nil)
    check("4 RR beats are too few for HRV", result.hasRR && result.hrv == nil)
}

// MARK: - Files stored under another file's id

section("refile")
// freeband#2: 0.5.2 stored what a late band sent under the id it had asked for.
func storedFile(_ id: ActivityFileID) -> Data { Data(id.bytes + [0xAA, 0xBB]) }
let sleepID = ActivityFileID(timestamp: 0x6ADD_33C0, tzQuarterHours: 4, version: 5, type: 0, subtype: 0x08, detailType: 1)
let dayID = ActivityFileID(timestamp: 0x6ADD_8B68, tzQuarterHours: 4, version: 4, type: 0, subtype: 0, detailType: 0)
let summaryID = ActivityFileID(timestamp: 0x6ADD_3870, tzQuarterHours: 4, version: 5, type: 0, subtype: 0, detailType: 1)
equal("sleep file id from the issue", sleepID.hex, "c033dd6a040521")
equal("filed correctly: nothing to do", refilePlan([(dayID.hex, storedFile(dayID))]), [:])
// The day's bytes under the sleep's id, nothing under the day's: moves, and frees the sleep's id.
equal("misfiled: moves to the id it carries",
      refilePlan([(sleepID.hex, storedFile(dayID))]), [sleepID.hex: .move(to: dayID)])
// The day's bytes under the sleep's id, and the day's own copy filed correctly: dropped.
equal("its id holds its own bytes: dropped",
      refilePlan([(sleepID.hex, storedFile(dayID)), (dayID.hex, storedFile(dayID))]), [sleepID.hex: .drop])
// Two files swapped: each moves to its own id.
equal("swapped pair: both move",
      refilePlan([(sleepID.hex, storedFile(summaryID)), (summaryID.hex, storedFile(sleepID))]),
      [sleepID.hex: .move(to: summaryID), summaryID.hex: .move(to: sleepID)])
// The same bytes under two wrong ids: one moves, the other is dropped.
equal("one id claimed twice: one move",
      refilePlan([(sleepID.hex, storedFile(dayID)), (summaryID.hex, storedFile(dayID))]).values.filter { $0 == .drop }.count, 1)
equal("too short for an id: left alone", refilePlan([(sleepID.hex, Data([1, 2, 3]))]), [:])

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
