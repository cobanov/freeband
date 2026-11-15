import Foundation

// Hand-computed vectors for ios/Freeband/Analytics (algorithm v1, plan section 5).
//
//   cd ios/tests/analytics
//   swiftc ../../Freeband/Analytics/*.swift main.swift -o /tmp/analytics_tests && /tmp/analytics_tests
//
// Every expected number below is worked out by hand (or with a calculator) from the formulas in
// the plan and the constants documented in the source; the comments show the arithmetic.

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

func near(_ name: String, _ got: Double?, _ want: Double?, _ tol: Double = 1e-6) {
    switch (got, want) {
    case (nil, nil): passed += 1
    case let (g?, w?) where abs(g - w) <= tol: passed += 1
    default:
        failed += 1
        print("FAIL \(group) :: \(name) got \(got.map { String($0) } ?? "nil") want \(want.map { String($0) } ?? "nil")")
    }
}

func equal<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    check(name, got == want, "got \(got) want \(want)")
}

// MARK: - Fixtures

/// 2026-10-14 local midnight at UTC+0.
let day0 = DayKey(string: "2026-10-14")!
let midnight = day0.start(offsetMinutes: 0)
func at(_ hours: Double) -> Date { midnight.addingTimeInterval(hours * 3600) }

/// RR alternating 1000 / 1000 + d ms for `seconds`: every successive difference is +-d, so the
/// RMSSD of any stretch is exactly d.
func alternating(_ d: Int, seconds: Double) -> [Int] {
    var out: [Int] = []
    var t = 0.0
    while t < seconds {
        let v = out.count % 2 == 0 ? 1000 : 1000 + d
        out.append(v)
        t += Double(v) / 1000
    }
    return out
}

func rrSegment(at hours: Double, d: Int, seconds: Double = 600) -> RRSegment {
    RRSegment(tsRaw: Int64(at(hours).timeIntervalSince1970), intervalsMs: alternating(d, seconds: seconds))
}

// MARK: - DayKey and packing

section("daykey")
equal("string round trip", DayKey(string: "2026-10-14")?.string, "2026-10-14")
equal("epoch", DayKey(string: "1970-01-01")?.index, 0)
equal("leap day", DayKey(string: "2024-02-29")?.adding(days: 1).string, "2024-03-01")
check("bad string", DayKey(string: "2026-13-01") == nil)
// 2026-10-13T21:30Z at UTC+3 is 00:30 on the 14th.
let late = Date(timeIntervalSince1970: day0.start(offsetMinutes: 0).timeIntervalSince1970 - 2.5 * 3600)
equal("offset moves the day", DayKey(date: late, offsetMinutes: 180), day0)
equal("same instant at UTC is the 13th", DayKey(date: late, offsetMinutes: 0).string, "2026-10-13")
equal("negative offset", DayKey(date: midnight.addingTimeInterval(2 * 3600), offsetMinutes: -180).string, "2026-10-13")
equal("local midnight at +3", day0.start(offsetMinutes: 180).timeIntervalSince1970, midnight.timeIntervalSince1970 - 10_800)
equal("minute of day", day0.minute(of: at(1.5), offsetMinutes: 0), 90)
check("minute of other day", day0.minute(of: at(24.1), offsetMinutes: 0) == nil)

section("packing")
let p8: [Int?] = [0, 1, nil, 254, 300, -4]
equal("pack8 round trip and clamp", Packed.unpack8(Packed.pack8(p8)), [0, 1, nil, 254, 254, 0])
let p16: [Int?] = [0, nil, 16383, 70000]
equal("pack16 round trip and clamp", Packed.unpack16(Packed.pack16(p16)), [0, nil, 16383, 65534])
equal("pack16 little-endian", [UInt8](Packed.pack16([0x1234])), [0x34, 0x12])
equal("unpack pads to count", Packed.unpack8(Data([1]), count: 3), [1, nil, nil])
let segs = [StageSegment(start: at(0), minutes: 30, stage: .light), StageSegment(start: at(0.5), minutes: 45, stage: .deep)]
equal("stage segments round trip", StageSegment.unpack(StageSegment.pack(segs)), segs)
let rrs = [RRSegment(tsRaw: 1_760_469_600_000, intervalsMs: [1000, 980]), RRSegment(tsRaw: -5, intervalsMs: [1200])]
let rrBack = RRSegment.unpack(index: RRSegment.packIndex(rrs), intervals: Packed.packU16(rrs.flatMap(\.intervalsMs)))
equal("rr segments round trip", rrBack, rrs)

// MARK: - Baseline

section("baseline")
// [60, 62, 58, 61, 59]: median 60, |dev| [0,2,2,1,1] -> MAD 1, sigma 1.4826, 5 days -> low.
let b1 = Baseline.compute([60, 62, 58, 61, 59], floor: .zero)!
near("median", b1.median, 60)
near("MAD", b1.mad, 1)
near("sigma = 1.4826 MAD", b1.sigma, 1.4826)
equal("5 days is low", b1.status, .low)
near("z", b1.z(63), 3 / 1.4826)
// Even count: [10,20,30,40] -> median 25, |dev| [15,5,5,15] -> MAD 10.
let b2 = Baseline.compute([10, 20, 30, 40], floor: .zero)!
near("even median", b2.median, 25)
near("even MAD", b2.mad, 10)
// Flat resting HR: MAD 0, floor max(1.5, 3% of 60 = 1.8) = 1.8.
let b3 = Baseline.compute([60, 60, 60, 60, 60, 60, 60], floor: .restingHR)!
near("floor applies", b3.sigma, 1.8)
equal("7 days is normal", b3.status, .normal)
equal("2 days is calibrating", Baseline.compute([60, 61], floor: .zero)?.status, .calibrating)
check("no days, no baseline", Baseline.compute([], floor: .zero) == nil)
// Only the first 14 values: 14 x 50 then 6 x 100 -> median 50.
let b4 = Baseline.compute(Array(repeating: 50.0, count: 14) + Array(repeating: 100.0, count: 6), floor: .zero)!
equal("window is 14", b4.count, 14)
near("older days ignored", b4.median, 50)

