import Foundation

/// One row of the sleep score: what was measured, its 0-100 sub-score and its weight.
struct SleepContributor: Codable, Equatable, Sendable {
    enum Name: String, Codable, Sendable, CaseIterable {
        case duration, efficiency, deep, rem, restfulness, regularity
        case hrDip = "hr_dip"
    }

    var name: Name
    var weight: Double
    /// Duration and WASO in minutes, efficiency/deep/REM/dip as fractions, regularity as the
    /// mid-sleep deviation in minutes.
    var value: Double?
    var subscore: Double?
    /// The value's 14-day median, for display.
    var baseline: Double?
}

struct SleepScoreResult: Codable, Equatable, Sendable {
    var score: Int?
    /// Available weight below 60 of 100: shown as an estimate.
    var estimated: Bool
    var availableWeight: Double
    var contributors: [SleepContributor]
    var metrics: SleepMetrics?
    var confidence: Confidence

    static let missing = SleepScoreResult(score: nil, estimated: false, availableWeight: 0, contributors: [], metrics: nil,
                                          confidence: Confidence(.none, reasons: [ConfidenceReason(.noSleep)]))
}

/// Sleep score 0-100 (plan section 5): the weighted mean of the contributors that exist.
/// Weights: duration 35, efficiency 15, deep 10, REM 10, restfulness 10, regularity 10, HR dip 10.
/// No duration, no score; less than 60 of the weight available, the score is an estimate.
enum SleepScore {
    static let weights: [SleepContributor.Name: Double] = [
        .duration: 35, .efficiency: 15, .deep: 10, .rem: 10, .restfulness: 10, .regularity: 10, .hrDip: 10,
    ]
    static let estimateBelowWeight = 60.0
    /// How far the score may stand above the duration sub-score (v2).
    static let durationLead = 10.0

    // Sub-score curves (choices, algorithm v1). Each is a clamped straight line.
    /// Efficiency 60% scores 0, 90% scores 100.
    static let efficiencyRange = (zero: 0.60, full: 0.90)
    /// Deep sleep 18% of total sleep scores 100.
    static let deepTarget = 0.18
    /// REM 22% of total sleep scores 100.
    static let remTarget = 0.22
    /// Restfulness: 100 - 4 per waking - 1 per minute awake after sleep onset.
    static let perWaking = 4.0
    static let perWASOMinute = 1.0
    /// Regularity: mid-sleep within 15 min of the last 7 nights' median scores 100, 2 h off 0.
    static let regularityRange = (full: 15.0, zero: 120.0)
    static let regularityNights = 7
    static let regularityMinNights = 3
    /// HR dip: 0% scores 0, 15% scores 100.
    static let dipFull = 0.15

    /// `previousMidSleeps`: mid-sleep minutes of day of the previous nights (up to 7).
    /// `baselines`: 14-day medians of the contributor values, for display only.
    static func score(_ metrics: SleepMetrics?, sleepNeedMinutes: Int, previousMidSleeps: [Double],
                      baselines: [SleepContributor.Name: Double] = [:]) -> SleepScoreResult {
        guard let m = metrics, m.inBedMinutes > 0 else { return .missing }

        func row(_ name: SleepContributor.Name, _ value: Double?, _ sub: Double?) -> SleepContributor {
            SleepContributor(name: name, weight: weights[name] ?? 0, value: value, subscore: sub.map { Stats.clamp($0, 0, 100) },
                             baseline: baselines[name])
        }

        var rows: [SleepContributor] = []
        rows.append(row(.duration, m.totalSleepMinutes,
                        Stats.ramp(m.totalSleepMinutes, from: 0, to: Double(max(sleepNeedMinutes, 1)))))
        rows.append(row(.efficiency, m.efficiency,
                        m.efficiency.map { Stats.ramp($0, from: efficiencyRange.zero, to: efficiencyRange.full) }))
        rows.append(row(.deep, m.deepFraction, m.deepFraction.map { Stats.ramp($0, from: 0, to: deepTarget) }))
        rows.append(row(.rem, m.remFraction, m.remFraction.map { Stats.ramp($0, from: 0, to: remTarget) }))

        var restful: Double?
        if m.wakeCount != nil || m.wasoMinutes != nil {
            restful = 100 - perWaking * Double(m.wakeCount ?? 0) - perWASOMinute * (m.wasoMinutes ?? 0)
        }
        rows.append(row(.restfulness, m.wasoMinutes, restful))

        let deviation = regularityDeviation(m.midSleepMinute, previous: previousMidSleeps)
        rows.append(row(.regularity, deviation,
                        deviation.map { Stats.ramp($0, from: regularityRange.zero, to: regularityRange.full) }))
        rows.append(row(.hrDip, m.hrDip, m.hrDip.map { Stats.ramp($0, from: 0, to: dipFull) }))

        let available = rows.filter { $0.subscore != nil }
        let weight = available.reduce(0) { $0 + $1.weight }
        var score = weight > 0 ? available.reduce(0) { $0 + $1.weight * ($1.subscore ?? 0) } / weight : nil
        // v2: the score may not exceed the duration sub-score by more than `durationLead`. A real
        // 4 h 52 min night scored 76 ("fair, nearly good") because efficiency, restfulness and the
        // heart rate dip were all near 100; how well a short night went doesn't make it enough.
        if let s = score, let duration = rows.first(where: { $0.name == .duration })?.subscore {
            score = min(s, duration + durationLead)
        }
        let estimated = weight < estimateBelowWeight

        var confidence = Confidence(.high)
        if !m.stagesAvailable { confidence.cap(.medium, ConfidenceReason(.noStages)) }
        for r in rows where r.subscore == nil {
            confidence.cap(.medium, ConfidenceReason(.missingContributor, detail: r.name.rawValue))
        }
        if estimated { confidence.cap(.low, ConfidenceReason(.estimated, weight)) }

        return SleepScoreResult(score: score.map { Int($0.rounded()) }, estimated: estimated, availableWeight: weight,
                                contributors: rows, metrics: m, confidence: confidence)
    }

    /// |median of the signed differences to the previous nights' mid-sleeps|, minutes, with the
    /// clock wrapped so 23:50 and 00:10 are 20 minutes apart. Nil with fewer than 3 nights.
    static func regularityDeviation(_ mid: Double, previous: [Double]) -> Double? {
        let nights = Array(previous.prefix(regularityNights))
        guard nights.count >= regularityMinNights else { return nil }
        let diffs = nights.map { p -> Double in
            var d = (mid - p).truncatingRemainder(dividingBy: 1440)
            if d > 720 { d -= 1440 }
            if d <= -720 { d += 1440 }
            return d
        }
        return Stats.median(diffs).map(abs)
    }
}
