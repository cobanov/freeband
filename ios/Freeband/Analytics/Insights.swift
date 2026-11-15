import Foundation

/// One day of what Insights reads: the stored scores and the values they were made from.
struct InsightDay: Equatable, Sendable {
    var day: DayKey
    var restingHR: Double?
    var hrv: Double?
    var sleepMinutes: Double?
    var midSleepMinute: Double?
    var strain: Double?
    var recovery: Double?
}

/// Something about a day that stands out from the person's own normal.
struct Insight: Equatable, Sendable {
    enum Kind: String, Sendable {
        /// `value`, `reference`: today's resting HR and the 14-day normal, bpm. `days`: days in a row.
        case restingHRHigh
        /// The lowest resting HR of the last 14 valid days. `value`, `reference` as above.
        case restingHRLowest
        /// `value`, `reference`: last night's HRV and the normal, ms. `days`: nights in a row.
        case hrvLow
        /// `value`: minutes slept less than needed over the last `days` nights.
        case sleepDebt
        /// `value`: minutes the night's middle moved against the previous nights; positive is later.
        case sleepShifted
        /// `value`: today's recovery; `reference`: the mean strain of the `days` days before.
        case loadWithoutRecovery
    }

    enum Tone: Int, Sendable, Comparable {
        case warning, notice, good
        static func < (a: Tone, b: Tone) -> Bool { a.rawValue < b.rawValue }
    }

    var kind: Kind
    var tone: Tone
    var value: Double
    var reference: Double?
    var days = 1
}

/// Reads the last weeks of one band's days and says what stands out today. Every rule compares
/// the person with their own baseline (Baseline: median of the previous 14 valid days, MAD
/// sigma), needs a full baseline (7 days), and stays silent otherwise. Pure and deterministic.
///
/// Thresholds are choices (v1), not validated against a population:
/// - resting HR high, HRV low: 2 sigma from normal; a warning at 3 sigma or 3 days in a row;
/// - sleep debt: 5 h short over the last 7 nights (at least 5 with data); a warning at 10 h;
/// - sleep shifted: the night's middle 90 min from the median of the previous nights (at least 4);
/// - load without recovery: recovery in the low band after 3 days of strain 1 sigma above normal.
enum Insights {
    static let outlierZ = 2.0
    static let warningZ = 3.0
    static let warningStreak = 3
    static let debtNights = 7
    static let debtMinNights = 5
    static let debtNotice = 300.0
    static let debtWarning = 600.0
    static let shiftMinutes = 90.0
    static let shiftMinNights = 4
    static let loadDays = 3
    /// Recovery's low band ends here (plan section 8).
    static let lowRecovery = 34.0

    /// Warnings first; within a tone, in the order of the rules above.
    static func compute(day: DayKey, history: [InsightDay], sleepNeedMinutes: Double) -> [Insight] {
        var byDay: [Int: InsightDay] = [:]
        for d in history { byDay[d.day.index] = d }
        guard let today = byDay[day.index] else { return [] }

        /// The values of the days before `index`, most recent first, as Baseline wants them.
        func past(_ index: Int, _ value: (InsightDay) -> Double?) -> [Double] {
            (1 ... Baseline.lookbackDays).compactMap { byDay[index - $0].flatMap(value) }
        }
        /// z of the day's value against the baseline of the days before it; nil without a full baseline.
        func z(_ index: Int, _ value: (InsightDay) -> Double?, _ floor: Baseline.Floor) -> (z: Double, median: Double)? {
            guard let v = byDay[index].flatMap(value), let b = Baseline.compute(past(index, value), floor: floor),
                  b.status == .normal else { return nil }
            return (b.z(v), b.median)
        }
        /// Days in a row, ending on `day`, that `holds`.
        func streak(_ holds: (Int) -> Bool) -> Int {
            var n = 0
            while holds(day.index - n) { n += 1 }
            return n
        }

        var out: [Insight] = []

        if let rhr = today.restingHR, let now = z(day.index, \.restingHR, .restingHR) {
            if now.z >= outlierZ {
                let days = streak { (z($0, \.restingHR, .restingHR)?.z ?? 0) >= outlierZ }
                out.append(Insight(kind: .restingHRHigh, tone: now.z >= warningZ || days >= warningStreak ? .warning : .notice,
                                   value: rhr, reference: now.median, days: days))
            } else if now.z <= -1, let lowest = past(day.index, \.restingHR).prefix(Baseline.window).min(), rhr < lowest {
                out.append(Insight(kind: .restingHRLowest, tone: .good, value: rhr, reference: now.median))
            }
        }

        if let hrv = today.hrv, let now = z(day.index, \.hrv, .hrv), now.z <= -outlierZ {
            let days = streak { (z($0, \.hrv, .hrv)?.z ?? 0) <= -outlierZ }
            out.append(Insight(kind: .hrvLow, tone: now.z <= -warningZ || days >= warningStreak ? .warning : .notice,
                               value: hrv, reference: now.median, days: days))
        }

        let nights = (0 ..< debtNights).compactMap { byDay[day.index - $0]?.sleepMinutes }
        let debt = nights.reduce(0) { $0 + (sleepNeedMinutes - $1) }
        if today.sleepMinutes != nil, nights.count >= debtMinNights, debt >= debtNotice {
            out.append(Insight(kind: .sleepDebt, tone: debt >= debtWarning ? .warning : .notice, value: debt, days: nights.count))
        }

        let mids = (1 ... debtNights).compactMap { byDay[day.index - $0]?.midSleepMinute }
        if let mid = today.midSleepMinute, mids.count >= shiftMinNights {
            // The clock wraps: 23:50 and 00:10 are 20 minutes apart.
            let diffs = mids.map { p -> Double in
                let d = (mid - p).truncatingRemainder(dividingBy: 1440)
                return d > 720 ? d - 1440 : (d <= -720 ? d + 1440 : d)
            }
            if let shift = Stats.median(diffs), abs(shift) >= shiftMinutes {
                out.append(Insight(kind: .sleepShifted, tone: .notice, value: shift, days: mids.count))
            }
        }

        if let recovery = today.recovery, recovery < lowRecovery {
            let loads = (1 ... loadDays).compactMap { back -> Double? in
                guard let hard = z(day.index - back, \.strain, .strain), hard.z >= 1 else { return nil }
                return byDay[day.index - back]?.strain
            }
            if loads.count == loadDays, let mean = Stats.mean(loads) {
                out.append(Insight(kind: .loadWithoutRecovery, tone: .warning, value: recovery, reference: mean, days: loadDays))
            }
        }

        // Stable: equal tones keep the rule order.
        return out.enumerated().sorted { ($0.element.tone, $0.offset) < ($1.element.tone, $1.offset) }.map(\.element)
    }
}