// MARK: - HRV

section("hrv")
// [1000,1010,990,1000]: d = 10,-20,10 -> sqrt((100+400+100)/3) = sqrt(200).
near("rmssd", HRV.rmssd([1000, 1010, 990, 1000]), 200.0.squareRoot())
// 500 jumps 51% from 1010 and 990 jumps 98% from 500: both differences go; 10 and 10 stay.
near("jump rejection", HRV.rmssd([1000, 1010, 500, 990, 1000]), 10)
equal("jump rejection keeps 2", HRV.validDifferences([1000, 1010, 500, 990, 1000]), [10, 10])
// 250 < 300 ms: its two differences go, 1010 -> 1020 stays.
near("range rejection", HRV.rmssd([1000, 250, 1010, 1020]), 10)
check("all rejected is nil", HRV.rmssd([2100, 1000]) == nil)
near("exactly 20% is kept", HRV.rmssd([1000, 1200]), 200)
check("over 20% is dropped", HRV.rmssd([1000, 1201]) == nil)
// Fixture RR from the sleep v5 test file: -20, +40, -70 -> sqrt((400+1600+4900)/3).
near("fixture rr", HRV.rmssd([1000, 980, 1020, 950]), 2300.0.squareRoot())

// Night 00:00-08:00 (middle 04:00). First half: d = 100 at 01:00 (ignored). Second half:
// d = 20 at 05:00, 40 at 06:00, 60 at 07:00, two 5-min windows each -> [20,20,40,40,60,60],
// median (40+40)/2 = 40.
let night = [rrSegment(at: 1, d: 100), rrSegment(at: 5, d: 20), rrSegment(at: 6, d: 40), rrSegment(at: 7, d: 60)]
let hrvNight = HRV.nightly(night, bedTime: at(0), wakeTime: at(8))
near("nightly median of second half", hrvNight.result?.rmssd, 40)
equal("second-half windows", hrvNight.windows, 6)
check("always approximate", hrvNight.result?.approximate == true)
let windows = HRV.windows(night, bedTime: at(0), wakeTime: at(8))
equal("8 windows in all", windows.count, 8)
near("first-half window rmssd", windows.first?.rmssd, 100)
check("first-half window flagged", windows.first?.secondHalf == false)
// One 10-minute group in the second half: 2 windows < 3 -> no HRV.
let thin = HRV.nightly([rrSegment(at: 5, d: 20)], bedTime: at(0), wakeTime: at(8))
check("fewer than 3 windows -> nil", thin.result == nil)
equal("found 2", thin.windows, 2)
// Time stamp unit: milliseconds and nanoseconds resolve, junk does not.
let msStart = HRV.resolveStart(tsRaw: Int64(at(5).timeIntervalSince1970) * 1000, bedTime: at(0), wakeTime: at(8))
near("ms time stamp", msStart?.timeIntervalSince1970, at(5).timeIntervalSince1970)
let nsStart = HRV.resolveStart(tsRaw: Int64(at(6).timeIntervalSince1970) * 1_000_000_000, bedTime: at(0), wakeTime: at(8))
near("ns time stamp", nsStart?.timeIntervalSince1970, at(6).timeIntervalSince1970)
check("unplaceable time stamp", HRV.resolveStart(tsRaw: 12345, bedTime: at(0), wakeTime: at(8)) == nil)
// Unplaceable packets follow each other from bed time: two at the start -> first half -> nil.
let unplaced = HRV.nightly([RRSegment(tsRaw: 1, intervalsMs: alternating(20, seconds: 600)),
                            RRSegment(tsRaw: 2, intervalsMs: alternating(20, seconds: 600))], bedTime: at(0), wakeTime: at(8))
equal("unplaced packets start at bed", unplaced.windows, 0)
// A window where most differences are artifacts does not count: 1000/1500 alternation (50% jumps).
let noisy = HRV.windows([RRSegment(tsRaw: Int64(at(5).timeIntervalSince1970), intervalsMs: (0 ..< 500).map { $0 % 2 == 0 ? 1000 : 1500 })],
                        bedTime: at(0), wakeTime: at(8))
check("artifact window unusable", noisy.allSatisfy { !$0.usable })

// MARK: - Sleep metrics

section("sleep metrics")
// Bed 23:00 (UTC+0), wake 07:00: 480 min in bed. Band totals deep 90, light 240, REM 100, awake 50
// -> total 430, efficiency 430/480. Timeline: awake 10 (latency), light 100, deep 90, awake 15,
// light 140, REM 100, awake 25 -> WASO 15 (only the waking between sleeps), one waking.
let bed = at(-1), wake = at(7)
var timeline: [StageSegment] = []
var cursor = bed
for (m, k) in [(10, StageKind.awake), (100, .light), (90, .deep), (15, .awake), (140, .light), (100, .rem), (25, .awake)] {
    timeline.append(StageSegment(start: cursor, minutes: m, stage: k))
    cursor = cursor.addingTimeInterval(TimeInterval(m * 60))
}
// HR: 60 every minute except minutes 100-107 = [60,58,56,55,54,55,57,60] (sum 455).
let dip: [Int] = [60, 58, 56, 55, 54, 55, 57, 60]
let hrSeries = (0 ..< 480).map { m in TimedValue(ts: bed.addingTimeInterval(TimeInterval(m * 60)), value: (100 ..< 108).contains(m) ? dip[m - 100] : 60) }
// SpO2: 96 every minute, 89 at minutes 200 and 201.
let spo2Series = (0 ..< 480).map { m in TimedValue(ts: bed.addingTimeInterval(TimeInterval(m * 60)), value: m == 200 || m == 201 ? 89 : 96) }
var sleepIn = SleepInput(bedTime: bed, wakeTime: wake, deepMinutes: 90, lightMinutes: 240, remMinutes: 100, awakeMinutes: 50,
                         segments: timeline, wakeCount: 2, heartRate: hrSeries, spo2: spo2Series)
