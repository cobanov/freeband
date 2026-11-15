import Foundation

/// What one scored day leaves behind for the baselines of the days after it.
struct HistoryPoint: Codable, Equatable, Sendable {
    var day: DayKey
    var restingHR: Double?
    var hrv: Double?
    var sleepScore: Double?
    var strain: Double?
    var midSleepMinute: Double?
    /// Sleep contributor values by name, for the 14-day medians shown next to them.
    var sleepValues: [String: Double] = [:]
}

struct NapSummary: Codable, Equatable, Sendable {
    var bedTime: Date
    var wakeTime: Date
    var minutes: Double
}

/// Everything known about one day, in plain values.
struct DayInputs: Sendable {
    var day: DayKey
    /// The day's minute file, if any.
    var minutes: MinuteSeries?
    /// The day before (a night starts there; the HR-dip reference is the evening before bed).
    var previousMinutes: MinuteSeries?
    /// Primary sleep sessions that end on this day (main sleep and naps).
    var sleeps: [SleepInput]
    /// Primary sessions that end on the day before.
    var previousSleeps: [SleepInput]
    /// The band's own resting HR from the daily summary.
    var bandRestingHR: Int?
    /// For today: minutes after this are not lived yet.
    var now: Date?

    init(day: DayKey, minutes: MinuteSeries? = nil, previousMinutes: MinuteSeries? = nil, sleeps: [SleepInput] = [],
         previousSleeps: [SleepInput] = [], bandRestingHR: Int? = nil, now: Date? = nil) {
        self.day = day
        self.minutes = minutes
        self.previousMinutes = previousMinutes
        self.sleeps = sleeps
        self.previousSleeps = previousSleeps
        self.bandRestingHR = bandRestingHR
        self.now = now
    }
}

struct DayScoreResult: Codable, Equatable, Sendable {
    var day: DayKey
    var algoVersion: Int
    var sleep: SleepScoreResult
    var recovery: RecoveryResult
    var strain: StrainResult?
    var strainConfidence: Confidence
    var restingHR: RestingHR?
    var hrv: HRVResult?
    /// Usable HRV windows found in the second half of the night.
    var hrvWindows: Int
    var hasRR: Bool
    var stress: StressSummary?
    var spo2: SpO2Summary?
    var naps: [NapSummary]

    var history: HistoryPoint {
        var values: [String: Double] = [:]
        for c in sleep.contributors {
            if let v = c.value { values[c.name.rawValue] = v }
        }
        return HistoryPoint(day: day, restingHR: restingHR?.value, hrv: hrv?.rmssd, sleepScore: sleep.score.map(Double.init),
                            strain: strain?.strain, midSleepMinute: sleep.metrics?.midSleepMinute, sleepValues: values)
    }
}

/// Scores days from plain inputs: sleep, recovery, strain, plus the shown-only stress and SpO2.
/// Pure and deterministic; the store side is DailyRollup.
enum ScoreEngine {
    /// Bump when any formula or constant in Analytics/ changes; stored scores with an older
    /// version are recomputed at launch.
    /// 2: the sleep score is capped at its duration sub-score + 10 (SleepScore.durationLead).
    static let algoVersion = 2

