import Charts
import SwiftUI

// The analysis part of Trends: a review of the period in words and numbers, then the charts
// that show what it was made of. Everything is read from HealthHistory through
// Analytics/Analysis.swift; nothing here decides a threshold.

// MARK: - Review

/// The period against the one before it: what stands out, then six means with their change.
struct ReviewCard: View {
    let review: PeriodReview

    private var hasAnything: Bool { review.changes.contains { $0.current != nil } }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: FBSpace.m) {
                VStack(alignment: .leading, spacing: FBSpace.xxs) {
                    Text("Last \(review.length) days")
                        .textStyle(.headline)
                        .foregroundStyle(.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(hasAnything ? String(localized: "Daily averages, against the \(review.length) days before")
                                     : String(localized: "Nothing recorded in these days yet."))
                        .textStyle(.subhead)
                        .foregroundStyle(.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !review.findings.isEmpty {
                    VStack(alignment: .leading, spacing: FBSpace.s) {
                        ForEach(Array(review.findings.prefix(4).enumerated()), id: \.offset) { _, finding in
                            NoteRow(tone: finding.tone, title: finding.title, detail: finding.detail)
                        }
                    }
                }
                if hasAnything {
                    Rectangle().fill(.hairline).frame(height: FBStroke.hairline)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: FBSpace.s, alignment: .topLeading), count: 3),
                              alignment: .leading, spacing: FBSpace.m) {
                        ForEach(review.changes, id: \.metric) { change in
                            ReviewCell(change: change, length: review.length)
                        }
                    }
                }
            }
        }
    }
}

