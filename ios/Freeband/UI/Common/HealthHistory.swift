import SwiftData
import SwiftUI

extension DayKey {
    /// Local midnight in the phone's time zone.
    var date: Date {
        let guess = Date(timeIntervalSince1970: TimeInterval(index) * 86_400)
        return start(offsetMinutes: TimeZone.current.secondsFromGMT(for: guess) / 60)
    }

    /// Noon of the day: safe for calendar arithmetic and formatting around DST changes.
    var noon: Date { date.addingTimeInterval(12 * 3600) }
}

/// One band's derived rows (scores, the band's daily summaries, primary sleeps), indexed by day.
/// Built per render from @Query arrays; decoded score results are cached for that render.
@MainActor
final class HealthHistory {
    let bandID: UUID
    private let scores: [Int: DailyScore]
    private let summaries: [Int: DaySummary]
    private let sleeps: [Int: [SleepRecord]]
    private var results: [Int: DayScoreResult?] = [:]

    init(bandID: UUID, scores: [DailyScore], summaries: [DaySummary], sleeps: [SleepRecord]) {
        self.bandID = bandID
        var byDay: [Int: DailyScore] = [:]
        for s in scores { byDay[s.dayIndex] = s }
        self.scores = byDay
        var sums: [Int: DaySummary] = [:]
        for s in summaries where (s.steps ?? -1) >= (sums[s.dayIndex]?.steps ?? -1) { sums[s.dayIndex] = s }
        self.summaries = sums
        self.sleeps = Dictionary(grouping: sleeps, by: \.dayIndex)
    }

    var isEmpty: Bool { scores.isEmpty && summaries.isEmpty && sleeps.isEmpty }

    /// The latest day with any data.
    var lastDay: DayKey? {
        [scores.keys.max(), summaries.keys.max(), sleeps.keys.max()].compactMap { $0 }.max().map(DayKey.init(index:))
    }

    var firstDay: DayKey? {
        [scores.keys.min(), summaries.keys.min(), sleeps.keys.min()].compactMap { $0 }.min().map(DayKey.init(index:))
    }

    func score(_ day: DayKey) -> DailyScore? { scores[day.index] }

    func result(_ day: DayKey) -> DayScoreResult? {
        if let cached = results[day.index] { return cached }
        let decoded = scores[day.index]?.result
        results[day.index] = decoded
        return decoded
    }

    func summary(_ day: DayKey) -> DaySummary? { summaries[day.index] }

    /// The night that ends on `day`: the longest primary sleep that is not a nap.
    func mainSleep(_ day: DayKey) -> SleepRecord? {
        (sleeps[day.index] ?? []).filter { !$0.isNap }.max { $0.wakeTime.timeIntervalSince($0.bedTime) < $1.wakeTime.timeIntervalSince($1.bedTime) }
    }

    func naps(_ day: DayKey) -> [SleepRecord] {
        let main = mainSleep(day)
        return (sleeps[day.index] ?? []).filter { $0 !== main }.sorted { $0.bedTime < $1.bedTime }
    }

    /// Days with a night, oldest first.
    var nights: [DayKey] {
        sleeps.keys.sorted().map(DayKey.init(index:)).filter { mainSleep($0) != nil }
    }

    func sleepMinutes(_ day: DayKey) -> Double? {
        result(day)?.sleep.metrics?.totalSleepMinutes ?? mainSleep(day)?.totalSleepMinutes.map(Double.init)
    }

    func activeMinutes(_ day: DayKey) -> Int? {
        result(day)?.strain.map { $0.zoneMinutes.dropFirst().reduce(0, +) }
    }

    func score(_ kind: ScoreKind, _ day: DayKey) -> Double? {
        switch kind {
        case .sleep: score(day)?.sleepScore.map(Double.init)
        case .recovery: score(day)?.recoveryScore.map(Double.init)
        case .strain: score(day)?.strain
        }
    }

    func confidence(_ kind: ScoreKind, _ day: DayKey) -> Confidence? {
        guard let r = result(day) else { return nil }
        switch kind {
        case .sleep: return r.sleep.confidence
        case .recovery: return r.recovery.confidence
        case .strain: return r.strainConfidence
        }
    }

    func value(_ metric: TrendMetric, on day: DayKey) -> Double? {
        switch metric {
        case .recovery: score(.recovery, day)
        case .sleepScore: score(.sleep, day)
        case .strain: score(.strain, day)
        case .sleepHours: sleepMinutes(day).map { $0 / 60 }
        case .restingHeartRate: score(day)?.rhr ?? summary(day)?.hrResting.map(Double.init)
        case .steps: summary(day)?.steps.map(Double.init)
        case .bloodOxygen: result(day)?.spo2?.average ?? summary(day)?.spo2Avg.map(Double.init)
        case .stress: result(day)?.stress?.average ?? summary(day)?.stressAvg.map(Double.init)
        case .activeMinutes: activeMinutes(day).map(Double.init)
        }
    }

    /// What stands out on `day` (Insights). 90 days back: 60 for a baseline, and room for the
    /// days of a run to have their own.
    func insights(_ day: DayKey, sleepNeedMinutes: Int) -> [Insight] {
        let days = (0 ..< 90).map { back -> InsightDay in
            let d = day.adding(days: -back)
            // A nap pays back debt: the day's sleep is the night plus its naps.
            let naps = napMinutes(d)
            return InsightDay(day: d, restingHR: settledRestingHR(d), hrv: score(d)?.hrv, sleepMinutes: sleepMinutes(d).map { $0 + naps },
                              midSleepMinute: score(d)?.midSleepMinute, strain: score(.strain, d), recovery: score(.recovery, d))
        }
        return Insights.compute(day: day, history: days, sleepNeedMinutes: Double(sleepNeedMinutes))
    }

