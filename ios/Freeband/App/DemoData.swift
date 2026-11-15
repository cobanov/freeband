import Foundation
import SwiftData

/// Debug-only data for simulator screenshots and UI work. Launch with
///
///     -freeband-demo [full | empty | calibrating]
///
/// (the bare flag means `full`):
/// - full: 30 days of minute data, nights with stages/HR/SpO2, daily summaries, scores and
///   today's live samples for one Band 10 Pro; no RR for the first 10 nights and RR after, so
///   both recovery paths (with and without HRV) show up;
/// - calibrating: the same for the last 2 days only (baselines still calibrating);
/// - empty: the band is added, nothing synced yet.
///
/// Scores are not invented: the generated raw data goes through DailyRollup like real data.
enum DemoData {
    enum Variant: String {
        case full, empty, calibrating
    }

    /// Demo data is showing: demo mode (DemoMode.swift) or the DEBUG launch argument.
    static var isActive: Bool { DemoMode.isOn || variant(ProcessInfo.processInfo.arguments) != nil }

    static func variant(_ arguments: [String]) -> Variant? {
        guard let i = arguments.firstIndex(of: "-freeband-demo") else { return nil }
        if i + 1 < arguments.count, let v = Variant(rawValue: arguments[i + 1].lowercased()) { return v }
        return .full
    }

    @MainActor
    static func seed(_ context: ModelContext, _ variant: Variant = .full, now: Date = Date()) {
        try? context.delete(model: Sample.self)
        try? context.delete(model: ActivityBlob.self)
        ActivityIngest.deleteDerived(context: context, bandID: nil, includingScores: true)
        try? context.delete(model: Band.self)

        let band = Band(name: "Xiaomi Smart Band 10 Pro", mac: "AA:BB:CC:DD:0D:E0")
        band.firmware = "3.1.42"
        band.hardwareModel = "Xiaomi Smart Band 10 Pro"
        context.insert(band)

        switch variant {
        case .empty:
            try? context.save()
        case .calibrating:
            Generator(band: band.id, now: now, days: 2, rrFromDay: 0).insert(into: context)
            band.lastBattery = 71
            band.lastSyncAt = now.addingTimeInterval(-240)
            try? context.save()
            DailyRollup.recompute(context: context, bandID: band.id, from: DayKey.current(now).adding(days: -1), now: now)
        case .full:
            Generator(band: band.id, now: now, days: 30, rrFromDay: 10).insert(into: context)
            band.lastBattery = 46
            band.lastSyncAt = now.addingTimeInterval(-90)
            try? context.save()
            DailyRollup.recompute(context: context, bandID: band.id, from: DayKey.current(now).adding(days: -29), now: now)
        }
    }

    /// Deterministic (seeded) so screenshots are repeatable.
    private struct RNG {
        var state: UInt64

        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }

        mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }

        mutating func normal(_ mean: Double, _ sd: Double) -> Double {
            let u = max(next(), 1e-12), v = next()
            return mean + sd * (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }

        mutating func chance(_ p: Double) -> Bool { next() < p }
    }

    private struct Generator {
        let band: UUID
        let now: Date
        let days: Int
        let rrFromDay: Int
        let offset: Int
        let today: DayKey

        init(band: UUID, now: Date, days: Int, rrFromDay: Int) {
            self.band = band
            self.now = now
            self.days = days
            self.rrFromDay = rrFromDay
            offset = TimeZone.current.secondsFromGMT(for: now) / 60
            today = DayKey.current(now)
        }

        private struct Plan {
            var poorNight: Bool
            /// 0 rest, 1 easy run, 2 hard session.
            var workout: Int
            var nap: Bool
        }

        func insert(into context: ModelContext) {
            var rng = RNG(state: 0x5EED_F00D)
            var plans: [Int: Plan] = [:]
            var nights: [Int: SleepDraft] = [:]
            var naps: [Int: SleepDraft] = [:]
            let first = today.adding(days: -(days - 1))

            for n in 0 ..< days {
                let day = first.adding(days: n)
                let plan = Plan(poorNight: rng.chance(0.15) || n % 11 == 6,
                                workout: n % 7 == 5 ? 2 : (n % 3 == 1 ? 1 : 0),
                                nap: n % 9 == 4)
                plans[day.index] = plan
                // Hard training the day before shows up as a lower HRV and a higher night HR.
                let tired = plans[day.index - 1]?.workout == 2
                if let night = makeNight(day: day, plan: plan, tired: tired, withRR: n >= rrFromDay, rng: &rng) {
                    nights[day.index] = night
                }
                if plan.nap {
                    let start = day.start(offsetMinutes: offset).addingTimeInterval(14 * 3600 + 10 * 60)
                    let end = start.addingTimeInterval(35 * 60)
                    if end < now {
                        naps[day.index] = makeNap(day: day, start: start, end: end)
                    }
                }
            }

            var liveSteps: [(Date, Int, Int, Int)] = []
            for n in 0 ..< days {
                let day = first.adding(days: n)
                guard let plan = plans[day.index] else { continue }
                let sleeps = [nights[day.index], nights[day.index + 1], naps[day.index]].compactMap { $0 }
                let series = makeMinutes(day: day, plan: plan, sleeps: sleeps, rng: &rng)
                context.insert(MinuteDay(bandID: band, draft: MinuteDayDraft(series: series, sourceFileIDs: ["demo-\(day.string)-details"])))
                context.insert(DaySummary(bandID: band, draft: summary(series, sleeps: sleeps)))
                if let workout = makeWorkout(day: day, plan: plan, series: series) {
                    context.insert(Workout(bandID: band, draft: workout))
                }
                if day == today { liveSteps = liveReadings(series) }
            }
            for sleep in nights.values.sorted(by: { $0.bedTime < $1.bedTime }) + naps.values.sorted(by: { $0.bedTime < $1.bedTime }) {
                context.insert(SleepRecord(bandID: band, draft: sleep))
                if sleep.rrBeats > 0 { context.insert(SleepRR(bandID: band, draft: sleep)) }
            }
            for (ts, steps, kcal, hr) in liveSteps {
                let draft = SampleDraft(kind: "live", ts: ts, steps: steps, calories: kcal, heartRate: hr,
                                        standingHours: max(0, Calendar.current.component(.hour, from: ts) - 7))
                context.insert(Sample(bandID: band, draft: draft))
            }
            context.insert(Sample(bandID: band, draft: .battery(46, at: now.addingTimeInterval(-90))))
        }

        // MARK: nights

        private func makeNight(day: DayKey, plan: Plan, tired: Bool, withRR: Bool, rng: inout RNG) -> SleepDraft? {
            let midnight = day.start(offsetMinutes: offset)
            var bed = midnight.addingTimeInterval(-3600 + rng.range(-40, 45) * 60)
            if plan.poorNight { bed = bed.addingTimeInterval(80 * 60) }
            let wakeTarget = midnight.addingTimeInterval(7 * 3600 + rng.range(-30, 40) * 60)
            let wake = min(wakeTarget, now.addingTimeInterval(-600))
            guard wake.timeIntervalSince(bed) >= 3 * 3600 else { return nil }

            // Timeline: latency, then ~90 min cycles; deep early, REM late, a few short wakings.
            var segments: [StageSegment] = []
            var t = bed
            func add(_ minutes: Int, _ stage: StageKind) {
                guard minutes > 0, t < wake else { return }
                let m = min(minutes, Int(wake.timeIntervalSince(t) / 60))
                guard m > 0 else { return }
                segments.append(StageSegment(start: t, minutes: m, stage: stage))
                t = t.addingTimeInterval(TimeInterval(m * 60))
            }
            add(Int(rng.range(7, 16)), .awake)
            let total = wake.timeIntervalSince(bed)
            while wake.timeIntervalSince(t) >= 60 {
                let progress = t.timeIntervalSince(bed) / total
                add(Int(rng.range(18, 32)), .light)
                add(Int(rng.range(10, 30) * (1.3 - progress)), .deep)
                add(Int(rng.range(8, 16)), .light)
                add(Int(rng.range(8, 22) * (0.6 + progress)), .rem)
                if rng.chance(plan.poorNight ? 0.6 : 0.3) { add(Int(rng.range(2, 7)), .awake) }
            }
            func minutes(_ k: StageKind) -> Int { segments.filter { $0.stage == k }.reduce(0) { $0 + $1.minutes } }

            // Heart rate per minute: lowest a little after the middle of the night.
            let base = 53 + (plan.poorNight ? 4.0 : 0) + (tired ? 3.0 : 0) + rng.normal(0, 1.2)
            let count = Int(total / 60)
            var hr: [Int] = []
            for m in 0 ..< count {
                let ts = bed.addingTimeInterval(TimeInterval(m * 60))
                let frac = Double(m) / Double(max(count, 1))
                let stage = segments.last { $0.start <= ts }?.stage ?? .light
                let shift: Double = stage == .deep ? -2 : (stage == .rem ? 3 : (stage == .awake ? 9 : 0))
                hr.append(Int((base + 12 * pow(frac - 0.55, 2) + shift + rng.normal(0, 1.1)).rounded()))
            }
            let spo2 = (0 ..< count).map { _ in rng.chance(0.03) ? Int(rng.range(90, 93)) : Int(rng.normal(96.3, 0.9).rounded()).clamped(92, 99) }

            var rr: [RRSegment] = []
            if withRR {
                // 10-minute groups every 30 minutes, like the band's ~10 min RR batches.
                let rmssd = max(18, 48 + rng.normal(0, 5) - (plan.poorNight ? 12 : 0) - (tired ? 9 : 0))
                var start = bed.addingTimeInterval(20 * 60)
                while start.addingTimeInterval(600) < wake {
                    let m = Int(start.timeIntervalSince(bed) / 60)
                    let meanRR = 60_000 / Double(hr[min(max(m, 0), hr.count - 1)])
                    var beats: [Int] = []
                    var elapsed = 0.0
                    while elapsed < 600 {
                        var v = meanRR + rng.normal(0, rmssd / 2.0.squareRoot())
                        if rng.chance(0.003) { v = meanRR / 2 }  // a missed beat now and then
                        let q = Int((v / 10).rounded()) * 10
                        beats.append(q)
                        elapsed += Double(q) / 1000
                    }
                    rr.append(RRSegment(tsRaw: Int64(start.timeIntervalSince1970), intervalsMs: beats))
                    start = start.addingTimeInterval(30 * 60)
                }
            }

            let awakeSegments = segments.dropFirst().filter { $0.stage == .awake }.count
            return SleepDraft(
                sourceFileID: "demo-\(day.string)-sleep", kind: .details, fileVersion: 5, day: day, tzOffsetMinutes: offset,
                bedTime: bed, wakeTime: wake, deepMinutes: minutes(.deep), lightMinutes: minutes(.light),
                remMinutes: minutes(.rem), awakeMinutes: minutes(.awake), segments: segments,
                hrStart: bed, hrIntervalSeconds: 60, hrValues: hr, spo2Start: bed, spo2IntervalSeconds: 60, spo2Values: spo2,
                wakeCount: awakeSegments, sleepQuality: plan.poorNight ? 62 : 84, isNap: false, rr: rr
            )
        }

        private func makeNap(day: DayKey, start: Date, end: Date) -> SleepDraft {
            let minutes = Int(end.timeIntervalSince(start) / 60)
            return SleepDraft(
                sourceFileID: "demo-\(day.string)-nap", kind: .details, fileVersion: 5, day: day, tzOffsetMinutes: offset,
                bedTime: start, wakeTime: end, deepMinutes: 0, lightMinutes: minutes - 4, remMinutes: 0, awakeMinutes: 4,
                segments: [StageSegment(start: start, minutes: 4, stage: .awake),
                           StageSegment(start: start.addingTimeInterval(240), minutes: minutes - 4, stage: .light)],
                hrStart: start, hrIntervalSeconds: 60, hrValues: (0 ..< minutes).map { 60 - min($0, 10) / 2 },
                spo2Start: nil, spo2IntervalSeconds: 60, spo2Values: [], wakeCount: 0, sleepQuality: nil,
                isNap: true, rr: []
            )
        }

        // MARK: days

        private func makeMinutes(day: DayKey, plan: Plan, sleeps: [SleepDraft], rng: inout RNG) -> MinuteSeries {
            var s = MinuteSeries(day: day, tzOffsetMinutes: offset)
            let start = day.start(offsetMinutes: offset)
            let lived = day == today ? min(MinuteSeries.slots, Int(now.timeIntervalSince(start) / 60)) : MinuteSeries.slots
            let rest = 58 + rng.normal(0, 1.5)
            let workoutStart = 18 * 60 + 30
            let workoutLength = plan.workout == 2 ? 70 : 45
            var energy = 92.0
            for i in 0 ..< max(lived, 0) {
                let t = start.addingTimeInterval(TimeInterval(i * 60))
                if let sleep = sleeps.first(where: { t >= $0.bedTime && t < $0.wakeTime }) {
                    let m = Int(t.timeIntervalSince(sleep.bedTime) / 60)
                    s.steps[i] = 0
                    s.kcal[i] = 0
                    s.distance[i] = 0
                    if m >= 0, m < sleep.hrValues.count { s.heartRate[i] = sleep.hrValues[m] }
                    if m >= 0, m < sleep.spo2Values.count, i % 5 == 0 { s.spo2[i] = sleep.spo2Values[m] }
                    energy = min(energy + 0.12, 96)
                    s.energy[i] = Int(energy)
                    continue
                }
                var steps = rng.chance(0.18) ? Int(rng.range(4, 45)) : 0
                var hr = rest + 13 + rng.normal(0, 3)
                let walking = (490 ..< 515).contains(i) || (750 ..< 770).contains(i) || (1065 ..< 1090).contains(i)
                let working = plan.workout > 0 && (workoutStart ..< workoutStart + workoutLength).contains(i)
                if walking {
                    steps = Int(rng.range(96, 116))
                    hr = 98 + rng.normal(0, 4)
                } else if working {
                    let k = Double(i - workoutStart) / Double(workoutLength)
                    let peak = plan.workout == 2 ? 172.0 : 152.0
                    steps = plan.workout == 2 ? Int(rng.range(158, 172)) : Int(rng.range(145, 160))
                    hr = 110 + (peak - 110) * min(k * 4, 1) - (k > 0.9 ? 25 : 0) + rng.normal(0, 3)
                } else if i >= 1260 {
                    hr = rest + 9 + rng.normal(0, 2.5)
                }
                s.steps[i] = steps
                s.kcal[i] = min(steps / 22 + (working ? 9 : 0), 63)
                s.distance[i] = Int(Double(steps) * (working ? 1.05 : 0.74))
                if !rng.chance(0.04) { s.heartRate[i] = Int(hr.rounded()).clamped(40, 200) }
                if i % 5 == 0, !working {
                    let workHours = (540 ..< 1020).contains(i)
                    s.stress[i] = Int(rng.normal(workHours ? 46 : 27, 9).rounded()).clamped(5, 95)
                }
                if i % 30 == 0 { s.spo2[i] = Int(rng.normal(97.4, 0.8).rounded()).clamped(93, 100) }
                energy = max(energy - (working ? 0.35 : 0.055), 8)
                s.energy[i] = Int(energy)
            }
            return s
        }

        /// The evening run of makeMinutes (18:30, 45 or 70 minutes) as the summary a band writes,
        /// counted from the same minutes so the list and the day trace agree.
        private func makeWorkout(day: DayKey, plan: Plan, series s: MinuteSeries) -> WorkoutDraft? {
            guard plan.workout > 0 else { return nil }
            let minutes = (18 * 60 + 30) ..< (18 * 60 + 30 + (plan.workout == 2 ? 70 : 45))
            let start = day.start(offsetMinutes: offset).addingTimeInterval(Double(minutes.lowerBound) * 60)
            let end = start.addingTimeInterval(Double(minutes.count) * 60)
            guard end < now else { return nil }
            func total(_ values: [Int?]) -> Int { values[minutes].reduce(0) { $0 + ($1 ?? 0) } }
            let hr = s.heartRate[minutes].compactMap { $0 }
            let steps = total(s.steps)
            let meters = total(s.distance)
            let hard = plan.workout == 2
            return WorkoutDraft(
                sourceFileID: "demo-\(day.string)-workout", sport: "outdoor_running", start: start, end: end, day: day,
                tzOffsetMinutes: offset, activeSeconds: minutes.count * 60, distanceMeters: meters, steps: steps,
                calories: total(s.kcal), totalCalories: total(s.kcal) + minutes.count * 6 / 5,
                hrAvg: hr.isEmpty ? nil : hr.reduce(0, +) / hr.count, hrMax: hr.max(), hrMin: hr.min(),
                paceAvg: meters > 0 ? minutes.count * 60_000 / meters : nil,
                paceBest: meters > 0 ? minutes.count * 55_000 / meters : nil,
                speedAvg: Double(meters) / 1000 / (Double(minutes.count) / 60),
                speedMax: Double(meters) / 1000 / (Double(minutes.count) / 60) * 1.12,
                cadenceAvg: steps / minutes.count, cadenceMax: s.steps[minutes].compactMap { $0 }.max(),
                aerobicEffect: hard ? 3.6 : 2.4, anaerobicEffect: hard ? 1.2 : nil, vo2max: 47,
                recoveryHours: hard ? 30 : 14, load: hard ? 96 : 48, vitality: hard ? 12 : 7)
        }

        private func summary(_ s: MinuteSeries, sleeps: [SleepDraft]) -> DaySummaryDraft {
            let hr = s.heartRate.compactMap { $0 }
            let stress = s.stress.compactMap { $0 }
            let spo2 = s.spo2.compactMap { $0 }
            let active = s.kcal.compactMap { $0 }.reduce(0, +)
            let lived = Double(s.recordCount) / Double(MinuteSeries.slots)
            func avg(_ v: [Int]) -> Int? { v.isEmpty ? nil : Int((Double(v.reduce(0, +)) / Double(v.count)).rounded()) }
            var standing = 0
            for h in 0 ..< 24 where s.steps[(h * 60) ..< (h * 60 + 60)].compactMap({ $0 }).reduce(0, +) > 250 { standing |= 1 << h }
            let night = sleeps.first { !$0.isNap && $0.day == s.day }
            return DaySummaryDraft(
                day: s.day, tzOffsetMinutes: s.tzOffsetMinutes, sourceFileID: "demo-\(s.day.string)-summary", fileVersion: 5,
                steps: s.stepTotal, activeCalories: active, calories: active + Int(1650 * lived),
                hrResting: night.flatMap { $0.hrValues.min() }.map { $0 + 2 }, hrMin: hr.min(), hrMax: hr.max(), hrAvg: avg(hr),
                stressAvg: avg(stress), stressMin: stress.min(), stressMax: stress.max(), standingMask: standing,
                spo2Avg: avg(spo2), spo2Min: spo2.min(), spo2Max: spo2.max(), trainingLoadDay: nil, trainingLoadWeek: nil,
                trainingLoadLevel: nil, vitalityCurrent: nil, vitalityLight: nil, vitalityModerate: nil, vitalityHigh: nil,
                recoveryHours: nil
            )
        }

        /// Cumulative live readings every 20 minutes from 07:30, as a day of syncs would leave,
        /// and one for the last minute so far (a sync just now).
        private func liveReadings(_ s: MinuteSeries) -> [(Date, Int, Int, Int)] {
            var out: [(Date, Int, Int, Int)] = []
            var steps = 0, kcal = 0
            var lastHR = 0
            var last: (Date, Int, Int, Int)?
            for i in 0 ..< MinuteSeries.slots {
                let t = s.time(ofMinute: i)
                guard t < now else { break }
                steps += s.steps[i] ?? 0
                kcal += s.kcal[i] ?? 0
                if let hr = s.heartRate[i] { lastHR = hr }
                if i >= 450, i % 20 == 0 { out.append((t, steps, kcal, lastHR)) }
                last = (t, steps, kcal, lastHR)
            }
            if let last, out.last?.0 != last.0 { out.append(last) }
            return out
        }
    }
}

private extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(self, lo), hi) }
}

/// "Try with demo data": a separate, in-memory store seeded with 30 days of demo data, so people
/// without a band (and App Review) can see every screen. The real store, the band keys and the
/// hub account are never touched while it is on.
enum DemoMode {
    static let storageKey = "demoMode"

    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: storageKey) }
        set { UserDefaults.standard.set(newValue, forKey: storageKey) }
    }
}
