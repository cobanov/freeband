import SwiftUI

/// Turns a day's score result into words: one sentence for the top of a score detail and the
/// contributor rows under it.
@MainActor
enum ScoreExplainer {
    struct Row: Identifiable {
        let id: String
        let name: String
        let value: String?
        var fraction: Double?
        var baseline: Double?
        var note: String?
        var flagged = false
    }

    // MARK: sentence

    static func sentence(_ kind: ScoreKind, result: DayScoreResult?, value: Double?) -> String {
        switch kind {
        case .recovery: recovery(result?.recovery)
        case .sleep: sleep(result?.sleep)
        case .strain: strain(result?.strain)
        }
    }

    private static func recovery(_ r: RecoveryResult?) -> String {
        guard let r, let score = r.score else {
            return String(localized: "Recovery needs enough previous valid resting heart rate or HRV data in Freeband. Sync available band history; data held only by Mi Fitness is not available here.")
        }
        let lead = switch ScoreBand.recovery(Double(score)) {
        case .good: String(localized: "Higher than usual")
        case .fair: String(localized: "About usual")
        default: String(localized: "Lower than usual")
        }
        let movers = r.contributors
            .filter { $0.weight > 0 && $0.z != nil && abs($0.z ?? 0) >= 0.5 }
            .sorted { abs($0.z ?? 0) * $0.weight > abs($1.z ?? 0) * $1.weight }
            .prefix(2)
        let phrases = movers.map { c -> String in
            let better = (c.z ?? 0) > 0
            switch c.name {
            case .hrv: return better ? String(localized: "heart rate variability is up") : String(localized: "heart rate variability is down")
            case .restingHR: return better ? String(localized: "resting heart rate is lower") : String(localized: "resting heart rate is up")
            case .sleep: return better ? String(localized: "sleep scored above usual") : String(localized: "sleep scored below usual")
            case .strain: return better ? String(localized: "yesterday was easier than usual") : String(localized: "yesterday was harder than usual")
            }
        }
        let reason = phrases.isEmpty ? String(localized: "everything is close to your normal") : FBFormat.list(phrases)
        return String(localized: "\(lead): \(reason).", comment: "Score sentence: lead, then reasons")
    }

    private static func sleep(_ s: SleepScoreResult?) -> String {
        guard let s, let score = s.score else { return String(localized: "No night was recorded for this day.") }
        let lead = switch ScoreBand.sleep(Double(score)) {
        case .good: String(localized: "A good night")
        case .fair: String(localized: "A fair night")
        default: String(localized: "A rough night")
        }
        let scored = s.contributors.filter { $0.subscore != nil }
        let weak = scored.filter { ($0.subscore ?? 100) < 70 }
            .sorted { (100 - ($0.subscore ?? 0)) * $0.weight > (100 - ($1.subscore ?? 0)) * $1.weight }
            .prefix(2)
        let phrases: [String]
        if !weak.isEmpty {
            phrases = weak.map { c in
                switch c.name {
                case .duration: String(localized: "it was short")
                case .efficiency: String(localized: "you lay awake a while")
                case .deep: String(localized: "there was little deep sleep")
                case .rem: String(localized: "there was little REM sleep")
                case .restfulness: String(localized: "you woke often")
                case .regularity: String(localized: "it started off your usual schedule")
                case .hrDip: String(localized: "your heart rate barely dipped")
                }
            }
        } else {
            phrases = scored.sorted { ($0.subscore ?? 0) * $0.weight > ($1.subscore ?? 0) * $1.weight }.prefix(2).map { c in
                switch c.name {
                case .duration: String(localized: "it was long enough")
                case .efficiency: String(localized: "you slept most of the time in bed")
                case .deep: String(localized: "there was plenty of deep sleep")
                case .rem: String(localized: "there was plenty of REM sleep")
                case .restfulness: String(localized: "it was restful")
                case .regularity: String(localized: "it kept your usual schedule")
                case .hrDip: String(localized: "your heart rate dipped well")
                }
            }
        }
        guard !phrases.isEmpty else { return lead + "." }
        return String(localized: "\(lead): \(FBFormat.list(phrases)).", comment: "Score sentence: lead, then reasons")
    }

    private static func strain(_ st: StrainResult?) -> String {
        guard let st else { return String(localized: "No heart rate for this day yet.") }
        let word = ScoreBand.strain(st.strain).word
        let zoned = Array(st.zoneMinutes.dropFirst())
        let active = zoned.reduce(0, +)
        guard active > 0, let top = zoned.indices.max(by: { zoned[$0] < zoned[$1] }) else {
            return String(localized: "\(word) day: no time in heart-rate zones.")
        }
        let zone = top + 1
        return String(localized: "\(word) day: \(active) min in heart-rate zones, most of it in zone \(zone).")
    }

    // MARK: contributor rows