    /// Daily points ending on `end`, oldest first; days without data are nil (they break lines).
    func points(_ metric: TrendMetric, ending end: DayKey, days: Int = 90,
                override: [DayKey: Double] = [:]) -> [TrendPoint] {
        (0..<days).reversed().map { back in
            let day = end.adding(days: -back)
            return TrendPoint(date: day.date, value: override[day] ?? settledValue(metric, on: day))
        }
    }

    /// Mean of the 7 days before `day` (not counting it).
    func average(_ metric: TrendMetric, before day: DayKey, days: Int = 7) -> Double? {
        let values = (1...days).compactMap { settledValue(metric, on: day.adding(days: -$0)) }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// Valid days of a metric in the 14 days before `day` (the baseline window).
    func baselineDays(_ metric: TrendMetric, before day: DayKey) -> Int {
        (1...Baseline.window).filter { settledValue(metric, on: day.adding(days: -$0)) != nil }.count
    }

    /// 14-day median before `day`.
    func median(_ metric: TrendMetric, before day: DayKey) -> Double? {
        let values = (1...Baseline.window).compactMap { settledValue(metric, on: day.adding(days: -$0)) }.sorted()
        guard !values.isEmpty else { return nil }
        let mid = values.count / 2
        return values.count % 2 == 0 ? (values[mid - 1] + values[mid]) / 2 : values[mid]
    }
}

/// Runs the band's queries and hands their rows to `content` as a HealthHistory.
struct BandHealthReader<Content: View>: View {
    let band: Band
    @Query private var scores: [DailyScore]
    @Query private var summaries: [DaySummary]
    @Query private var sleeps: [SleepRecord]
    private let content: (HealthHistory) -> Content

    init(band: Band, @ViewBuilder content: @escaping (HealthHistory) -> Content) {
        self.band = band
        self.content = content
        let id = band.id
        _scores = Query(filter: #Predicate<DailyScore> { $0.bandID == id }, sort: \DailyScore.dayIndex)
        _summaries = Query(filter: #Predicate<DaySummary> { $0.bandID == id }, sort: \DaySummary.dayIndex)
        _sleeps = Query(filter: #Predicate<SleepRecord> { $0.bandID == id && $0.isPrimary }, sort: \SleepRecord.bedTime)
    }

    var body: some View {
        content(HealthHistory(bandID: band.id, scores: scores, summaries: summaries, sleeps: sleeps))
    }
}

/// One calendar day as the analysis charts draw it.
struct AnalysisRow: Identifiable {
    var day: AnalysisDay
    /// Local midnight.
    var date: Date
    /// The night's stages, minutes; nil when the band sent none.
    var deep: Double?
    var rem: Double?
    var light: Double?
    /// Minutes in heart-rate zones 1...5.
    var zones: [Int]?

    var id: Int { day.day.index }
}

extension HealthHistory {
    /// Resting heart rate for everything but Today's own figure (`Analysis.settledRestingHR`).
    /// A day is over when a later day has data.
    func settledRestingHR(_ d: DayKey) -> Double? {
        Analysis.settledRestingHR(scored: score(d)?.rhr, fromSleep: score(d)?.rhrSource == "sleep",
                                  bandValue: summary(d)?.hrResting.map(Double.init), dayIsOver: d.index < (lastDay?.index ?? d.index))
    }

    /// A metric's value as trends and baselines read it: `value`, except that an unfinished
    /// day's running resting heart rate is left out.
    func settledValue(_ metric: TrendMetric, on day: DayKey) -> Double? {
        metric == .restingHeartRate ? settledRestingHR(day) : value(metric, on: day)
    }

    /// Minutes napped on the day.
    func napMinutes(_ d: DayKey) -> Double { result(d)?.naps.reduce(0) { $0 + $1.minutes } ?? 0 }

    func analysisDay(_ d: DayKey) -> AnalysisDay {
        let night = mainSleep(d)
        let bed = night.map { Analysis.clockMinute($0.bedTime, offsetMinutes: $0.tzOffsetMinutes) }
        let wake = night.flatMap { n in bed.map { $0 + n.wakeTime.timeIntervalSince(n.bedTime) / 60 } }
        return AnalysisDay(day: d, sleepMinutes: sleepMinutes(d), napMinutes: napMinutes(d), bedMinute: bed, wakeMinute: wake,
                           recovery: score(.recovery, d), strain: score(.strain, d),
                           restingHR: settledRestingHR(d), hrv: score(d)?.hrv, steps: value(.steps, on: d))
    }

    /// `count` days ending on `end`, oldest first.
    func analysisRows(ending end: DayKey, count: Int) -> [AnalysisRow] {
        (0 ..< count).reversed().map { back in
            let d = end.adding(days: -back)
            let metrics = result(d)?.sleep.metrics
            let night = mainSleep(d)
            return AnalysisRow(day: analysisDay(d), date: d.date,
                               deep: metrics?.deepMinutes ?? night?.deepMinutes.map(Double.init),
                               rem: metrics?.remMinutes ?? night?.remMinutes.map(Double.init),
                               light: metrics?.lightMinutes ?? night?.lightMinutes.map(Double.init),
                               zones: result(d)?.strain.map { Array($0.zoneMinutes.dropFirst()) })
        }
    }
}