let m1 = SleepMetricsCalc.compute(sleepIn, minutes: [], awakeHRMean: 70)
near("in bed", m1.inBedMinutes, 480)
near("total", m1.totalSleepMinutes, 430)
near("efficiency", m1.efficiency, 430.0 / 480)
near("deep fraction", m1.deepFraction, 90.0 / 430)
near("rem fraction", m1.remFraction, 100.0 / 430)
near("waso", m1.wasoMinutes, 15)
equal("band wake count wins", m1.wakeCount, 2)
near("mid-sleep 03:00", m1.midSleepMinute, 180)
// Lowest 5-min mean: (56+55+54+55+57)/5 = 55.4.
near("lowest 5 min", m1.hrLowest5Min, 55.4)
near("hr min", m1.hrMinimum, 54)
// (472 x 60 + 455) / 480.
near("hr mean", m1.hrAverage, 28_775.0 / 480)
near("hr dip", m1.hrDip, (70 - 28_775.0 / 480) / 70)
near("spo2 mean", m1.spo2Average, (478 * 96 + 2 * 89) / 480.0)
near("spo2 below 90", m1.spo2Below90Minutes, 2)
sleepIn.wakeCount = nil
equal("wake count from the timeline", SleepMetricsCalc.compute(sleepIn, minutes: [], awakeHRMean: nil).wakeCount, 1)
// Rolling mean needs 3 values in 5 minutes.
check("sparse rolling mean", SleepMetricsCalc.lowestRollingAverage([60, nil, nil, nil, 50, nil, nil]) == nil)
near("rolling mean with gaps", SleepMetricsCalc.lowestRollingAverage([60, 58, nil, 56, nil, nil]), 58)

// MARK: - Sleep score

section("sleep score")
// Duration 430/480 -> 89.583; efficiency (0.8958-0.60)/0.30 -> 98.611; deep 20.9% >= 18% -> 100;
// REM 23.3% >= 22% -> 100; restfulness 100 - 4x2 - 15 = 77; regularity: diffs to [180,190,170,200]
// are [0,-10,10,-20], median -5 -> 5 min -> 100; dip 14.36%/15% -> 95.734.
// (35x89.583 + 15x98.611 + 10x100 + 10x100 + 10x77 + 10x100 + 10x95.734) / 100 = 93.42 -> 93.
let s1 = SleepScore.score(m1, sleepNeedMinutes: 480, previousMidSleeps: [180, 190, 170, 200])
equal("full score", s1.score, 93)
check("not estimated", !s1.estimated)
equal("high confidence", s1.confidence.level, .high)
near("duration sub", s1.contributors.first { $0.name == .duration }?.subscore, 430.0 / 480 * 100)
// v2: the same night against a need of 12 h. Duration 430/720 -> 59.72; the other six are as above,
// so the weighted mean is (35x59.72 + 15x98.611 + 1000 + 1000 + 770 + 1000 + 957.34) / 100 = 82.97,
// but a score may stand at most 10 above its duration sub-score: 69.72 -> 70.
equal("a short night can't be rescued by the rest", SleepScore.score(m1, sleepNeedMinutes: 720, previousMidSleeps: [180, 190, 170, 200]).score, 70)
near("restfulness sub", s1.contributors.first { $0.name == .restfulness }?.subscore, 77)
near("regularity value", s1.contributors.first { $0.name == .regularity }?.value, 5)
near("regularity across midnight", SleepScore.regularityDeviation(10, previous: [1430, 1435, 5]), 15)
check("regularity needs 3 nights", SleepScore.regularityDeviation(10, previous: [0, 5]) == nil)
// No stages, no HR, no history: total = 480 - 50 = 430, WASO from the awake total = 50 ->
// restfulness 50. Weights 35 + 15 + 10 = 60 (not below 60): (3135.42 + 1479.17 + 500) / 60 = 85.24.
let bare = SleepInput(bedTime: bed, wakeTime: wake, awakeMinutes: 50)
let m2 = SleepMetricsCalc.compute(bare, minutes: [], awakeHRMean: nil)
check("no stages flagged", !m2.stagesAvailable)
let s2 = SleepScore.score(m2, sleepNeedMinutes: 480, previousMidSleeps: [])
equal("score from 60 of the weight", s2.score, 85)
check("60 is not an estimate", !s2.estimated)
equal("missing contributors -> medium", s2.confidence.level, .medium)
check("reasons name the missing", s2.confidence.reasons.contains(ConfidenceReason(.missingContributor, detail: "deep")))
// Nothing but bed and wake: duration 480/480 and efficiency 1.0 -> 100, but only 50 of the weight.
let s3 = SleepScore.score(SleepMetricsCalc.compute(SleepInput(bedTime: bed, wakeTime: wake), minutes: [], awakeHRMean: nil),
                          sleepNeedMinutes: 480, previousMidSleeps: [])
equal("estimate score", s3.score, 100)
check("below 60 is an estimate", s3.estimated)
equal("estimate -> low", s3.confidence.level, .low)
let s4 = SleepScore.score(nil, sleepNeedMinutes: 480, previousMidSleeps: [])
check("no sleep, no score", s4.score == nil && s4.confidence.level == ConfidenceLevel.none)
// A band that did not stage the night (all light) has no deep/REM rows.
let unstaged = SleepMetricsCalc.compute(SleepInput(bedTime: bed, wakeTime: wake, deepMinutes: 0, lightMinutes: 430, remMinutes: 0),
                                        minutes: [], awakeHRMean: nil)
check("all-light night is unstaged", !unstaged.stagesAvailable && unstaged.deepFraction == nil)

// MARK: - Recovery

