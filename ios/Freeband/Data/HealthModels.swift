import Foundation
import SwiftData

// Data derived from the band's activity files (plan section 6). Every row carries `bandID` and,
// where it comes from one file, `sourceFileID` (the file id in hex): ingest deletes by source
// and inserts again, so parsing a file twice gives the same rows. No #Unique (iOS 17, Swift 5
// mode): uniqueness is kept in code (ActivityIngest, DailyRollup).
//
// Days are local days in the file's own UTC offset, as "yyyy-MM-dd" (`day`) and as days since
// 1970-01-01 (`dayIndex`, what queries use).
//
// All new attributes have defaults so the existing store migrates lightweight.

/// One local day of minute values. Each array is 1440 slots packed little-endian (see
/// `Packed`): UInt16 for steps and distance (0xFFFF = no value), UInt8 for the rest
/// (0xFF = no value). A row per day instead of a row per minute: 90 days would be 130k rows.
@Model
final class MinuteDay {
    var bandID: UUID = UUID()
    var day: String = ""
    var dayIndex: Int = 0
    /// The band's UTC offset for this day, minutes east.
    var tzOffsetMinutes: Int = 0
    var steps: Data = Data()
    var heartRate: Data = Data()
    var spo2: Data = Data()
    var stress: Data = Data()
    /// Active kcal per minute.
    var kcal: Data = Data()
    /// Metres per minute.
    var distance: Data = Data()
    var energy: Data = Data()
    /// Activity level per minute, packed like the others (added with parser version 5).
    var activity: Data = Data()
    /// The minute files merged into this day, in file order.
    var sourceFileIDs: [String] = []
    var recordCount: Int = 0
    var updatedAt: Date = Date()

    init(bandID: UUID, draft: MinuteDayDraft) {
        self.bandID = bandID
        update(from: draft)
    }

    func update(from draft: MinuteDayDraft) {
        let s = draft.series
        day = s.day.string
        dayIndex = s.day.index
        tzOffsetMinutes = s.tzOffsetMinutes
        steps = Packed.pack16(s.steps)
        heartRate = Packed.pack8(s.heartRate)
        spo2 = Packed.pack8(s.spo2)
        stress = Packed.pack8(s.stress)
        kcal = Packed.pack8(s.kcal)
        distance = Packed.pack16(s.distance)
        energy = Packed.pack8(s.energy)
        activity = Packed.pack8(s.activityLevel)
        sourceFileIDs = draft.sourceFileIDs
        recordCount = draft.recordCount
        updatedAt = Date()
    }

    var dayKey: DayKey { DayKey(index: dayIndex) }

    var series: MinuteSeries {
        var s = MinuteSeries(day: dayKey, tzOffsetMinutes: tzOffsetMinutes)
        let n = MinuteSeries.slots
        s.steps = Packed.unpack16(steps, count: n)
        s.heartRate = Packed.unpack8(heartRate, count: n)
        s.spo2 = Packed.unpack8(spo2, count: n)
        s.stress = Packed.unpack8(stress, count: n)
        s.kcal = Packed.unpack8(kcal, count: n)
        s.distance = Packed.unpack16(distance, count: n)
        s.energy = Packed.unpack8(energy, count: n)
        s.activityLevel = Packed.unpack8(activity, count: n)
        return s
    }

    var draft: MinuteDayDraft { MinuteDayDraft(series: series, sourceFileIDs: sourceFileIDs) }
}

/// The band's own daily summary for one day.
@Model
final class DaySummary {
    var bandID: UUID = UUID()
    var day: String = ""
    var dayIndex: Int = 0
    var tzOffsetMinutes: Int = 0
    var sourceFileID: String = ""
    var fileVersion: Int = 0
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
    /// Bit h set: stood during hour h.
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
    var updatedAt: Date = Date()

    init(bandID: UUID, draft d: DaySummaryDraft) {
        self.bandID = bandID
        day = d.day.string
        dayIndex = d.day.index
        tzOffsetMinutes = d.tzOffsetMinutes
        sourceFileID = d.sourceFileID
        fileVersion = d.fileVersion
        steps = d.steps
        activeCalories = d.activeCalories
        calories = d.calories
        hrResting = d.hrResting
        hrMin = d.hrMin
        hrMax = d.hrMax
        hrAvg = d.hrAvg
        stressAvg = d.stressAvg
        stressMin = d.stressMin
        stressMax = d.stressMax
        standingMask = d.standingMask
        spo2Avg = d.spo2Avg
        spo2Min = d.spo2Min
        spo2Max = d.spo2Max
        trainingLoadDay = d.trainingLoadDay
        trainingLoadWeek = d.trainingLoadWeek
        trainingLoadLevel = d.trainingLoadLevel
        vitalityCurrent = d.vitalityCurrent
        vitalityLight = d.vitalityLight
        vitalityModerate = d.vitalityModerate
        vitalityHigh = d.vitalityHigh
        recoveryHours = d.recoveryHours
        updatedAt = Date()
    }

