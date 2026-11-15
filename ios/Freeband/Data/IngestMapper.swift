import Foundation

// Parsed activity files -> plain drafts for the store (plan section 6: "saf IngestMapper").
// Foundation only: ios/tests/ingest compiles it with ActivityFiles.swift and Analytics/*.swift.
//
// Days: every value goes to the local day of the file's own UTC offset (fileID.tzQuarterHours),
// never the phone's. A night belongs to the day it ends on.

enum ParseStatus: String, Codable, Sendable, CaseIterable {
    /// Stored, not parsed yet (or replaced since).
    case pending
    case parsed
    /// Parsed with warnings (partial record, stream error, ...): what was read is kept.
    case partial
    /// Workouts, unknown kinds and unknown versions: kept raw only.
    case unsupported
    case error
    case crc
}

/// One file's minute values for one local day (or, merged, every file's).
struct MinuteDayDraft: Equatable, Sendable {
    var series: MinuteSeries
    var sourceFileIDs: [String]

    var day: DayKey { series.day }
    var recordCount: Int { series.recordCount }
}

/// The band's own daily summary (file kind daily_summary).
struct DaySummaryDraft: Equatable, Sendable {
    var day: DayKey
    var tzOffsetMinutes: Int
    var sourceFileID: String
    var fileVersion: Int
    var steps: Int?
    var activeCalories: Int?
    var calories: Int?
    var hrResting: Int?
    var hrMin: Int?
    var hrMax: Int?
    var hrAvg: Int?
    var stressAvg: Int?
    var stressMin: Int?
    var stressMax: Int?
    var standingMask: Int?
    var spo2Avg: Int?
    var spo2Min: Int?
    var spo2Max: Int?
    var trainingLoadDay: Int?
    var trainingLoadWeek: Int?
    var trainingLoadLevel: Int?
    var vitalityCurrent: Int?
    var vitalityLight: Int?
    var vitalityModerate: Int?
    var vitalityHigh: Int?
    var recoveryHours: Int?
}

enum SleepSourceKind: String, Codable, Sendable {
    /// ACTIVITY / SLEEP file: stage words, HR/SpO2 series, RR.
    case details
    /// ACTIVITY / SLEEP_STAGES file: phase changes only.
    case stages
}

struct SleepDraft: Equatable, Sendable {
    var sourceFileID: String
    var kind: SleepSourceKind
    var fileVersion: Int
    /// The local day the sleep ends on.
    var day: DayKey
    var tzOffsetMinutes: Int
    var bedTime: Date
    var wakeTime: Date
    var deepMinutes: Int?
    var lightMinutes: Int?
    var remMinutes: Int?
    var awakeMinutes: Int?
    var segments: [StageSegment]
    var hrStart: Date?
    var hrIntervalSeconds: Int
    var hrValues: [Int]
    var spo2Start: Date?
    var spo2IntervalSeconds: Int
    var spo2Values: [Int]
    var wakeCount: Int?
    var sleepQuality: Int?
    var isNap: Bool
    var rr: [RRSegment]
    /// False when another file describes the same sleep better (see IngestMapper.primaryFlags).
    var isPrimary = true

    var durationMinutes: Double { wakeTime.timeIntervalSince(bedTime) / 60 }
    var rrBeats: Int { rr.reduce(0) { $0 + $1.intervalsMs.count } }

    static func series(start: Date?, interval: Int, values: [Int]) -> [TimedValue] {
        guard let start else { return [] }
        return values.enumerated().map { TimedValue(ts: start.addingTimeInterval(TimeInterval(interval * $0.offset)), value: $0.element) }
    }

    var input: SleepInput {
        SleepInput(bedTime: bedTime, wakeTime: wakeTime, tzOffsetMinutes: tzOffsetMinutes, deepMinutes: deepMinutes,
                   lightMinutes: lightMinutes, remMinutes: remMinutes, awakeMinutes: awakeMinutes, segments: segments,
                   wakeCount: wakeCount,
                   heartRate: Self.series(start: hrStart, interval: hrIntervalSeconds, values: hrValues),
                   hrIntervalSeconds: hrIntervalSeconds,
                   spo2: Self.series(start: spo2Start, interval: spo2IntervalSeconds, values: spo2Values),
                   spo2IntervalSeconds: spo2IntervalSeconds, rr: rr, isNap: isNap)
    }
}

struct ManualReadingDraft: Equatable, Sendable {
    var sourceFileID: String
    var ts: Date
    var day: DayKey
    var kind: String
    var value: Int
    var celsius: Double?
}