section("recovery")
// HRV 50 vs [40..52 step 2]: median 46, MAD 4 -> sigma max(5.930, 3, 3.68) = 5.930, z = 0.6745 -> 73.490.
// Resting 55 vs [58,57,59,58,60,56,58]: median 58, MAD 1 -> sigma max(1.483, 1.5, 1.74) = 1.74,
// z = 3/1.74 = 1.7241 -> 94.483. Sleep 80 vs [70,75,80,85,90,70,75]: median 75, MAD 5 ->
// sigma 7.413, z = 0.6745 -> 73.490. Yesterday's strain 12 vs [10,11,9,10,12,8,10]: median 10,
// MAD 1 -> sigma 1.5, z = -1.333 -> 33.333.
let rhrSleep = RestingHR(value: 55, source: .sleep)
var rIn = Recovery.Inputs(hrv: 50, hrvHistory: [40, 42, 44, 46, 48, 50, 52], hasRR: true, hrvWindows: 6,
                          restingHR: rhrSleep, restingHRHistory: [58, 57, 59, 58, 60, 56, 58],
                          sleepScore: 80, sleepHistory: [70, 75, 80, 85, 90, 70, 75],
                          strainYesterday: 12, strainHistory: [10, 11, 9, 10, 12, 8, 10])
near("f(0) is 60", Recovery.f(0), 60)
near("f clamps", Recovery.f(3), 100)
let r1 = Recovery.score(rIn)
// (40x73.490 + 25x94.483 + 25x73.490 + 10x33.333) / 100 = 74.72 -> 75.
equal("with HRV", r1.score, 75)
check("uses HRV", r1.usesHRV)
equal("with HRV confidence", r1.confidence.level, .high)
check("HRV labelled approximate", r1.confidence.reasons.contains(ConfidenceReason(.hrvApproximate)))
near("hrv z", r1.contributors.first { $0.name == .hrv }?.z, 4 / (1.4826 * 4))
near("resting z sign", r1.contributors.first { $0.name == .restingHR }?.z, 3 / 1.74)
near("strain z sign", r1.contributors.first { $0.name == .strain }?.z, -2 / 1.5)
// Without RR: (45x94.483 + 40x73.490 + 15x33.333) / 100 = 76.91 -> 77, at most medium.
var noRR = rIn
noRR.hrv = nil
noRR.hasRR = false
noRR.hrvWindows = 0
let r2 = Recovery.score(noRR)
equal("without RR", r2.score, 77)
check("no HRV weights", !r2.usesHRV && r2.contributors.first { $0.name == .hrv }?.weight == 0)
equal("without RR is medium", r2.confidence.level, .medium)
check("reason no RR", r2.confidence.reasons.contains(ConfidenceReason(.noRR)))
// RR but too few windows: same score, the reason says why.
var fewWindows = noRR
fewWindows.hasRR = true
fewWindows.hrvWindows = 2
let r3 = Recovery.score(fewWindows)
equal("too few windows score", r3.score, 77)
check("too few windows reason", r3.confidence.reasons.contains(ConfidenceReason(.hrvTooFewWindows, 2, 3)))
// HRV value but its baseline still calibrating (2 nights): the no-HRV path.
var hrvCalibrating = rIn
hrvCalibrating.hrvHistory = [48, 50]
let r4 = Recovery.score(hrvCalibrating)
equal("HRV baseline calibrating", r4.score, 77)
check("HRV baseline calibrating reason", r4.confidence.reasons.contains { $0.code == .baselineCalibrating && $0.detail == "hrv" })
// Resting-HR baseline of 4 days: low confidence (median 58, MAD 0.5 -> same sigma 1.74, same score).
var shortBase = rIn
shortBase.restingHRHistory = [58, 57, 59, 58]
let r5 = Recovery.score(shortBase)
equal("short baseline score", r5.score, 75)
equal("short baseline -> low", r5.confidence.level, .low)
check("short baseline reason", r5.confidence.reasons.contains(ConfidenceReason(.baselineShort, 4, 14, detail: "resting_hr")))
// No strain yesterday: (40x73.490 + 25x94.483 + 25x73.490) / 90 = 79.32 -> 79, medium.
var noStrain = rIn
noStrain.strainYesterday = nil
let r6 = Recovery.score(noStrain)
equal("missing strain renormalises", r6.score, 79)
equal("missing strain -> medium", r6.confidence.level, .medium)
// Resting HR from the band: medium; from daytime minutes: low.
var bandRHR = rIn
bandRHR.restingHR = RestingHR(value: 55, source: .band)
equal("band resting HR -> medium", Recovery.score(bandRHR).confidence.level, .medium)
bandRHR.restingHR = RestingHR(value: 55, source: .daytime)
equal("daytime resting HR -> low", Recovery.score(bandRHR).confidence.level, .low)
// Calibrating: no HRV, resting baseline of 2 -> no score.
let r7 = Recovery.score(Recovery.Inputs(restingHR: rhrSleep, restingHRHistory: [58, 57], sleepScore: 80, sleepHistory: [70, 80]))
check("calibrating -> no score", r7.score == nil)
equal("calibrating -> none", r7.confidence.level, .none)
check("calibrating reason", r7.confidence.reasons.contains { $0.code == .baselineCalibrating && $0.a == 2 })
// Every metric at its baseline scores 60.
let flat = Recovery.score(Recovery.Inputs(hrv: 50, hrvHistory: Array(repeating: 50, count: 7), hasRR: true, hrvWindows: 5,
                                          restingHR: RestingHR(value: 55, source: .sleep), restingHRHistory: Array(repeating: 55, count: 7),
                                          sleepScore: 80, sleepHistory: Array(repeating: 80, count: 7),
                                          strainYesterday: 10, strainHistory: Array(repeating: 10, count: 7)))
equal("your normal is 60", flat.score, 60)

// MARK: - Resting HR