    var draft: DaySummaryDraft {
        DaySummaryDraft(day: DayKey(index: dayIndex), tzOffsetMinutes: tzOffsetMinutes, sourceFileID: sourceFileID,
                        fileVersion: fileVersion, steps: steps, activeCalories: activeCalories, calories: calories,
                        hrResting: hrResting, hrMin: hrMin, hrMax: hrMax, hrAvg: hrAvg, stressAvg: stressAvg,
                        stressMin: stressMin, stressMax: stressMax, standingMask: standingMask, spo2Avg: spo2Avg,
                        spo2Min: spo2Min, spo2Max: spo2Max, trainingLoadDay: trainingLoadDay,
                        trainingLoadWeek: trainingLoadWeek, trainingLoadLevel: trainingLoadLevel,
                        vitalityCurrent: vitalityCurrent, vitalityLight: vitalityLight,
                        vitalityModerate: vitalityModerate, vitalityHigh: vitalityHigh, recoveryHours: recoveryHours)
    }
}

/// One sleep (night or nap) from one file. The plan calls it `SleepSession`; that name is taken
/// by the parser's value type in Band/ActivityFiles.swift, so the stored model is SleepRecord.
/// Several files can describe the same sleep; `isPrimary` marks the one analytics uses
/// (sleep details over sleep stages, then the latest wake time).
@Model
final class SleepRecord {
    var bandID: UUID = UUID()
    var sourceFileID: String = ""
    /// "details" (sleep file) or "stages" (sleep stages file).
    var kind: String = "details"
    var fileVersion: Int = 0
    var bedTime: Date = Date()
    var wakeTime: Date = Date()
    /// The local day the sleep ends on.
    var day: String = ""
    var dayIndex: Int = 0
    var tzOffsetMinutes: Int = 0
    var deepMinutes: Int?
    var lightMinutes: Int?
    var remMinutes: Int?
    var awakeMinutes: Int?
    /// Packed StageSegment list (7 bytes each).
    var stageTimeline: Data = Data()
    var hrStart: Date?
    var hrIntervalSeconds: Int = 60
    /// UInt8 per sample, raw.
    var hrValues: Data = Data()
    var spo2Start: Date?
    var spo2IntervalSeconds: Int = 60
    var spo2Values: Data = Data()
    var wakeCount: Int?
    var sleepQuality: Int?
    var isNap: Bool = false
    var isPrimary: Bool = true
    var hasRR: Bool = false
    var updatedAt: Date = Date()

    init(bandID: UUID, draft d: SleepDraft) {
        self.bandID = bandID
        sourceFileID = d.sourceFileID
        kind = d.kind.rawValue
        fileVersion = d.fileVersion
        bedTime = d.bedTime
        wakeTime = d.wakeTime
        day = d.day.string
        dayIndex = d.day.index
        tzOffsetMinutes = d.tzOffsetMinutes
        deepMinutes = d.deepMinutes
        lightMinutes = d.lightMinutes
        remMinutes = d.remMinutes
        awakeMinutes = d.awakeMinutes
        stageTimeline = StageSegment.pack(d.segments)
        hrStart = d.hrStart
        hrIntervalSeconds = d.hrIntervalSeconds
        hrValues = Data(d.hrValues.map { UInt8(clamping: $0) })
        spo2Start = d.spo2Start
        spo2IntervalSeconds = d.spo2IntervalSeconds
        spo2Values = Data(d.spo2Values.map { UInt8(clamping: $0) })
        wakeCount = d.wakeCount
        sleepQuality = d.sleepQuality
        isNap = d.isNap
        isPrimary = d.isPrimary
        hasRR = d.rrBeats > 0
        updatedAt = Date()
    }

    /// The draft back, with RR when given (RR lives in SleepRR).
    func draft(rr: [RRSegment] = []) -> SleepDraft {
        SleepDraft(sourceFileID: sourceFileID, kind: SleepSourceKind(rawValue: kind) ?? .details, fileVersion: fileVersion,
                   day: DayKey(index: dayIndex), tzOffsetMinutes: tzOffsetMinutes, bedTime: bedTime, wakeTime: wakeTime,
                   deepMinutes: deepMinutes, lightMinutes: lightMinutes, remMinutes: remMinutes, awakeMinutes: awakeMinutes,
                   segments: StageSegment.unpack(stageTimeline), hrStart: hrStart, hrIntervalSeconds: hrIntervalSeconds,
                   hrValues: hrValues.map(Int.init), spo2Start: spo2Start, spo2IntervalSeconds: spo2IntervalSeconds,
                   spo2Values: spo2Values.map(Int.init), wakeCount: wakeCount, sleepQuality: sleepQuality, isNap: isNap,
                   rr: rr, isPrimary: isPrimary)
    }