/// Everything one file yields.
struct IngestOutput: Sendable {
    var fileID: String
    var kind: ActivityFileKind
    var version: Int
    var status: ParseStatus
    var note: String
    var warnings: [String]
    var minuteParts: [MinuteDayDraft] = []
    var summary: DaySummaryDraft?
    var sleeps: [SleepDraft] = []
    var manual: [ManualReadingDraft] = []
    /// DailyDetails records in the file (all days).
    var minuteRecords: Int?

    /// Every local day this file feeds.
    var touchedDays: Set<DayKey> {
        var days = Set(minuteParts.map(\.day))
        if let summary { days.insert(summary.day) }
        days.formUnion(sleeps.map(\.day))
        days.formUnion(manual.map(\.day))
        return days
    }
}

enum IngestMapper {
    // MARK: status

    static func status(of result: ActivityParseResult) -> ParseStatus {
        switch result.payload {
        case .error(.crcMismatch): return .crc
        case .error: return .error
        case .unsupported: return .unsupported
        default: return result.warnings.isEmpty ? .parsed : .partial
        }
    }

    // MARK: map

    /// `fileHex`: the id the file was stored under (the file's own id when nil).
    static func map(_ result: ActivityParseResult, fileHex: String? = nil) -> IngestOutput {
        let hex = fileHex ?? result.fileID?.hex ?? ""
        var out = IngestOutput(fileID: hex, kind: result.kind, version: Int(result.fileID?.version ?? 0),
                               status: status(of: result), note: result.description, warnings: result.warnings)
        guard let id = result.fileID else { return out }
        let tz = id.utcOffsetMinutes
        switch result.payload {
        case let .dailyDetails(d):
            out.minuteParts = minuteParts(d, tzOffsetMinutes: tz, hex: hex)
            out.minuteRecords = d.records.count
        case let .dailySummary(s):
            out.summary = summary(s, tzOffsetMinutes: tz, hex: hex)
        case let .sleepDetails(s):
            if let draft = sleepDraft(details: s, tzOffsetMinutes: tz, hex: hex) { out.sleeps = [draft] }
        case let .sleepStages(s):
            if let draft = sleepDraft(stages: s, tzOffsetMinutes: tz, hex: hex) { out.sleeps = [draft] }
        case let .manualSamples(m):
            out.manual = m.samples.map { sample in
                ManualReadingDraft(sourceFileID: hex, ts: sample.ts, day: DayKey(date: sample.ts, offsetMinutes: tz),
                                   kind: sample.kind.rawValue, value: sample.value, celsius: sample.celsius)
            }
        case .empty, .unsupported, .error:
            break
        }
        return out
    }

    // MARK: minutes

    /// Splits a minute file by local day. Zero means "not measured" for HR, SpO2 and stress and
    /// "none" for energy (docs/ACTIVITY.md 6.1); steps, kcal and distance keep their zeros.
    static func minuteParts(_ d: DailyDetails, tzOffsetMinutes tz: Int, hex: String) -> [MinuteDayDraft] {
        var days: [DayKey: MinuteSeries] = [:]
        for rec in d.records {
            let day = DayKey(date: rec.ts, offsetMinutes: tz)
            guard let m = day.minute(of: rec.ts, offsetMinutes: tz) else { continue }
            var s = days[day] ?? MinuteSeries(day: day, tzOffsetMinutes: tz)
            s.steps[m] = rec.steps
            s.kcal[m] = rec.activeCalories
            s.distance[m] = rec.distanceMeters
            s.heartRate[m] = rec.heartRate.flatMap { $0 > 0 && $0 < 255 ? $0 : nil }
            s.energy[m] = rec.energy.flatMap { $0 > 0 && $0 < 255 ? $0 : nil }
            s.spo2[m] = rec.spo2.flatMap { $0 > 0 && $0 < 255 ? $0 : nil }
            s.stress[m] = rec.stress.flatMap { $0 > 0 && $0 < 255 ? $0 : nil }
            days[day] = s
        }
        return days.keys.sorted().compactMap { day in days[day].map { MinuteDayDraft(series: $0, sourceFileIDs: [hex]) } }
    }

