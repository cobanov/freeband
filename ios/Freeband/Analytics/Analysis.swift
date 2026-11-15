import Foundation

/// One day as the analysis screens read it: the stored scores and the values behind them.
struct AnalysisDay: Equatable, Sendable {
    var day: DayKey
    /// The night that ended on this day, minutes asleep.
    var sleepMinutes: Double?
    var napMinutes: Double = 0
    /// Bed and wake on a clock that starts at noon the day before (`Analysis.clockMinute`):
    /// 23:30 is 690, 07:00 the next morning is 1140. Wake is bed plus the time in bed.
    var bedMinute: Double?
    var wakeMinute: Double?
    var sleepScore: Double?
    var recovery: Double?
    var strain: Double?
    var restingHR: Double?
    var hrv: Double?
    var steps: Double?
}

enum ReviewMetric: String, CaseIterable, Sendable {
    case sleep, recovery, strain, restingHR, hrv, steps
}

/// A period's mean of one metric next to the mean of the period before it. A mean is given
/// for any number of days and says how many it stands on; a change, and anything said about
/// the period in words, needs `Analysis.minDays` on both sides.
struct PeriodChange: Equatable, Sendable {
    var metric: ReviewMetric
    var current: Double?
    var previous: Double?
    /// Days of the period, and of the one before, that had a value.
    var days: Int
    var previousDays: Int
    /// Enough days to say something about the period.
    var settled: Bool { days >= Analysis.minDays }
    var delta: Double? {
        guard settled, previousDays >= Analysis.minDays, let current, let previous else { return nil }
        return current - previous
    }
}

/// Something a period says about itself, in numbers; the screen writes the sentence.
struct ReviewFinding: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// `value`: mean minutes slept a day (night and naps); `reference`: the need.
        case sleepShort
        /// `value`: mean minutes slept; `reference`: the period before.
        case sleepUp, sleepDown
        /// `value`, `reference`: this period's mean and the one before, in the metric's unit.
        case restingHRUp, restingHRDown, hrvUp, hrvDown, recoveryUp, recoveryDown, strainUp, strainDown
        /// `value`: minutes bed and wake times move around their mean.
        case timingIrregular, timingSteady
    }

    var kind: Kind
    var tone: Insight.Tone
    var value: Double
    var reference: Double?
}

struct PeriodReview: Equatable, Sendable {
    var length: Int
    var changes: [PeriodChange]
    var findings: [ReviewFinding]
    var timing: SleepTiming?

    func change(_ metric: ReviewMetric) -> PeriodChange? { changes.first { $0.metric == metric } }
}

/// When the nights of a period began and ended, and how much that moved.
struct SleepTiming: Equatable, Sendable {
    /// Clock minutes after noon (see AnalysisDay).
    var meanBed: Double
    var meanWake: Double
    /// Mean distance of a night's bed (wake) time from the mean, minutes.
    var bedSpread: Double
    var wakeSpread: Double
    var nights: Int
    var spread: Double { (bedSpread + wakeSpread) / 2 }
}

/// Something one night says about itself, read against what a body needs and not against the
/// person's own history, so it can be said from the first night on.
struct NightNote: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// `value`: minutes slept with naps; `reference`: the need.
        case needMet, short
        /// `value`: deep and REM minutes together; `reference`: their share of the sleep, 0...1.
        case restorativeHigh, restorativeLow
        /// `value`: minutes awake in bed; `reference`: efficiency, 0...1.
        case restless
        /// `value`: how far heart rate fell from the evening's, 0...1.
        case heartRateStayedUp
    }

    var kind: Kind
    var tone: Insight.Tone
    var value: Double
    var reference: Double?
}

/// Where today's value of a vital stands against the person's own normal.
struct VitalRange: Equatable, Sendable {
    enum Status: String, Sendable { case calibrating, below, within, above }

    var status: Status
    /// The normal: median of the previous valid days, and two sigma either side.
    var median: Double?
    var low: Double?
    var high: Double?
    /// Valid days behind the normal.
    var days: Int
}