    static func contributorRows(_ kind: ScoreKind, result: DayScoreResult?, day: DayKey, history: HealthHistory) -> [Row] {
        guard let result else { return [] }
        switch kind {
        case .recovery: return result.recovery.contributors.map(recoveryRow)
        case .sleep: return result.sleep.contributors.map(sleepRow)
        case .strain: return strainRows(result, day: day, history: history)
        }
    }

    private static func recoveryRow(_ c: RecoveryContributor) -> Row {
        func format(_ v: Double) -> String {
            switch c.name {
            case .hrv: String(localized: "\(FBFormat.number(v)) ms")
            case .restingHR: FBFormat.bpm(v)
            case .sleep: FBFormat.number(v)
            case .strain: FBFormat.number(v, fraction: 1)
            }
        }
        func amount(_ v: Double) -> String {
            switch c.name {
            case .strain: FBFormat.number(v, fraction: 1)
            default: FBFormat.number(v)
            }
        }
        var note: String?
        if c.weight == 0 {
            note = c.name == .hrv ? String(localized: "Needs RR data") : String(localized: "Not counted")
        } else if let b = c.baseline, b.status == .calibrating {
            note = String(localized: "Learning your normal")
        } else if let b = c.baseline, let t = c.today {
            note = usualNote(t - b.median, threshold: c.name == .strain ? 0.5 : 1, amount: amount)
        }
        return Row(id: c.name.rawValue, name: ContributorName.name(c.name.rawValue), value: c.today.map(format),
                   fraction: c.weight > 0 ? c.subscore.map { $0 / 100 } : nil,
                   baseline: c.weight > 0 && c.subscore != nil ? 0.6 : nil,
                   note: note, flagged: (c.subscore ?? 100) < 34)
    }

    private static func sleepRow(_ c: SleepContributor) -> Row {
        func format(_ v: Double) -> String {
            switch c.name {
            case .duration: FBFormat.duration(minutes: v)
            case .efficiency, .deep, .rem, .hrDip: FBFormat.percent(v)
            case .restfulness: String(localized: "\(FBFormat.number(v)) min awake")
            case .regularity: String(localized: "±\(FBFormat.number(v)) min")
            }
        }
        let need = Double(Profile.load().sleepNeed)
        var tick: Double?
        if let b = c.baseline {
            switch c.name {
            case .duration: tick = Stats.ramp(b, from: 0, to: need)
            case .efficiency: tick = Stats.ramp(b, from: SleepScore.efficiencyRange.zero, to: SleepScore.efficiencyRange.full)
            case .deep: tick = Stats.ramp(b, from: 0, to: SleepScore.deepTarget)
            case .rem: tick = Stats.ramp(b, from: 0, to: SleepScore.remTarget)
            case .restfulness: tick = Stats.clamp(100 - SleepScore.perWASOMinute * b, 0, 100)
            case .regularity: tick = Stats.ramp(b, from: SleepScore.regularityRange.zero, to: SleepScore.regularityRange.full)
            case .hrDip: tick = Stats.ramp(b, from: 0, to: SleepScore.dipFull)
            }
        }
        let note = c.baseline.map { String(localized: "Usual \(format($0))") }
            ?? (c.subscore == nil ? String(localized: "Not measured") : nil)
        return Row(id: c.name.rawValue, name: ContributorName.name(c.name.rawValue), value: c.value.map(format),
                   fraction: c.subscore.map { $0 / 100 }, baseline: tick.map { $0 / 100 }, note: note,
                   flagged: (c.subscore ?? 100) < 60)
    }

    private static func strainRows(_ r: DayScoreResult, day: DayKey, history: HealthHistory) -> [Row] {
        var rows: [Row] = []
        let active = history.activeMinutes(day)
        let usualActive = history.median(.activeMinutes, before: day)
        rows.append(Row(id: "active", name: String(localized: "Active minutes"),
                        value: active.map { String(localized: "\($0) min") },
                        note: usualActive.map { String(localized: "Usual \(FBFormat.number($0)) min") }))
        let steps = history.value(.steps, on: day)
        let usualSteps = history.median(.steps, before: day)
        rows.append(Row(id: "steps", name: String(localized: "Steps"), value: steps.map { FBFormat.number(Int($0)) },
                        note: usualSteps.map { String(localized: "Usual \(FBFormat.number(Int($0)))") }))
        if let peak = history.summary(day)?.hrMax {
            rows.append(Row(id: "peak", name: String(localized: "Peak heart rate"), value: FBFormat.bpm(Double(peak))))
        }
        if let st = r.strain {
            rows.append(Row(id: "coverage", name: String(localized: "Heart-rate coverage"), value: FBFormat.percent(st.coverage),
                            fraction: st.coverage, note: String(localized: "of awake minutes"), flagged: st.coverage < Strain.lowCoverage))
            let known = Profile.load().maxHRIsKnown
            rows.append(Row(id: "max", name: String(localized: "Maximum heart rate"), value: FBFormat.bpm(st.maxHR),
                            note: known ? nil : String(localized: "Assumed from age")))
        }
        return rows
    }