    /// Joins the parts of one day from several files. Parts are applied in file order (by the
    /// id's time stamp); a later file overwrites a minute only where it has a value. Nil when
    /// the parts are empty or for different days.
    static func mergeMinuteParts(_ parts: [MinuteDayDraft]) -> MinuteDayDraft? {
        guard let first = parts.first, parts.allSatisfy({ $0.day == first.day }) else { return nil }
        let ordered = parts.sorted { a, b in
            let ka = fileOrder(a.sourceFileIDs.first ?? ""), kb = fileOrder(b.sourceFileIDs.first ?? "")
            return ka == kb ? (a.sourceFileIDs.first ?? "") < (b.sourceFileIDs.first ?? "") : ka < kb
        }
        var merged = MinuteSeries(day: first.day, tzOffsetMinutes: ordered.last?.series.tzOffsetMinutes ?? 0)
        var sources: [String] = []
        for part in ordered {
            let s = part.series
            for i in 0 ..< MinuteSeries.slots {
                if let v = s.steps[i] { merged.steps[i] = v }
                if let v = s.heartRate[i] { merged.heartRate[i] = v }
                if let v = s.spo2[i] { merged.spo2[i] = v }
                if let v = s.stress[i] { merged.stress[i] = v }
                if let v = s.kcal[i] { merged.kcal[i] = v }
                if let v = s.distance[i] { merged.distance[i] = v }
                if let v = s.energy[i] { merged.energy[i] = v }
            }
            for id in part.sourceFileIDs where !sources.contains(id) { sources.append(id) }
        }
        return MinuteDayDraft(series: merged, sourceFileIDs: sources)
    }

    /// File time stamp from a stored hex id (little-endian u32 in the first 4 bytes).
    static func fileOrder(_ hex: String) -> UInt32 {
        let bytes = Array(hex.utf8)
        guard bytes.count >= 8 else { return 0 }
        func nibble(_ c: UInt8) -> UInt32 {
            switch c {
            case 48 ... 57: return UInt32(c - 48)
            case 97 ... 102: return UInt32(c - 87)
            case 65 ... 70: return UInt32(c - 55)
            default: return 0
            }
        }
        var ts: UInt32 = 0
        for i in 0 ..< 4 {
            ts |= (nibble(bytes[2 * i]) << 4 | nibble(bytes[2 * i + 1])) << UInt32(8 * i)
        }
        return ts
    }

    // MARK: summary

    static func summary(_ s: DailySummary, tzOffsetMinutes tz: Int, hex: String) -> DaySummaryDraft {
        DaySummaryDraft(
            day: DayKey(date: s.day, offsetMinutes: tz), tzOffsetMinutes: tz, sourceFileID: hex, fileVersion: Int(s.version),
            steps: s.steps, activeCalories: s.activeCalories, calories: s.calories, hrResting: s.hrResting,
            hrMin: s.hrMin, hrMax: s.hrMax, hrAvg: s.hrAvg, stressAvg: s.stressAvg, stressMin: s.stressMin,
            stressMax: s.stressMax, standingMask: s.standing, spo2Avg: s.spo2Avg, spo2Min: s.spo2Min, spo2Max: s.spo2Max,
            trainingLoadDay: s.trainingLoadDay, trainingLoadWeek: s.trainingLoadWeek, trainingLoadLevel: s.trainingLoadLevel,
            vitalityCurrent: s.vitalityCurrent, vitalityLight: s.vitalityIncreaseLight,
            vitalityModerate: s.vitalityIncreaseModerate, vitalityHigh: s.vitalityIncreaseHigh,
            recoveryHours: s.recoveryHours
        )
    }

    // MARK: sleep

    static func stageKind(_ s: SleepStage) -> StageKind {
        switch s {
        case .awake: return .awake
        case .light: return .light
        case .deep: return .deep
        case .rem: return .rem
        case .notSleep: return .notSleep
        case .unknown: return .unknown
        }
    }

    /// Plan section 5: a sleep that starts between 10:00 and 20:00 local time and lasts under
    /// 3 hours is a nap.
    static func isNap(bedTime: Date, wakeTime: Date, tzOffsetMinutes tz: Int) -> Bool {
        let local = Int64(bedTime.timeIntervalSince1970) + Int64(tz) * 60
        let secondOfDay = ((local % 86_400) + 86_400) % 86_400
        let hour = Int(secondOfDay / 3600)
        return (10 ..< 20).contains(hour) && wakeTime.timeIntervalSince(bedTime) < 3 * 3600
    }