    static func score(_ input: DayInputs, history: [HistoryPoint], profile: Profile) -> DayScoreResult {
        let day = input.day
        let past = history
            .filter { $0.day < day && $0.day.index >= day.index - Baseline.lookbackDays }
            .sorted { $0.day > $1.day }

        // Main sleep: the longest non-nap session ending today; the rest are naps. (v1 does not
        // join a night the band split in two; the shorter part is listed with the naps.)
        let mainIndex = input.sleeps.indices.filter { !input.sleeps[$0].isNap }
            .max { input.sleeps[$0].inBedMinutes < input.sleeps[$1].inBedMinutes }
        let main = mainIndex.map { input.sleeps[$0] }
        let naps = input.sleeps.indices.filter { $0 != mainIndex }.map { input.sleeps[$0] }
        let minuteDays = [input.previousMinutes, input.minutes].compactMap { $0 }
        let allSleeps = input.sleeps + input.previousSleeps

        var metrics: SleepMetrics?
        if let main {
            let awakeMean = SleepMetricsCalc.awakeHRMean(before: main.bedTime, minutes: minuteDays, sleeps: allSleeps)
            metrics = SleepMetricsCalc.compute(main, minutes: minuteDays, awakeHRMean: awakeMean)
        }

        let previousMids = past.filter { $0.day.index >= day.index - SleepScore.regularityNights }.compactMap(\.midSleepMinute)
        var sleepBaselines: [SleepContributor.Name: Double] = [:]
        for name in SleepContributor.Name.allCases {
            let values = past.compactMap { $0.sleepValues[name.rawValue] }.prefix(Baseline.window)
            if let m = Stats.median(Array(values)) { sleepBaselines[name] = m }
        }
        let sleep = SleepScore.score(metrics, sleepNeedMinutes: profile.sleepNeed, previousMidSleeps: previousMids,
                                     baselines: sleepBaselines)

        let restingHR = RestingHR.compute(sleepLowest5Min: metrics?.hrLowest5Min, bandValue: input.bandRestingHR,
                                          minutes: input.minutes, sleeps: allSleeps)

        let hasRR = main?.rr.contains { !$0.intervalsMs.isEmpty } ?? false
        var hrv: HRVResult?
        var windows = 0
        if hasRR, let main {
            (hrv, windows) = HRV.nightly(main.rr, bedTime: main.bedTime, wakeTime: main.wakeTime)
        }

        let yesterday = day.adding(days: -1)
        let recovery = Recovery.score(Recovery.Inputs(
            hrv: hrv?.rmssd, hrvHistory: past.compactMap(\.hrv), hasRR: hasRR, hrvWindows: windows,
            restingHR: restingHR, restingHRHistory: past.compactMap(\.restingHR),
            sleepScore: sleep.score.map(Double.init), sleepHistory: past.compactMap(\.sleepScore),
            strainYesterday: past.first { $0.day == yesterday }?.strain,
            strainHistory: past.filter { $0.day < yesterday }.compactMap(\.strain)
        ))

        let strainRest = restingHR?.value ?? Baseline.compute(past.compactMap(\.restingHR), floor: .restingHR)?.median
        let strain = input.minutes.flatMap {
            Strain.compute($0, sleeps: allSleeps, restingHR: strainRest, profile: profile, now: input.now)
        }

        var spo2: SpO2Summary?
        if let m = metrics, let avg = m.spo2Average, let low = m.spo2Minimum {
            spo2 = SpO2Summary(average: avg, minimum: low, below90Minutes: m.spo2Below90Minutes ?? 0)
        }

        return DayScoreResult(
            day: day, algoVersion: algoVersion, sleep: sleep, recovery: recovery, strain: strain,
            strainConfidence: strain?.confidence ?? Confidence(.none, reasons: [ConfidenceReason(.noData)]),
            restingHR: restingHR, hrv: hrv, hrvWindows: windows, hasRR: hasRR,
            stress: input.minutes.flatMap(StressSummary.compute), spo2: spo2,
            naps: naps.map { NapSummary(bedTime: $0.bedTime, wakeTime: $0.wakeTime, minutes: $0.inBedMinutes) }
        )
    }

    /// Scores days in order; each day's result feeds the baselines of the days after it.
    /// `history`: points for days before the range (from stored scores).
    static func scoreRange(_ days: [DayInputs], history: [HistoryPoint], profile: Profile) -> [DayScoreResult] {
        var points: [DayKey: HistoryPoint] = [:]
        for p in history { points[p.day] = p }
        var out: [DayScoreResult] = []
        for input in days.sorted(by: { $0.day < $1.day }) {
            let result = score(input, history: Array(points.values), profile: profile)
            points[input.day] = result.history
            out.append(result)
        }
        return out
    }
}