    var totalSleepMinutes: Int? {
        guard deepMinutes != nil || lightMinutes != nil || remMinutes != nil else { return nil }
        return (deepMinutes ?? 0) + (lightMinutes ?? 0) + (remMinutes ?? 0)
    }
}

/// RR intervals of one sleep file, kept apart from SleepRecord because they are large
/// (one UInt16 per beat).
@Model
final class SleepRR {
    var bandID: UUID = UUID()
    var sourceFileID: String = ""
    var bedTime: Date = Date()
    var day: String = ""
    var dayIndex: Int = 0
    /// UInt16 LE milliseconds, all packets back to back.
    @Attribute(.externalStorage) var intervals: Data = Data()
    /// Per packet: tsRaw i64 | count u32 (RRSegment.packIndex).
    var segmentIndex: Data = Data()
    var beatCount: Int = 0
    var updatedAt: Date = Date()

    init(bandID: UUID, draft d: SleepDraft) {
        self.bandID = bandID
        sourceFileID = d.sourceFileID
        bedTime = d.bedTime
        day = d.day.string
        dayIndex = d.day.index
        intervals = Packed.packU16(d.rr.flatMap(\.intervalsMs))
        segmentIndex = RRSegment.packIndex(d.rr)
        beatCount = d.rrBeats
        updatedAt = Date()
    }

    var segments: [RRSegment] { RRSegment.unpack(index: segmentIndex, intervals: intervals) }
}

/// A spot measurement the user started on the band (HR, SpO2, stress, temperature).
@Model
final class ManualReading {
    var bandID: UUID = UUID()
    var sourceFileID: String = ""
    var ts: Date = Date()
    var day: String = ""
    var dayIndex: Int = 0
    /// heart_rate, spo2, stress, temperature.
    var kind: String = ""
    var value: Int = 0
    var celsius: Double?

    init(bandID: UUID, draft d: ManualReadingDraft) {
        self.bandID = bandID
        sourceFileID = d.sourceFileID
        ts = d.ts
        day = d.day.string
        dayIndex = d.day.index
        kind = d.kind
        value = d.value
        celsius = d.celsius
    }
}

/// The three scores of one day with their confidences and every contributor (as JSON: the
/// encoded DayScoreResult), so the UI can show how each was computed.
@Model
final class DailyScore {
    var bandID: UUID = UUID()
    var day: String = ""
    var dayIndex: Int = 0
    var sleepScore: Int?
    var sleepConfidence: String = "none"
    var sleepEstimated: Bool = false
    var recoveryScore: Int?
    var recoveryConfidence: String = "none"
    var strain: Double?
    var strainConfidence: String = "none"
    var rhr: Double?
    /// sleep / band / daytime.
    var rhrSource: String?
    /// Nightly RMSSD, ms (approximate: 10 ms RR resolution).
    var hrv: Double?
    var midSleepMinute: Double?
    /// JSON of DayScoreResult.
    var contributors: Data = Data()
    var algoVersion: Int = 0
    var computedAt: Date = Date()

    init(bandID: UUID, result: DayScoreResult) {
        self.bandID = bandID
        update(from: result)
    }

    func update(from r: DayScoreResult) {
        day = r.day.string
        dayIndex = r.day.index
        sleepScore = r.sleep.score
        sleepConfidence = r.sleep.confidence.level.rawValue
        sleepEstimated = r.sleep.estimated
        recoveryScore = r.recovery.score
        recoveryConfidence = r.recovery.confidence.level.rawValue
        strain = r.strain?.strain
        strainConfidence = r.strainConfidence.level.rawValue
        rhr = r.restingHR?.value
        rhrSource = r.restingHR?.source.rawValue
        hrv = r.hrv?.rmssd
        midSleepMinute = r.sleep.metrics?.midSleepMinute
        contributors = Self.encode(r)
        algoVersion = r.algoVersion
        computedAt = Date()
    }

    var dayKey: DayKey { DayKey(index: dayIndex) }

    /// The full result, nil when the JSON is from another algorithm shape.
    var result: DayScoreResult? { Self.decode(contributors) }

    /// What later days' baselines need, read from the stored row.
    var historyPoint: HistoryPoint {
        var point = HistoryPoint(day: dayKey, restingHR: rhr, hrv: hrv, sleepScore: sleepScore.map(Double.init),
                                 strain: strain, midSleepMinute: midSleepMinute)
        if let r = result { point.sleepValues = r.history.sleepValues }
        return point
    }

    static func encode(_ r: DayScoreResult) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(r)) ?? Data()
    }

    static func decode(_ data: Data) -> DayScoreResult? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(DayScoreResult.self, from: data)
    }
}