/// Period reviews, sleep timing and vital ranges for the analysis screens. Pure and deterministic.
///
/// Every threshold is a choice (v1), not validated against a population:
/// - a finding needs 3 days with data in the period; a change needs that in both periods;
/// - a change is worth a sentence at 30 min of sleep, 2 bpm of resting heart rate, 10% of HRV,
///   8 points of recovery, 1.5 of strain;
/// - sleep is short when the daily mean (night and naps) is 45 min under the need, a warning at 90;
/// - sleep timing is irregular at a spread of 60 min, steady at 30 or less over 5 nights or more;
/// - a vital is out of range 2 sigma from the 14-day median (Baseline), which needs 3 days.
/// - a night met the need within 15 min of it, was short from 45 min under (a warning from 2 h);
/// - deep and REM together are a good share of a night from 40% and a small one under 30%
///   (the commonly quoted adult ranges are 13-23% deep and 20-25% REM);
/// - a night was restless under 85% efficiency;
/// - heart rate stayed up when it fell less than 10% from the evening before bed.
enum Analysis {
    static let minDays = 3
    static let sleepChange = 30.0
    static let restingHRChange = 2.0
    static let hrvChange = 0.10
    static let recoveryChange = 8.0
    static let strainChange = 1.5
    static let shortNotice = 45.0
    static let shortWarning = 90.0
    static let irregularSpread = 60.0
    static let steadySpread = 30.0
    static let steadyNights = 5
    static let rangeSigmas = 2.0

    /// Minutes after local noon: 23:30 is 690, 00:30 is 750, 11:00 in the morning is 1380.
    static func clockMinute(_ date: Date, offsetMinutes: Int) -> Double {
        let local = date.timeIntervalSince1970 + Double(offsetMinutes) * 60
        let minuteOfDay = (local / 60).truncatingRemainder(dividingBy: 1440)
        return minuteOfDay >= 720 ? minuteOfDay - 720 : minuteOfDay + 720
    }

    static func timing(_ nights: [(bed: Double, wake: Double)]) -> SleepTiming? {
        guard nights.count >= minDays, let bed = Stats.mean(nights.map(\.bed)), let wake = Stats.mean(nights.map(\.wake)),
              let bedSpread = Stats.mean(nights.map { abs($0.bed - bed) }),
              let wakeSpread = Stats.mean(nights.map { abs($0.wake - wake) }) else { return nil }
        return SleepTiming(meanBed: bed, meanWake: wake, bedSpread: bedSpread, wakeSpread: wakeSpread, nights: nights.count)
    }

    /// The `length` days ending on `ending` against the `length` days before them.
    static func review(_ days: [AnalysisDay], ending: DayKey, length: Int, sleepNeedMinutes: Double) -> PeriodReview {
        var byDay: [Int: AnalysisDay] = [:]
        for d in days { byDay[d.day.index] = d }
        let current = (0 ..< length).compactMap { byDay[ending.index - $0] }
        let previous = (length ..< 2 * length).compactMap { byDay[ending.index - $0] }

        func value(_ metric: ReviewMetric, _ d: AnalysisDay) -> Double? {
            switch metric {
            case .sleep: d.sleepMinutes.map { $0 + d.napMinutes }
            case .recovery: d.recovery
            case .strain: d.strain
            case .restingHR: d.restingHR
            case .hrv: d.hrv
            case .steps: d.steps
            }
        }
        func mean(_ metric: ReviewMetric, _ period: [AnalysisDay]) -> (mean: Double?, days: Int) {
            let values = period.compactMap { value(metric, $0) }
            return (Stats.mean(values), values.count)
        }

        let changes = ReviewMetric.allCases.map { metric -> PeriodChange in
            let now = mean(metric, current), before = mean(metric, previous)
            return PeriodChange(metric: metric, current: now.mean, previous: before.mean, days: now.days, previousDays: before.days)
        }
        func change(_ metric: ReviewMetric) -> PeriodChange { changes.first { $0.metric == metric }! }

        var findings: [ReviewFinding] = []
        let sleep = change(.sleep)
        if sleep.settled, let slept = sleep.current, sleepNeedMinutes - slept >= shortNotice {
            findings.append(ReviewFinding(kind: .sleepShort, tone: sleepNeedMinutes - slept >= shortWarning ? .warning : .notice,
                                          value: slept, reference: sleepNeedMinutes))
        }
        if let slept = sleep.current, let delta = sleep.delta, abs(delta) >= sleepChange {
            findings.append(ReviewFinding(kind: delta > 0 ? .sleepUp : .sleepDown, tone: delta > 0 ? .good : .notice,
                                          value: slept, reference: sleep.previous))
        }
        /// `up` is the kind when the mean rose; `rising` says whether a rise is the good direction.
        func compare(_ metric: ReviewMetric, threshold: Double, relative: Bool = false,
                     up: ReviewFinding.Kind, down: ReviewFinding.Kind, rising: Bool?) {
            let c = change(metric)
            guard let now = c.current, let before = c.previous, let delta = c.delta,
                  abs(delta) >= (relative ? threshold * abs(before) : threshold) else { return }
            let tone: Insight.Tone = rising.map { ($0 == (delta > 0)) ? .good : .notice } ?? .notice
            findings.append(ReviewFinding(kind: delta > 0 ? up : down, tone: tone, value: now, reference: before))
        }
        compare(.restingHR, threshold: restingHRChange, up: .restingHRUp, down: .restingHRDown, rising: false)
        compare(.hrv, threshold: hrvChange, relative: true, up: .hrvUp, down: .hrvDown, rising: true)
        compare(.recovery, threshold: recoveryChange, up: .recoveryUp, down: .recoveryDown, rising: true)
        compare(.strain, threshold: strainChange, up: .strainUp, down: .strainDown, rising: nil)

        let timing = timing(current.compactMap { d in d.bedMinute.flatMap { bed in d.wakeMinute.map { (bed, $0) } } })
        if let timing {
            if timing.spread >= irregularSpread {
                findings.append(ReviewFinding(kind: .timingIrregular, tone: .notice, value: timing.spread))
            } else if timing.spread <= steadySpread, timing.nights >= steadyNights {
                findings.append(ReviewFinding(kind: .timingSteady, tone: .good, value: timing.spread))
            }
        }
        // Stable: warnings first, equal tones keep the order above.
        let ordered = findings.enumerated().sorted { ($0.element.tone, $0.offset) < ($1.element.tone, $1.offset) }.map(\.element)
        return PeriodReview(length: length, changes: changes, findings: ordered, timing: timing)
    }