section("resting hr")
equal("sleep tier", RestingHR.compute(sleepLowest5Min: 55.4, bandValue: 52, minutes: nil, sleeps: [])?.source, .sleep)
equal("band tier", RestingHR.compute(sleepLowest5Min: nil, bandValue: 52, minutes: nil, sleeps: [])?.value, 52)
check("band value out of range ignored", RestingHR.compute(sleepLowest5Min: nil, bandValue: 0, minutes: nil, sleeps: []) == nil)
// Daytime: 100 still minutes with HR 50...149 -> nearest-rank 10th percentile = sorted[9] = 59.
var still = MinuteSeries(day: day0, tzOffsetMinutes: 0)
for i in 0 ..< 100 {
    still.steps[600 + i] = 0
    still.heartRate[600 + i] = 50 + i
}
still.steps[700] = 30
still.heartRate[700] = 40  // moving: not still
let daytime = RestingHR.compute(sleepLowest5Min: nil, bandValue: nil, minutes: still, sleeps: [])
equal("daytime tier", daytime?.source, .daytime)
near("daytime 10th percentile", daytime?.value, 59)
var fewStill = MinuteSeries(day: day0, tzOffsetMinutes: 0)
for i in 0 ..< 20 {
    fewStill.steps[i + 600] = 0
    fewStill.heartRate[i + 600] = 60
}
check("fewer than 30 still minutes", RestingHR.compute(sleepLowest5Min: nil, bandValue: nil, minutes: fewStill, sleeps: []) == nil)
// Minutes inside a sleep are not daytime.
let asleepAll = [SleepInput(bedTime: at(0), wakeTime: at(24))]
check("sleep minutes excluded", RestingHR.compute(sleepLowest5Min: nil, bandValue: nil, minutes: still, sleeps: asleepAll) == nil)

// MARK: - Strain

section("strain")
// 21 ln(1 + 100/25) / ln 25 = 21 ln 5 / (2 ln 5) = 10.5; 21 ln 9 / ln 25 = 14.3347.
near("TRIMP 100 -> 10.5", Strain.strain(trimp: 100), 10.5, 1e-9)
near("TRIMP 200 -> 14.3", Strain.strain(trimp: 200), 21 * log(9) / log(25), 1e-9)
check("TRIMP 200 rounds to 14.3", (Strain.strain(trimp: 200) * 10).rounded() / 10 == 14.3)
near("TRIMP 0 -> 0", Strain.strain(trimp: 0), 0)
near("capped at 21", Strain.strain(trimp: 1e6), 21)
// r = (150 - 60) / (180 - 60) = 0.75.
near("reserve", Strain.reserve(150, resting: 60, max: 180), 0.75)
near("reserve clamps", Strain.reserve(200, resting: 60, max: 180), 1)
equal("zones", [0.29, 0.49, 0.5, 0.6, 0.75, 0.8, 0.9, 1.0].map(Strain.zone), [0, 0, 1, 2, 3, 4, 5, 5])
// 0.75 x 0.64 x e^(1.92 x 0.75) = 0.48 x 4.220696 = 2.025934.
near("minute TRIMP", Strain.minuteTrimp(0.75, k: 1.92), 0.48 * exp(1.44))
near("below the floor", Strain.minuteTrimp(0.29, k: 1.92), 0)
equal("k by sex", [Profile(sex: .male).trimpK, Profile(sex: .female).trimpK, Profile().trimpK], [1.92, 1.67, 1.80])

// A full day: HR 70 all day (r = 10/120 < 0.3, nothing), 10:00-11:00 at 150 (r 0.75, zone 3).
// TRIMP = 60 x 2.025934 = 121.556 -> strain 21 ln(1 + 4.8622) / ln 25 = 11.538.
let athlete = Profile(age: 40, sex: .male, maxHROverride: 180)
var dayFull = MinuteSeries(day: day0, tzOffsetMinutes: 0)
for i in 0 ..< 1440 {
    dayFull.steps[i] = 0
    dayFull.heartRate[i] = (600 ..< 660).contains(i) ? 150 : 70
}
let st1 = Strain.compute(dayFull, sleeps: [], restingHR: 60, profile: athlete)!
near("day TRIMP", st1.trimp, 60 * 0.48 * exp(1.44), 1e-9)
near("day strain", st1.strain, 21 * log(1 + 60 * 0.48 * exp(1.44) / 25) / log(25), 1e-9)
equal("zone minutes", st1.zoneMinutes, [0, 0, 0, 60, 0, 0])
near("hourly", st1.hourlyTrimp[10], st1.trimp, 1e-9)
near("coverage", st1.coverage, 1)
equal("full coverage -> high", st1.confidence.level, .high)
// Sleep 00:00-07:00 is not counted: 1440 - 420 = 1020 awake minutes.
equal("awake minutes", Strain.compute(dayFull, sleeps: [SleepInput(bedTime: at(0), wakeTime: at(7))], restingHR: 60, profile: athlete)?.awakeMinutes, 1020)
// "Now" 10:30: only 30 minutes at 150 so far.
let partial = Strain.compute(dayFull, sleeps: [], restingHR: 60, profile: athlete, now: at(10.5))!
near("today so far", partial.trimp, 30 * 0.48 * exp(1.44), 1e-9)
// Unknown age (max 183.5) and resting HR assumed: medium.
let st2 = Strain.compute(dayFull, sleeps: [], restingHR: nil, profile: .unknown)!
equal("assumed max/rest -> medium", st2.confidence.level, .medium)
near("assumed max HR", st2.maxHR, 183.5)
near("assumed resting HR", st2.restingHR, 60)
check("age reason", st2.confidence.reasons.contains(ConfidenceReason(.ageUnknown)))