    /// "3 above usual", "2 below usual", "Usual".
    private static func usualNote(_ diff: Double, threshold: Double, amount: (Double) -> String) -> String {
        if abs(diff) < threshold { return String(localized: "Usual") }
        let text = amount(abs(diff))
        return diff > 0 ? String(localized: "\(text) above usual") : String(localized: "\(text) below usual")
    }
}

/// "How it's calculated": plan section 5 in plain words, then this day's confidence and why.
struct ScoreMethodView: View {
    let kind: ScoreKind
    let day: DayKey
    let history: HealthHistory

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FBSpace.l) {
                Card {
                    VStack(alignment: .leading, spacing: FBSpace.s) {
                        ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, text in
                            Text(text)
                                .textStyle(.body)
                                .foregroundStyle(.textBody)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: FBSpace.xs) {
                    SectionHeader(title: String(localized: "This day"), trailing: FBFormat.shortDay(day.noon))
                    Card {
                        VStack(alignment: .leading, spacing: FBSpace.xs) {
                            let confidence = history.confidence(kind, day)
                            Text(confidence?.level.title ?? ConfidenceLevel.none.title)
                                .textStyle(.headline)
                                .foregroundStyle(.textPrimary)
                            let reasons = confidence?.reasons ?? []
                            if reasons.isEmpty {
                                Text(history.score(kind, day) == nil ? String(localized: "No data for this day.")
                                                                     : String(localized: "Every input was there."))
                                    .textStyle(.body)
                                    .foregroundStyle(.textSecondary)
                            }
                            ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                                HStack(alignment: .firstTextBaseline, spacing: FBSpace.xs) {
                                    Text(verbatim: "·").accessibilityHidden(true)
                                    Text(reason.localizedText).fixedSize(horizontal: false, vertical: true)
                                }
                                .textStyle(.body)
                                .foregroundStyle(.textBody)
                            }
                        }
                    }
                    Footnote(String(localized: "Algorithm version \(ScoreEngine.algoVersion). Nothing here is medical advice."))
                }
            }
            .padding(.horizontal, FBSpace.gutter)
            .padding(.bottom, FBSpace.xl)
        }
        .fbScreen()
        .navigationTitle(String(localized: "How \(kind.name) works"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var paragraphs: [String] {
        switch kind {
        case .recovery:
            [
                String(localized: "Recovery compares this morning with your own normal: the median of your previous 14 valid days."),
                String(localized: "Each input is measured in standard deviations from that normal. Your normal scores 60; each step better adds 20 and each step worse takes 20, from 0 to 100."),
                String(localized: "With beat-to-beat (RR) data the weights are heart rate variability 40, resting heart rate 25, sleep score 25 and yesterday's strain 10. Without it: resting heart rate 45, sleep 40 and strain 15, and confidence is at most medium."),
                String(localized: "Resting heart rate is the lowest 5-minute average while asleep; failing that, the band's own value; failing that, still daytime minutes."),
                String(localized: "With fewer than 3 days of history there is no score yet. 3 to 6 days give low confidence, 7 or more normal."),
                String(localized: "67 to 100 is good, 34 to 66 fair, 0 to 33 low."),
            ]
        case .sleep:
            [
                String(localized: "The sleep score is a weighted mean of what the band measured: duration 35, efficiency 15, deep sleep 10, REM 10, restfulness 10, regularity 10 and heart-rate dip 10."),
                String(localized: "Duration counts against your sleep need (8 hours unless you set it in Profile). Efficiency scores from 60% to 90% of the time in bed. Deep sleep aims for 18% of the night, REM for 22%."),
                String(localized: "Restfulness loses 4 points per waking and 1 per minute awake after falling asleep. Regularity compares the middle of your sleep with the last 7 nights. The heart-rate dip compares sleeping heart rate with your evening."),
                String(localized: "Missing inputs drop out of the mean. Without duration there is no score; with less than 60 of the 100 points, the score is an estimate."),
                String(localized: "80 to 100 is good, 60 to 79 fair, below 60 low."),
            ]
        case .strain:
            [
                String(localized: "Strain counts how hard your heart worked while you were awake, from 0 to 21."),
                String(localized: "Each minute's heart rate becomes a share of your heart-rate reserve: (heart rate − resting) ÷ (maximum − resting). Maximum is 208 − 0.7 × age unless you set it in Profile."),
                String(localized: "Minutes under 30% of the reserve add nothing. The rest add load that grows faster at higher effort; the weighting follows your sex when you set it."),
                String(localized: "Strain is 21 × ln(1 + load ÷ 25) ÷ ln 25, at most 21: a load of 100 is about 10.5, 200 about 14.3."),
                String(localized: "When heart rate covers less than half of your awake minutes, short gaps are filled, minutes with 100 or more steps count as light effort, and confidence is low."),
                String(localized: "Light is under 10, moderate 10 to 14, high 14 to 18, all out 18 and up."),
            ]
        }
    }
}