    static func sleepDraft(details d: SleepDetails, tzOffsetMinutes tz: Int, hex: String) -> SleepDraft? {
        guard let session = d.session else { return nil }
        let segments = d.nightStages.compactMap { s -> StageSegment? in
            guard let m = s.durationMinutes, m > 0 else { return nil }
            return StageSegment(start: s.ts, minutes: m, stage: stageKind(s.stage))
        }
        return SleepDraft(
            sourceFileID: hex, kind: .details, fileVersion: Int(d.version),
            day: DayKey(date: session.wakeTime, offsetMinutes: tz), tzOffsetMinutes: tz,
            bedTime: session.bedTime, wakeTime: session.wakeTime,
            deepMinutes: session.deepMinutes, lightMinutes: session.lightMinutes, remMinutes: session.remMinutes,
            awakeMinutes: session.awakeMinutes, segments: segments,
            hrStart: d.heartRate?.firstTs, hrIntervalSeconds: d.heartRate.map { max($0.unit, 1) } ?? 60,
            hrValues: d.heartRate?.values ?? [],
            spo2Start: d.spo2?.firstTs, spo2IntervalSeconds: d.spo2.map { max($0.unit, 1) } ?? 60,
            spo2Values: d.spo2?.values ?? [],
            wakeCount: d.summaries.last?.wakeCount ?? (d.sessionFromSpans ? d.sleepSpans.count - 1 : nil),
            sleepQuality: d.sleepQuality,
            isNap: isNap(bedTime: session.bedTime, wakeTime: session.wakeTime, tzOffsetMinutes: tz),
            rr: d.rrIntervals.filter { !$0.intervalsMs.isEmpty }.map { RRSegment(tsRaw: $0.tsRaw, intervalsMs: $0.intervalsMs) }
        )
    }

    /// Phase changes become segments: each lasts until the next change, the last until wake time.
    static func sleepDraft(stages s: SleepStages, tzOffsetMinutes tz: Int, hex: String) -> SleepDraft? {
        guard let session = s.session, session.wakeTime > session.bedTime else { return nil }
        let changes = s.stages.sorted { $0.ts < $1.ts }
        var segments: [StageSegment] = []
        for (i, c) in changes.enumerated() {
            let end = i + 1 < changes.count ? changes[i + 1].ts : session.wakeTime
            let minutes = Int((end.timeIntervalSince(c.ts) / 60).rounded())
            guard minutes > 0 else { continue }
            segments.append(StageSegment(start: c.ts, minutes: minutes, stage: stageKind(c.stage)))
        }
        return SleepDraft(
            sourceFileID: hex, kind: .stages, fileVersion: Int(s.version),
            day: DayKey(date: session.wakeTime, offsetMinutes: tz), tzOffsetMinutes: tz,
            bedTime: session.bedTime, wakeTime: session.wakeTime,
            deepMinutes: session.deepMinutes, lightMinutes: session.lightMinutes, remMinutes: session.remMinutes,
            awakeMinutes: session.awakeMinutes, segments: segments,
            hrStart: nil, hrIntervalSeconds: 60, hrValues: [], spo2Start: nil, spo2IntervalSeconds: 60, spo2Values: [],
            wakeCount: nil, sleepQuality: nil,
            isNap: isNap(bedTime: session.bedTime, wakeTime: session.wakeTime, tzOffsetMinutes: tz), rr: []
        )
    }

    /// Two drafts describe the same sleep when they share the bed time or overlap by more than
    /// half of the shorter one.
    static func sameSleep(_ a: SleepDraft, _ b: SleepDraft) -> Bool {
        if a.bedTime == b.bedTime { return true }
        let overlap = min(a.wakeTime, b.wakeTime).timeIntervalSince(max(a.bedTime, b.bedTime))
        let shorter = min(a.wakeTime.timeIntervalSince(a.bedTime), b.wakeTime.timeIntervalSince(b.bedTime))
        return overlap > 0 && overlap > shorter / 2
    }

    /// Merge rule (plan section 6): a sleep details file beats a sleep stages file; between files
    /// of the same kind the later wake time wins (same bed time, growing wake time: the newest
    /// file of the night); then the longer one; then the larger source id, so the choice is stable.
    static func better(_ a: SleepDraft, than b: SleepDraft) -> Bool {
        if a.kind != b.kind { return a.kind == .details }
        if a.wakeTime != b.wakeTime { return a.wakeTime > b.wakeTime }
        if a.bedTime != b.bedTime { return a.bedTime < b.bedTime }
        return a.sourceFileID > b.sourceFileID
    }

    /// For each draft: true when no draft describing the same sleep beats it.
    static func primaryFlags(_ sleeps: [SleepDraft]) -> [Bool] {
        sleeps.indices.map { i in
            !sleeps.indices.contains { j in j != i && sameSleep(sleeps[i], sleeps[j]) && better(sleeps[j], than: sleeps[i]) }
        }
    }
}