/// One thing worth saying: the icon's shape carries the tone, colour only repeats it.
struct NoteRow: View {
    let tone: Insight.Tone
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: FBSpace.s) {
            Image(systemName: tone.symbol)
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).textStyle(.figureS).foregroundStyle(.textPrimary)
                Text(detail).textStyle(.subhead).foregroundStyle(.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

extension Insight.Tone {
    var symbol: String {
        switch self {
        case .warning: "exclamationmark.triangle"
        case .notice: "info.circle"
        case .good: "checkmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .warning: .low
        case .notice: .fair
        case .good: .good
        }
    }
}

private struct ReviewCell: View {
    let change: PeriodChange
    let length: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(change.metric.title).textStyle(.caption).foregroundStyle(.textSecondary)
            Text(change.current.map(change.metric.format) ?? "–")
                .textStyle(.figureM)
                .foregroundStyle(change.current == nil ? .textTertiary : .textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let delta = change.delta, change.metric.isVisible(delta) {
                HStack(spacing: 2) {
                    Image(systemName: delta > 0 ? "arrow.up" : "arrow.down").font(.system(size: 10, weight: .semibold))
                    Text(change.metric.formatDelta(abs(delta)))
                }
                .textStyle(.caption)
                .foregroundStyle(change.metric.color(delta))
            } else if change.delta != nil {
                Text("No change").textStyle(.caption).foregroundStyle(.textTertiary)
            } else {
                Text("\(change.days) of \(length) days", comment: "Days with data in the period").textStyle(.caption).foregroundStyle(.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

extension ReviewMetric {
    var title: String {
        switch self {
        case .sleep: String(localized: "Sleep")
        case .recovery: String(localized: "Recovery")
        case .strain: String(localized: "Strain")
        case .restingHR: String(localized: "Resting HR")
        case .hrv: String(localized: "HRV")
        case .steps: String(localized: "Steps")
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .sleep: FBFormat.duration(minutes: value)
        case .recovery: ScoreKind.recovery.format(value)
        case .strain: ScoreKind.strain.format(value)
        case .restingHR: FBFormat.number(value)
        case .hrv: FBFormat.number(value)
        case .steps: FBFormat.number(Int(value.rounded()))
        }
    }

    func formatDelta(_ value: Double) -> String {
        switch self {
        case .sleep: FBFormat.duration(minutes: value)
        case .strain: ScoreKind.strain.format(value)
        case .steps: FBFormat.number(Int(value.rounded()))
        default: FBFormat.number(value)
        }
    }

    /// A change that would print as zero is no change.
    func isVisible(_ delta: Double) -> Bool {
        switch self {
        case .strain: abs(delta) >= 0.05
        default: abs(delta) >= 0.5
        }
    }

    /// Green when the change is the kind a body wants, amber when not; Strain takes no side.
    func color(_ delta: Double) -> Color {
        switch self {
        case .strain: .textSecondary
        case .restingHR: delta < 0 ? .good : .fair
        default: delta > 0 ? .good : .fair
        }
    }
}

extension ReviewFinding {
    var title: String {
        switch kind {
        case .sleepShort: String(localized: "Sleep is running short")
        case .sleepUp: String(localized: "More sleep than before")
        case .sleepDown: String(localized: "Less sleep than before")
        case .restingHRUp: String(localized: "Resting heart rate is up")
        case .restingHRDown: String(localized: "Resting heart rate is down")
        case .hrvUp: String(localized: "Heart rate variability is up")
        case .hrvDown: String(localized: "Heart rate variability is down")
        case .recoveryUp: String(localized: "Recovery is up")
        case .recoveryDown: String(localized: "Recovery is down")
        case .strainUp: String(localized: "Days were harder")
        case .strainDown: String(localized: "Days were easier")
        case .timingIrregular: String(localized: "Sleep times move around")
        case .timingSteady: String(localized: "Sleep times are steady")
        }
    }

    var detail: String {
        let before = reference ?? 0
        switch kind {
        case .sleepShort:
            return String(localized: "\(FBFormat.duration(minutes: value)) a day on average, against a need of \(FBFormat.duration(minutes: before)).")
        case .sleepUp, .sleepDown:
            return String(localized: "\(FBFormat.duration(minutes: value)) a day on average, was \(FBFormat.duration(minutes: before)).")
        case .restingHRUp, .restingHRDown:
            return String(localized: "\(FBFormat.bpm(value)) on average, was \(FBFormat.bpm(before)).")
        case .hrvUp, .hrvDown:
            return String(localized: "\(FBFormat.number(value)) ms on average, was \(FBFormat.number(before)) ms.")
        case .recoveryUp, .recoveryDown:
            return String(localized: "\(ScoreKind.recovery.format(value)) on average, was \(ScoreKind.recovery.format(before)).")
        case .strainUp, .strainDown:
            return String(localized: "Strain \(ScoreKind.strain.format(value)) on average, was \(ScoreKind.strain.format(before)).")
        case .timingIrregular:
            return String(localized: "Bed and wake times shift by about \(FBFormat.number(value)) min from night to night.")
        case .timingSteady:
            return String(localized: "Bed and wake times stay within about \(FBFormat.number(value)) min.")
        }
    }
}

// MARK: - Shared chart parts

private struct LegendItem: View {
    let color: Color
    let text: String
    var round = false

    var body: some View {
        HStack(spacing: FBSpace.xxs) {
            Group {
                if round { Circle().fill(color) } else { RoundedRectangle(cornerRadius: 2).fill(color) }
            }
            .frame(width: 8, height: 8)
            Text(text)
        }
        .textStyle(.caption)
        .foregroundStyle(.textSecondary)
    }
}

private extension View {
    /// Day labels under a chart, thinned to the range as in TrendChart.
    func dayAxis(_ range: TrendRange, from: Date, to: Date) -> some View {
        chartXScale(domain: from ... to.addingTimeInterval(86_400))
            .chartXAxis {
                switch range {
                case .week:
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true, collisionResolution: .greedy)
                            .font(.fb(.caption)).foregroundStyle(.textSecondary)
                    }
                case .month:
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated), collisionResolution: .greedy)
                            .font(.fb(.caption)).foregroundStyle(.textSecondary)
                    }
                case .quarter:
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated), collisionResolution: .greedy)
                            .font(.fb(.caption)).foregroundStyle(.textSecondary)
                    }
                }
            }
            .chartPlotStyle { plot in
                plot.overlay(alignment: .bottom) { Rectangle().fill(.hairlineStrong).frame(height: FBStroke.hairline) }
            }
    }
}

@AxisMarkBuilder private func gridMark(_ label: String) -> some AxisMark {
    AxisGridLine(stroke: StrokeStyle(lineWidth: FBStroke.hairline)).foregroundStyle(.hairline)
    AxisValueLabel { Text(label).font(.fb(.caption)).foregroundStyle(.textSecondary) }
}

private func noData(_ text: String) -> some View {
    Text(text).textStyle(.subhead).foregroundStyle(.textSecondary).frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
}

// MARK: - Strain and recovery

/// The day's load as a bar and the recovery it met as a dot in its band's colour, on one
/// grid: Strain runs 0 to 21 on the left, Recovery 0 to 100 on the right, and the thirds of
/// both fall on the same lines (7 and 14; 33 and 67).
struct StrainRecoveryChart: View {
    let rows: [AnalysisRow]
    let range: TrendRange