// Sparse HR: a reading every 10 minutes at 70 -> coverage 144/1440 = 0.1 < 0.5. Gaps of 9 are
// filled (r stays 0.083, nothing), and 10:00-11:00 at 120 steps/min without a reading counts as
// r = 0.4: 54 minutes x 0.4 x 0.64 x e^0.768 = 29.797 -> strain 21 ln(1 + 1.19188) / ln 25 = 5.120.
var sparse = MinuteSeries(day: day0, tzOffsetMinutes: 0)
for i in 0 ..< 1440 {
    sparse.steps[i] = (600 ..< 660).contains(i) ? 120 : 0
    if i % 10 == 0 { sparse.heartRate[i] = 70 }
}
let st3 = Strain.compute(sparse, sleeps: [], restingHR: 60, profile: athlete)!
near("sparse coverage", st3.coverage, 0.1)
equal("step minutes", st3.stepMinutes, 54)
near("sparse TRIMP", st3.trimp, 54 * 0.4 * 0.64 * exp(1.92 * 0.4), 1e-9)
near("sparse strain", st3.strain, 21 * log(1 + 54 * 0.256 * exp(0.768) / 25) / log(25), 1e-9)
equal("filled minutes", st3.filledMinutes, 143 * 9)
equal("sparse -> low", st3.confidence.level, .low)
check("sparse reasons", st3.confidence.reasons.contains(ConfidenceReason(.lowHeartRateCoverage, 0.1))
      && st3.confidence.reasons.contains(ConfidenceReason(.sparseHeartRate, 10)))
// Gap filling: readings 150 at 10:00 and 10:10 -> the 9 minutes between interpolate to r 0.75.
var gap = sparse
gap.heartRate[600] = 150
gap.heartRate[610] = 150
let st4 = Strain.compute(gap, sleeps: [], restingHR: 60, profile: athlete)!
equal("gap filled at 0.75", st4.zoneMinutes[3], 11)
// No heart rate at all: steps only, low.
var noHR = sparse
noHR.heartRate = Array(repeating: nil, count: 1440)
let st5 = Strain.compute(noHR, sleeps: [], restingHR: 60, profile: athlete)!
equal("steps only minutes", st5.stepMinutes, 60)
check("no HR reason", st5.confidence.level == .low && st5.confidence.reasons.contains(ConfidenceReason(.noHeartRate)))
check("no records -> nil", Strain.compute(MinuteSeries(day: day0, tzOffsetMinutes: 0), sleeps: [], restingHR: 60, profile: athlete) == nil)

// MARK: - Stress

section("stress")
// 30 at 00:00 holds 10 min, 70 at 00:10 holds 30 (capped), 90 at 01:40 holds 30 (capped):
// (300 + 2100 + 2700) / 70 = 72.857; relaxed 10, mild 0, moderate 30, high 30.
var stressDay = MinuteSeries(day: day0, tzOffsetMinutes: 0)
stressDay.stress[0] = 30
stressDay.stress[10] = 70
stressDay.stress[100] = 90
let stress = StressSummary.compute(stressDay)!
near("time-weighted mean", stress.average, 5100.0 / 70)
equal("band minutes", stress.bandMinutes, [10, 0, 30, 30])
check("no stress -> nil", StressSummary.compute(MinuteSeries(day: day0, tzOffsetMinutes: 0)) == nil)

// MARK: - Hourly steps

section("hourly steps")
var stepsMinutes = [Int?](repeating: nil, count: 1440)
stepsMinutes[61] = 100
stepsMinutes[125] = 50
let h1 = HourlySteps.compute(minuteSteps: stepsMinutes, dayStart: midnight, readings: [])
equal("from minutes", Array(h1.prefix(3)), [0, 100, 50])
// Live only: 1000 at 08:00 spread over 06:00-08:00, then +2000 spread over 08:00-10:00.
let h2 = HourlySteps.compute(minuteSteps: nil, dayStart: midnight, readings: [(at(8), 1000), (at(10), 3000)])
equal("spread between readings", Array(h2[6 ..< 10]), [500, 500, 1000, 1000])
equal("total kept", h2.reduce(0, +), 3000)
// Minute file to 09:59 (2000 steps), live 2600 at 11:00 -> 600 over 10:00-11:00.
var morning = [Int?](repeating: nil, count: 1440)
for i in 0 ..< 600 { morning[i] = i == 480 ? 2000 : 0 }
let h3 = HourlySteps.compute(minuteSteps: morning, dayStart: midnight, readings: [(at(9), 1800), (at(11), 2600)])
equal("minutes then live", [h3[8], h3[10]], [2000, 600])
equal("minutes then live total", h3.reduce(0, +), 2600)
// A count that drops (band reset) starts again from the lower reading.
let h4 = HourlySteps.compute(minuteSteps: nil, dayStart: midnight, readings: [(at(8), 1000), (at(9), 500), (at(10), 800)])
equal("reset", h4[9], 300)
equal("rounding keeps the total", HourlySteps.roundPreservingTotal([0.5, 0.5, 1.0]).reduce(0, +), 2)

// MARK: - Profile

section("profile")
near("Tanaka-style max", Profile(age: 40).maxHR, 180)
near("override wins", Profile(age: 40, maxHROverride: 195).maxHR, 195)
check("max known with age", Profile(age: 40).maxHRIsKnown && !Profile().maxHRIsKnown)
equal("default sleep need", Profile().sleepNeed, 480)
equal("set sleep need", Profile(sleepNeedMinutes: 450).sleepNeed, 450)
let suite = UserDefaults(suiteName: "freeband.tests.\(UUID().uuidString)")!
equal("unknown by default", Profile.load(from: suite), Profile.unknown)
Profile(age: 33, sex: .female, heightCm: 170, weightKg: 60, maxHROverride: nil, sleepNeedMinutes: 450).save(to: suite)
equal("saved and loaded", Profile.load(from: suite).age, 33)

// MARK: - Score engine (end to end, every degradation path)