    /// Minutes slept under the need over the `length` days ending on `ending`, counting naps;
    /// negative when the nights ran over. Nil when none of the days has a night.
    static func sleepDebt(_ days: [AnalysisDay], ending: DayKey, length: Int = 7, sleepNeedMinutes: Double) -> (minutes: Double, nights: Int)? {
        let slept = days.filter { (0 ..< length).contains(ending.index - $0.day.index) }
            .compactMap { d in d.sleepMinutes.map { $0 + d.napMinutes } }
        guard !slept.isEmpty else { return nil }
        return (slept.reduce(0) { $0 + (sleepNeedMinutes - $1) }, slept.count)
    }

    static let needMetWithin = 15.0
    static let nightShortWarning = 120.0
    static let restorativeHigh = 0.40
    static let restorativeLow = 0.30
    static let restlessEfficiency = 0.85
    static let smallDip = 0.10

    /// What stands out about one night; warnings first, then in the order of the rules.
    static func nightNotes(_ night: SleepMetrics, napMinutes: Double, sleepNeedMinutes: Double) -> [NightNote] {
        var out: [NightNote] = []
        let slept = night.totalSleepMinutes + napMinutes
        let under = sleepNeedMinutes - slept
        if under <= needMetWithin {
            out.append(NightNote(kind: .needMet, tone: .good, value: slept, reference: sleepNeedMinutes))
        } else if under >= shortNotice {
            out.append(NightNote(kind: .short, tone: under >= nightShortWarning ? .warning : .notice, value: slept, reference: sleepNeedMinutes))
        }
        if night.stagesAvailable, let deep = night.deepMinutes, let rem = night.remMinutes, night.totalSleepMinutes > 0 {
            let share = (deep + rem) / night.totalSleepMinutes
            if share >= restorativeHigh {
                out.append(NightNote(kind: .restorativeHigh, tone: .good, value: deep + rem, reference: share))
            } else if share < restorativeLow {
                out.append(NightNote(kind: .restorativeLow, tone: .notice, value: deep + rem, reference: share))
            }
        }
        if let efficiency = night.efficiency, efficiency < restlessEfficiency {
            out.append(NightNote(kind: .restless, tone: .notice, value: night.inBedMinutes - night.totalSleepMinutes, reference: efficiency))
        }
        if let dip = night.hrDip, dip < smallDip {
            out.append(NightNote(kind: .heartRateStayedUp, tone: .notice, value: dip))
        }
        return out.enumerated().sorted { ($0.element.tone, $0.offset) < ($1.element.tone, $1.offset) }.map(\.element)
    }

    /// `previous`: the values of the days before, most recent first (Baseline takes the first 14).
    static func range(_ value: Double?, previous: [Double], floor: Baseline.Floor) -> VitalRange {
        guard let baseline = Baseline.compute(previous, floor: floor) else {
            return VitalRange(status: .calibrating, median: nil, low: nil, high: nil, days: 0)
        }
        let low = baseline.median - rangeSigmas * baseline.sigma
        let high = baseline.median + rangeSigmas * baseline.sigma
        guard baseline.status != .calibrating, let value else {
            return VitalRange(status: .calibrating, median: baseline.median, low: low, high: high, days: baseline.count)
        }
        return VitalRange(status: value < low ? .below : (value > high ? .above : .within),
                          median: baseline.median, low: low, high: high, days: baseline.count)
    }
}