    private struct Dot: Identifiable {
        let date: Date
        let recovery: Double
        let run: Int
        var id: Date { date }
    }

    /// Recovery days, with a run number that changes at every gap so lines don't bridge one.
    private var dots: [Dot] {
        var out: [Dot] = []
        var run = 0
        for row in rows {
            if let recovery = row.day.recovery {
                out.append(Dot(date: row.date.addingTimeInterval(43_200), recovery: recovery, run: run))
            } else {
                run += 1
            }
        }
        return out
    }

    var body: some View {
        let dots = dots
        if let first = rows.first, let last = rows.last, rows.contains(where: { $0.day.strain != nil }) || !dots.isEmpty {
            VStack(alignment: .leading, spacing: FBSpace.s) {
                Chart {
                    ForEach(rows) { row in
                        if let strain = row.day.strain {
                            BarMark(x: .value("Day", row.date, unit: .day), y: .value("Strain", strain))
                                .foregroundStyle(Color.activity.opacity(0.55))
                                .cornerRadius(2)
                        }
                    }
                    ForEach(range == .week ? dots : []) { dot in
                        LineMark(x: .value("Day", dot.date), y: .value("Recovery", dot.recovery * 0.21), series: .value("Run", dot.run))
                            .foregroundStyle(Color.textTertiary)
                            .lineStyle(StrokeStyle(lineWidth: 1))
                    }
                    ForEach(dots) { dot in
                        PointMark(x: .value("Day", dot.date), y: .value("Recovery", dot.recovery * 0.21))
                            .foregroundStyle(ScoreBand.recovery(dot.recovery).color)
                            .symbolSize(range == .quarter ? 18 : 46)
                    }
                }
                .chartYScale(domain: 0 ... 21)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 7, 14, 21]) { value in
                        gridMark(value.as(Double.self).map { FBFormat.number($0) } ?? "")
                    }
                    AxisMarks(position: .trailing, values: [0, 7, 14, 21]) { value in
                        AxisValueLabel {
                            Text(value.as(Double.self).map { FBFormat.number(($0 / 0.21).rounded()) } ?? "")
                                .font(.fb(.caption)).foregroundStyle(.textSecondary)
                        }
                    }
                }
                .dayAxis(range, from: first.date, to: last.date)
                .frame(height: 180)
                .accessibilityLabel(Text("Strain and recovery by day"))
                HStack(spacing: FBSpace.s) {
                    LegendItem(color: Color.activity.opacity(0.55), text: String(localized: "Strain, left"))
                    LegendItem(color: .good, text: String(localized: "Recovery, right"), round: true)
                }
            }
        } else {
            noData(String(localized: "No strain or recovery in these days yet."))
        }
    }
}

// MARK: - Sleep against need

/// Each night as a bar of its stages, naps on top, against the line of what is needed.
struct SleepNeedChart: View {
    let rows: [AnalysisRow]
    let range: TrendRange
    let needMinutes: Double

    private struct Part: Identifiable {
        let date: Date
        let order: Int
        let hours: Double
        let color: Color
        var id: String { "\(date.timeIntervalSince1970)-\(order)" }
    }

    private var parts: [Part] {
        rows.flatMap { row -> [Part] in
            guard let total = row.day.sleepMinutes else { return [] }
            var out: [Part] = []
            if let deep = row.deep, let rem = row.rem, let light = row.light, deep + rem + light > 0 {
                out = [Part(date: row.date, order: 0, hours: deep / 60, color: .stageDeep),
                       Part(date: row.date, order: 1, hours: rem / 60, color: .stageRem),
                       Part(date: row.date, order: 2, hours: light / 60, color: .stageLight)]
            } else {
                out = [Part(date: row.date, order: 2, hours: total / 60, color: .stageLight)]
            }
            if row.day.napMinutes > 0 {
                out.append(Part(date: row.date, order: 3, hours: row.day.napMinutes / 60, color: Color.sleep.opacity(0.3)))
            }
            return out
        }
    }