section("score engine")
// Ten identical days: HR 70 all day with a 10:00-11:00 hour at 150, a night 23:00-07:00 with HR
// 55 and stages, RR from day 5. Constant metrics -> every z is 0 -> recovery 60 once baselines exist.
func engineDay(_ n: Int, rr: Bool) -> DayInputs {
    let day = day0.adding(days: n)
    let start = day.start(offsetMinutes: 0)
    var minutes = MinuteSeries(day: day, tzOffsetMinutes: 0)
    for i in 0 ..< 1440 {
        minutes.steps[i] = 0
        minutes.heartRate[i] = (600 ..< 660).contains(i) ? 150 : 70
    }
    let bedTime = start.addingTimeInterval(-3600), wakeTime = start.addingTimeInterval(7 * 3600)
    var segs: [StageSegment] = []
    var t = bedTime
    for (m, k) in [(10, StageKind.awake), (100, .light), (90, .deep), (15, .awake), (140, .light), (100, .rem), (25, .awake)] {
        segs.append(StageSegment(start: t, minutes: m, stage: k))
        t = t.addingTimeInterval(TimeInterval(m * 60))
    }
    let hr = (0 ..< 480).map { TimedValue(ts: bedTime.addingTimeInterval(TimeInterval($0 * 60)), value: 55) }
    let rrSegs = rr ? [4.0, 5.0, 6.0].map { h in
        RRSegment(tsRaw: Int64(bedTime.addingTimeInterval(h * 3600).timeIntervalSince1970), intervalsMs: alternating(30, seconds: 600))
    } : []
    let sleep = SleepInput(bedTime: bedTime, wakeTime: wakeTime, deepMinutes: 90, lightMinutes: 240, remMinutes: 100,
                           awakeMinutes: 50, segments: segs, wakeCount: 1, heartRate: hr, rr: rrSegs)
    return DayInputs(day: day, minutes: minutes, sleeps: [sleep], bandRestingHR: 52)
}
var inputs = (0 ..< 10).map { engineDay($0, rr: $0 >= 5) }
for i in 1 ..< inputs.count { inputs[i].previousMinutes = inputs[i - 1].minutes; inputs[i].previousSleeps = inputs[i - 1].sleeps }
let run = ScoreEngine.scoreRange(inputs, history: [], profile: athlete)
equal("ten results", run.count, 10)
equal("algorithm version", run[0].algoVersion, 2)
check("day 0: no baseline, no recovery", run[0].recovery.score == nil && run[0].recovery.confidence.level == ConfidenceLevel.none)
check("day 0: sleep scored", run[0].sleep.score != nil)
equal("resting HR from sleep", run[0].restingHR?.source, .sleep)
near("resting HR value", run[0].restingHR?.value, 55)
check("day 0: strain", run[0].strain != nil)
// Day 3 has 3 previous days: low baseline, no RR -> 60 with low confidence.
equal("day 3 recovery", run[3].recovery.score, 60)
equal("day 3 low", run[3].recovery.confidence.level, .low)
check("day 3 no HRV", !run[3].recovery.usesHRV)
// RR from day 5 (3 windows of 10 min in the second half... 04:00-07:00 after a 23:00 bed: 05:00+).
check("day 5 has RR", run[5].hasRR)
near("day 5 HRV", run[5].hrv?.rmssd, 30)
check("day 5 HRV baseline calibrating", !run[5].recovery.usesHRV)
// Day 8 has 3 previous HRV nights: HRV path, low (3-6 days).
check("day 8 uses HRV", run[8].recovery.usesHRV)
equal("day 8 recovery", run[8].recovery.score, 60)
// History points carry what the next days need.
near("history strain", run[4].history.strain, run[4].strain?.strain)
// Degradations: no minutes -> no strain, confidence none; no sleep -> no sleep score.
let empty = ScoreEngine.score(DayInputs(day: day0), history: [], profile: athlete)
check("no data: no strain", empty.strain == nil && empty.strainConfidence.level == ConfidenceLevel.none)
check("no data: no sleep", empty.sleep.score == nil && empty.sleep.confidence.level == ConfidenceLevel.none)
check("no data: no recovery", empty.recovery.score == nil)
// A nap alone does not make a sleep score; it is listed.
let napOnly = ScoreEngine.score(DayInputs(day: day0, sleeps: [SleepInput(bedTime: at(14), wakeTime: at(14.5), isNap: true)]),
                                history: [], profile: athlete)
check("nap not scored", napOnly.sleep.score == nil && napOnly.naps.count == 1)
// Band resting HR when the night has no HR.
var noNightHR = engineDay(0, rr: false)
noNightHR.sleeps[0].heartRate = []
noNightHR.minutes = nil
let bandOnly = ScoreEngine.score(noNightHR, history: [], profile: athlete)
equal("band resting HR fallback", bandOnly.restingHR?.source, .band)

// MARK: - Insights

section("insights")
/// `today` on day0, and before it `values` (the most recent first) on the days day0-1, day0-2, ...
func insightDays(_ today: InsightDay, _ values: [Double?], _ set: (inout InsightDay, Double) -> Void) -> [InsightDay] {
    [today] + values.enumerated().map { i, v in
        var d = InsightDay(day: day0.adding(days: -(i + 1)))
        if let v { set(&d, v) }
        return d
    }
}
func insights(_ history: [InsightDay], need: Double = 480) -> [Insight] {
    Insights.compute(day: day0, history: history, sleepNeedMinutes: need)
}
func rhrCase(_ today: Double, _ before: [Double?]) -> [Insight] {
    insights(insightDays(InsightDay(day: day0, restingHR: today), before) { $0.restingHR = $1 })
}
let flat50 = [Double?](repeating: 50, count: 14)
// Normal 50, MAD 0, so sigma is the floor: max(1.5, 3% of 50) = 1.5.
// 53.5: z = 3.5 / 1.5 = 2.33, a notice. 55: z = 3.33, a warning. 52: z = 1.33, nothing.
equal("rhr 2.33 sigma", rhrCase(53.5, flat50), [Insight(kind: .restingHRHigh, tone: .notice, value: 53.5, reference: 50)])
equal("rhr 3.33 sigma", rhrCase(55, flat50), [Insight(kind: .restingHRHigh, tone: .warning, value: 55, reference: 50)])
equal("rhr 1.33 sigma", rhrCase(52, flat50), [])
equal("rhr, 6-day baseline", rhrCase(55, Array(flat50.prefix(6))), [])
equal("day without data", insights(insightDays(InsightDay(day: day0), flat50) { $0.restingHR = $1 }.filter { $0.day != day0 }), [])
// Three days of 53.5: each day's own baseline still has median 50 and MAD 0 (two high days
// among 14 don't move either), so each is 2.33 sigma: 3 days in a row is a warning.
equal("rhr 3 days in a row", rhrCase(53.5, [53.5, 53.5] + flat50),
      [Insight(kind: .restingHRHigh, tone: .warning, value: 53.5, reference: 50, days: 3)])