    var body: some View {
        let parts = parts
        if let first = rows.first, let last = rows.last, !parts.isEmpty {
            let longest = rows.compactMap { row in row.day.sleepMinutes.map { $0 + row.day.napMinutes } }.max() ?? 0
            let top = max(needMinutes, longest) / 60 + 1
            VStack(alignment: .leading, spacing: FBSpace.s) {
                Chart {
                    ForEach(parts) { part in
                        BarMark(x: .value("Day", part.date, unit: .day), y: .value("Hours", part.hours))
                            .foregroundStyle(part.color)
                    }
                    RuleMark(y: .value("Need", needMinutes / 60))
                        .foregroundStyle(Color.textSecondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .chartYScale(domain: 0 ... top.rounded(.up))
                .chartYAxis {
                    AxisMarks(position: .leading, values: .stride(by: 2)) { value in
                        gridMark(value.as(Double.self).map { FBFormat.number($0) } ?? "")
                    }
                }
                .dayAxis(range, from: first.date, to: last.date)
                .frame(height: 180)
                .accessibilityLabel(Text("Hours slept each night, against the need"))
                HStack(spacing: FBSpace.s) {
                    LegendItem(color: .stageDeep, text: String(localized: "Deep", comment: "Sleep stage"))
                    LegendItem(color: .stageRem, text: String(localized: "REM", comment: "Sleep stage"))
                    LegendItem(color: .stageLight, text: String(localized: "Light", comment: "Sleep stage"))
                    LegendItem(color: Color.sleep.opacity(0.3), text: String(localized: "Nap"))
                }
            }
        } else {
            noData(String(localized: "No nights in these days yet."))
        }
    }
}

// MARK: - Sleep timing

/// When each night began and ended, on a clock that runs down the page from the evening to
/// the next morning. Bars that line up are a regular rhythm; the dashed lines are the means.
struct SleepTimingChart: View {
    let rows: [AnalysisRow]
    let range: TrendRange
    let timing: SleepTiming?

    /// Clock minutes after noon to a time of day in the phone's format.
    static func clock(_ minute: Double) -> String {
        let noon = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        return FBFormat.time(noon.addingTimeInterval(minute.rounded() * 60))
    }

    var body: some View {
        let nights = rows.filter { $0.day.bedMinute != nil && $0.day.wakeMinute != nil }
        if let first = rows.first, let last = rows.last, !nights.isEmpty {
            let earliest = (nights.compactMap(\.day.bedMinute).min() ?? 600) - 45
            let latest = (nights.compactMap(\.day.wakeMinute).max() ?? 1200) + 45
            let ticks = Array(stride(from: (earliest / 120).rounded(.up) * 120, through: latest, by: 120))
            VStack(alignment: .leading, spacing: FBSpace.s) {
                // The clock is drawn negated so that earlier is higher.
                Chart {
                    ForEach(nights) { row in
                        BarMark(x: .value("Day", row.date, unit: .day),
                                yStart: .value("Bed", -(row.day.bedMinute ?? 0)), yEnd: .value("Wake", -(row.day.wakeMinute ?? 0)),
                                width: range == .week ? .fixed(14) : .automatic)
                            .foregroundStyle(Color.sleep)
                            .cornerRadius(range == .quarter ? 1 : 4)
                    }
                    if let timing {
                        RuleMark(y: .value("Mean bed", -timing.meanBed))
                            .foregroundStyle(Color.textSecondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        RuleMark(y: .value("Mean wake", -timing.meanWake))
                            .foregroundStyle(Color.textSecondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartYScale(domain: -latest ... -earliest)
                .chartYAxis {
                    AxisMarks(position: .leading, values: ticks.map { -$0 }) { value in
                        gridMark(value.as(Double.self).map { Self.clock(-$0) } ?? "")
                    }
                }
                .dayAxis(range, from: first.date, to: last.date)
                .frame(height: 200)
                .accessibilityLabel(Text("Bed and wake time each night"))
                if let timing {
                    HStack(alignment: .top, spacing: FBSpace.m) {
                        fact(String(localized: "Usual bedtime"), Self.clock(timing.meanBed), timing.bedSpread)
                        fact(String(localized: "Usual wake time"), Self.clock(timing.meanWake), timing.wakeSpread)
                    }
                }
            }
        } else {
            noData(String(localized: "No nights in these days yet."))
        }
    }

    private func fact(_ title: String, _ time: String, _ spread: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).textStyle(.caption).foregroundStyle(.textSecondary)
            Text(time).textStyle(.figureM).foregroundStyle(.textPrimary)
            Text("± \(FBFormat.number(spread)) min", comment: "How far a night's bed or wake time is from the usual, on average")
                .textStyle(.caption).foregroundStyle(.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Health monitor

/// One vital against the person's own range.
struct VitalRow: Identifiable {
    let title: String
    let value: Double?
    let text: String
    let range: VitalRange
    var id: String { title }
}

/// The latest vitals, each on a track where the shaded stretch is the person's normal range
/// (two sigma either side of the 14-day median) and the dot is today.
struct HealthMonitorCard: View {
    let rows: [VitalRow]

    var body: some View {
        Card {
            VStack(spacing: FBSpace.m) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    VStack(alignment: .leading, spacing: FBSpace.xs) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.title).textStyle(.body).foregroundStyle(.textPrimary)
                            Spacer(minLength: FBSpace.s)
                            Text(row.value == nil ? "–" : row.text).textStyle(.figureS).foregroundStyle(.textPrimary)
                        }
                        RangeTrack(value: row.value, range: row.range)
                        HStack(alignment: .firstTextBaseline) {
                            Text(status(row)).textStyle(.caption).foregroundStyle(statusColor(row))
                            Spacer(minLength: FBSpace.s)
                            if let low = row.range.low, let high = row.range.high, row.range.status != .calibrating {
                                Text("Usual \(FBFormat.number(low))–\(FBFormat.number(high))", comment: "A vital's normal range")
                                    .textStyle(.caption).foregroundStyle(.textSecondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    if i < rows.count - 1 { Rectangle().fill(.hairline).frame(height: FBStroke.hairline) }
                }
            }
        }
    }

    private func status(_ row: VitalRow) -> String {
        if row.value == nil { return String(localized: "No reading today") }
        switch row.range.status {
        case .calibrating: return String(localized: "Learning your range: \(row.range.days) of \(Analysis.minDays) days")
        case .within: return String(localized: "In your range")
        case .above: return String(localized: "Above your range")
        case .below: return String(localized: "Below your range")
        }
    }

    private func statusColor(_ row: VitalRow) -> Color {
        guard row.value != nil else { return .textTertiary }
        switch row.range.status {
        case .within: return .good
        case .above, .below: return .fair
        case .calibrating: return .textSecondary
        }
    }
}

/// The track spans four sigma either side of the median, so the normal range is always its
/// middle half and the dot's distance from it reads the same for every vital.
private struct RangeTrack: View {
    let value: Double?
    let range: VitalRange

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.hairline).frame(height: 6)
                if range.status != .calibrating {
                    Capsule().fill(Color.textTertiary.opacity(0.55)).frame(width: width / 2, height: 6).offset(x: width / 4)
                    if let value, let low = range.low, let high = range.high, high > low {
                        let start = low - (high - low) / 2
                        let position = min(max((value - start) / (2 * (high - low)), 0.02), 0.98)
                        Circle()
                            .fill(range.status == .within ? Color.textPrimary : Color.fair)
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(.surface, lineWidth: 2))
                            .offset(x: width * position - 6)
                    }
                }
            }
            .frame(height: 12)
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }
}

// MARK: - Heart-rate zones

/// Minutes in each heart-rate zone, a bar a day.
struct ZoneDaysChart: View {
    let rows: [AnalysisRow]
    let range: TrendRange

    private struct Part: Identifiable {
        let date: Date
        let zone: Int
        let minutes: Int
        var id: String { "\(date.timeIntervalSince1970)-\(zone)" }
    }

    var body: some View {
        let parts = rows.flatMap { row in
            (row.zones ?? []).enumerated().compactMap { i, minutes in minutes > 0 ? Part(date: row.date, zone: i + 1, minutes: minutes) : nil }
        }
        if let first = rows.first, let last = rows.last, !parts.isEmpty {
            VStack(alignment: .leading, spacing: FBSpace.s) {
                Chart(parts) { part in
                    BarMark(x: .value("Day", part.date, unit: .day), y: .value("Minutes", part.minutes))
                        .foregroundStyle(Color.zone(part.zone))
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        gridMark(value.as(Int.self).map { FBFormat.number($0) } ?? "")
                    }
                }
                .dayAxis(range, from: first.date, to: last.date)
                .frame(height: 160)
                .accessibilityLabel(Text("Minutes in each heart-rate zone by day"))
                HStack(spacing: FBSpace.s) {
                    ForEach(1 ... 5, id: \.self) { zone in
                        LegendItem(color: .zone(zone), text: String(localized: "Zone \(zone)"))
                    }
                }
            }
        } else {
            noData(String(localized: "No time in heart-rate zones in these days yet."))
        }
    }
}