// A day without a reading ends the run.
equal("rhr run broken by a gap", rhrCase(53.5, [nil, 53.5] + flat50).first?.days, 1)
// Normal 51 (seven 50s, seven 52s), MAD 1, sigma = max(1.4826, 1.5, 1.53) = 1.53.
// 49: z = -1.31 and below every one of the 14 days. 50: not below the lowest.
let alternating = (0 ..< 14).map { Double?($0 % 2 == 0 ? 50 : 52) }
equal("rhr lowest in 14 days", rhrCase(49, alternating), [Insight(kind: .restingHRLowest, tone: .good, value: 49, reference: 51)])
equal("rhr equal to the lowest", rhrCase(50, alternating), [])

func hrvCase(_ today: Double) -> [Insight] {
    insights(insightDays(InsightDay(day: day0, hrv: today), [Double?](repeating: 40, count: 14)) { $0.hrv = $1 })
}
// Normal 40, sigma floor max(3, 8% of 40) = 3.2. 33: z = -2.19. 30: z = -3.13. 35: z = -1.56.
equal("hrv -2.19 sigma", hrvCase(33), [Insight(kind: .hrvLow, tone: .notice, value: 33, reference: 40)])
equal("hrv -3.13 sigma", hrvCase(30).first?.tone, .warning)
equal("hrv -1.56 sigma", hrvCase(35), [])

func debtCase(_ minutes: Double, nights: Int) -> [Insight] {
    insights(insightDays(InsightDay(day: day0, sleepMinutes: minutes), [Double?](repeating: minutes, count: nights - 1)) { $0.sleepMinutes = $1 })
}
// Need 480. Seven nights of 420: 7 x 60 = 420 min short. Of 390: 630. Of 450: 210.
equal("sleep debt 7 h", debtCase(420, nights: 7), [Insight(kind: .sleepDebt, tone: .notice, value: 420, days: 7)])
equal("sleep debt 10.5 h", debtCase(390, nights: 7), [Insight(kind: .sleepDebt, tone: .warning, value: 630, days: 7)])
equal("sleep debt 3.5 h", debtCase(450, nights: 7), [])
equal("sleep debt, 4 nights", debtCase(300, nights: 4), [])
// Only the last 7 nights count: 10 nights of 420 is still 420.
equal("sleep debt window", debtCase(420, nights: 10).first?.value, 420)

func shiftCase(_ today: Double, _ before: Double, nights: Int = 7) -> [Insight] {
    insights(insightDays(InsightDay(day: day0, midSleepMinute: today), [Double?](repeating: before, count: nights)) { $0.midSleepMinute = $1 })
}
// Middle of the night at 03:00 (180) on the nights before; 04:50 (290) is 110 min later.
equal("sleep 110 min later", shiftCase(290, 180), [Insight(kind: .sleepShifted, tone: .notice, value: 110, days: 7)])
equal("sleep 100 min earlier", shiftCase(80, 180).first?.value, -100)
equal("sleep 60 min later", shiftCase(240, 180), [])
// 23:50 (1430) before, 01:40 (100) now: 110 min later across midnight, not 1330 earlier.
equal("sleep shift across midnight", shiftCase(100, 1430).first?.value, 110)
// And the other way round: 01:40 before, 23:50 now is 110 min earlier.
equal("sleep shift back across midnight", shiftCase(1430, 100).first?.value, -110)
equal("sleep shift, 3 nights", shiftCase(290, 180, nights: 3), [])

func loadCase(recovery: Double, hardDays: Int) -> [Insight] {
    let before = [Double?](repeating: 11, count: hardDays) + [Double?](repeating: 8, count: 14)
    return insights(insightDays(InsightDay(day: day0, recovery: recovery), before) { $0.strain = $1 })
}
// Strain normal 8, sigma floor 1.5; 11 is 2 sigma above on each of the three days.
equal("3 hard days, recovery 30", loadCase(recovery: 30, hardDays: 3),
      [Insight(kind: .loadWithoutRecovery, tone: .warning, value: 30, reference: 11, days: 3)])
equal("3 hard days, recovery 40", loadCase(recovery: 40, hardDays: 3), [])
equal("2 hard days, recovery 30", loadCase(recovery: 30, hardDays: 2), [])

// Warnings come first: sleep debt (warning) before resting HR (notice), though its rule is later.
var mixed = insightDays(InsightDay(day: day0, restingHR: 53.5, sleepMinutes: 390), flat50) { $0.restingHR = $1 }
for i in 1 ... 6 { mixed[i].sleepMinutes = 390 }
equal("warnings first", insights(mixed).map(\.kind), [.sleepDebt, .restingHRHigh])

// MARK: - Battery estimate

section("battery estimate")
func reading(_ hours: Double, _ level: Int) -> (at: Date, level: Int) { (at(hours), level) }
// 80% -> 68% in 24 h is 0.5% an hour; 68 / 0.5 = 136 h = 5.67 days.
near("days left from one day of discharge", BatteryEstimate.daysLeft([reading(0, 80), reading(8, 76), reading(24, 68)]), 68 / 0.5 / 24, 1e-9)
// A charge in between: only the readings after it count. 100 -> 94 in 12 h = 0.5% an hour; 94 / 0.5 / 24 = 7.83.
near("only since the last charge", BatteryEstimate.daysLeft([reading(0, 60), reading(10, 40), reading(11, 100), reading(23, 94)]), 94 / 0.5 / 24, 1e-9)
check("under 12 hours says nothing", BatteryEstimate.daysLeft([reading(0, 80), reading(6, 70)]) == nil)
check("under 3 points says nothing", BatteryEstimate.daysLeft([reading(0, 80), reading(24, 78)]) == nil)
check("no readings", BatteryEstimate.daysLeft([]) == nil)

// MARK: - Done

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
