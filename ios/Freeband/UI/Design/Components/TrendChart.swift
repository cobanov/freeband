import Charts
import SwiftUI

enum TrendRange: Int, CaseIterable, Identifiable, Sendable {
    case week = 7
    case month = 30
    case quarter = 90

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .week: String(localized: "7 days")
        case .month: String(localized: "30 days")
        case .quarter: String(localized: "90 days")
        }
    }

    var shortTitle: String {
        switch self {
        case .week: String(localized: "7d", comment: "7 days, short")
        case .month: String(localized: "30d", comment: "30 days, short")
        case .quarter: String(localized: "90d", comment: "90 days, short")
        }
    }
}

/// One day's value; nil is a day without data and breaks the line.
struct TrendPoint: Identifiable, Hashable, Sendable {
    let date: Date
    let value: Double?

    var id: Date { date }
}

enum TrendMark: Sendable { case line, bars }

/// The metrics Trends shows, with their chart form: lines for scores, resting HR, SpO₂ and
/// stress; bars for steps, sleep hours, strain and active minutes.
enum TrendMetric: String, CaseIterable, Identifiable, Sendable {
    case recovery, sleepScore, strain, sleepHours, restingHeartRate, steps, bloodOxygen, stress, activeMinutes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recovery: String(localized: "Recovery")
        case .sleepScore: String(localized: "Sleep score")
        case .strain: String(localized: "Strain")
        case .sleepHours: String(localized: "Sleep")
        case .restingHeartRate: String(localized: "Resting heart rate")
        case .steps: String(localized: "Steps")
        case .bloodOxygen: String(localized: "Blood oxygen")
        case .stress: String(localized: "Stress")
        case .activeMinutes: String(localized: "Active minutes")
        }
    }

    var unit: String? {
        switch self {
        case .sleepHours: String(localized: "hours")
        case .restingHeartRate: String(localized: "bpm")
        case .bloodOxygen: "%"
        case .activeMinutes: String(localized: "min")
        default: nil
        }
    }

    var mark: TrendMark {
        switch self {
        case .steps, .sleepHours, .strain, .activeMinutes: .bars
        default: .line
        }
    }

    /// Colour is earned: domain hues where the metric has one, primary ink otherwise.
    var tint: Color {
        switch self {
        case .sleepScore, .sleepHours: .sleep
        case .strain, .steps, .activeMinutes: .activity
        case .restingHeartRate: .heart
        case .recovery, .bloodOxygen, .stress: .textPrimary
        }
    }

    /// Band hairlines on score charts.
    var thresholds: [Double] {
        switch self {
        case .recovery: ScoreKind.recovery.thresholds
        case .sleepScore: ScoreKind.sleep.thresholds
        case .strain: ScoreKind.strain.thresholds
        default: []
        }
    }

    var yDomain: ClosedRange<Double>? {
        switch self {
        case .recovery, .sleepScore: 0...100
        case .strain: 0...21
        default: nil
        }
    }

    func format(_ value: Double, locale: Locale = .current) -> String {
        switch self {
        case .strain, .sleepHours: value.formatted(.number.precision(.fractionLength(1)).locale(locale))
        default: value.formatted(.number.precision(.fractionLength(0)).locale(locale))
        }
    }
}

/// A metric over 7, 30 or 90 days (90 shows weekly means). Header: title with unit, then the
/// value line, the average until you drag across the chart, then the selected day (no floating
/// tooltip). A dashed rule marks the average; on score charts the band thresholds are the
/// y ticks and their gridlines. The y axis sits on the trailing edge with three ticks.
struct TrendChart: View {
    enum Style {
        /// Header, value line, range control, axes and scrubbing.
        case full
        /// A static Trends list card: title, average and a small chart without axes.
        case compact
    }

    let title: String
    var unit: String?
    var mark: TrendMark = .line
    var tint: Color = .textPrimary
    var thresholds: [Double] = []
    var yDomain: ClosedRange<Double>?
    var format: (Double, Locale) -> String
    let points: [TrendPoint]
    @Binding var range: TrendRange
    var showsRangePicker = true
    var style: Style = .full

    @State private var selectedDate: Date?
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .caption) private var fullHeight: CGFloat = 168

    /// `selected` pre-selects a day (previews, the gallery, restoring a scrub).
    init(metric: TrendMetric, points: [TrendPoint], range: Binding<TrendRange>,
         showsRangePicker: Bool = true, style: Style = .full, selected: Date? = nil) {
        self.title = metric.title
        self.unit = metric.unit
        self.mark = metric.mark
        self.tint = metric.tint
        self.thresholds = metric.thresholds
        self.yDomain = metric.yDomain
        self.format = { metric.format($0, locale: $1) }
        self.points = points
        _range = range
        self.showsRangePicker = showsRangePicker
        self.style = style
        _selectedDate = State(initialValue: selected)
    }

    init(title: String, unit: String? = nil, mark: TrendMark = .line, tint: Color = .textPrimary,
         thresholds: [Double] = [], yDomain: ClosedRange<Double>? = nil,
         format: @escaping (Double, Locale) -> String = { $0.formatted(.number.precision(.fractionLength(0)).locale($1)) },
         points: [TrendPoint], range: Binding<TrendRange>, showsRangePicker: Bool = true, style: Style = .full,
         selected: Date? = nil) {
        self.title = title
        self.unit = unit
        self.mark = mark
        self.tint = tint
        self.thresholds = thresholds
        self.yDomain = yDomain
        self.format = format
        self.points = points
        _range = range
        self.showsRangePicker = showsRangePicker
        self.style = style
        _selectedDate = State(initialValue: selected)
    }

    // MARK: data

    struct Bucket: Identifiable, Hashable {
        let date: Date
        let value: Double?
        /// Contiguous run of known values, so gaps break the line.
        let run: Int
        var id: Date { date }
    }

    private var calendar: Calendar { .current }
    private var bucketUnit: Calendar.Component { range == .quarter ? .weekOfYear : .day }

    /// The visible days (or weekly means for 90 days), oldest first.
    var buckets: [Bucket] {
        let sorted = points.sorted { $0.date < $1.date }
        guard let last = sorted.last else { return [] }
        let end = calendar.startOfDay(for: last.date)
        guard let start = calendar.date(byAdding: .day, value: -(range.rawValue - 1), to: end) else { return [] }
        let days = sorted.filter { $0.date >= start && calendar.startOfDay(for: $0.date) <= end }
        var raw: [(Date, Double?)]
        if range == .quarter {
            var weeks: [Date: [Double]] = [:]
            var order: [Date] = []
            for day in days {
                let week = calendar.dateInterval(of: .weekOfYear, for: day.date)?.start ?? day.date
                if weeks[week] == nil { weeks[week] = []; order.append(week) }
                if let v = day.value { weeks[week]?.append(v) }
            }
            raw = order.map { week in
                let values = weeks[week] ?? []
                return (week, values.isEmpty ? nil : values.reduce(0, +) / Double(values.count))
            }
        } else {
            raw = days.map { (calendar.startOfDay(for: $0.date), $0.value) }
        }
        var run = 0
        var previousKnown = false
        return raw.map { date, value in
            if value != nil && !previousKnown { run += 1 }
            previousKnown = value != nil
            return Bucket(date: date, value: value, run: run)
        }
    }

    private func average(_ buckets: [Bucket]) -> Double? {
        let known = buckets.compactMap(\.value)
        return known.isEmpty ? nil : known.reduce(0, +) / Double(known.count)
    }

    private func domain(_ buckets: [Bucket], average: Double?) -> ClosedRange<Double> {
        if let yDomain { return yDomain }
        let known = buckets.compactMap(\.value) + (average.map { [$0] } ?? [])
        guard let lo = known.min(), let hi = known.max() else { return 0...1 }
        if mark == .bars { return 0...max(hi * 1.1, 1) }
        let pad = max((hi - lo) * 0.25, 1)
        return (lo - pad).rounded(.down)...(hi + pad).rounded(.up)
    }

    /// Score charts tick at their band thresholds (plus the top when that makes three).
    private func ticks(_ domain: ClosedRange<Double>) -> [Double]? {
        let inside = thresholds.filter { domain.contains($0) }
        guard !inside.isEmpty else { return nil }
        return inside.count >= 3 ? inside : inside + [domain.upperBound]
    }

    private func nearest(to date: Date, in buckets: [Bucket]) -> Bucket? {
        buckets.filter { $0.value != nil }.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    // MARK: view

    var body: some View {
        let buckets = buckets
        let average = average(buckets)
        let selected = selectedDate.flatMap { nearest(to: $0, in: buckets) }
        VStack(alignment: .leading, spacing: style == .full ? FBSpace.xs : FBSpace.xs) {
            switch style {
            case .full:
                Text(heading)
                    .textStyle(.headline)
                    .foregroundStyle(.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: FBSpace.s) {
                        valueLine(average: average, selected: selected)
                        Spacer(minLength: 0)
                        rangePicker
                    }
                    VStack(alignment: .leading, spacing: FBSpace.xs) {
                        valueLine(average: average, selected: selected)
                        rangePicker
                    }
                }
                .padding(.bottom, FBSpace.xs)
            case .compact:
                VStack(alignment: .leading, spacing: 0) {
                    Text(heading)
                        .textStyle(.subhead)
                        .foregroundStyle(.textSecondary)
                    HStack(alignment: .firstTextBaseline, spacing: FBSpace.xs) {
                        Text(average.map { format($0, locale) } ?? "–")
                            .textStyle(.figureM)
                            .foregroundStyle(average == nil ? Color.textTertiary : Color.textPrimary)
                        Text("avg")
                            .textStyle(.caption)
                            .foregroundStyle(.textSecondary)
                        Spacer(minLength: FBSpace.xs)
                        if let change = changeOnPreviousPeriod {
                            Text("\(Image(systemName: change.symbol)) \(change.text)")
                                .textStyle(.subhead)
                                .imageScale(.small)
                                .monospacedDigit()
                                .foregroundStyle(.textSecondary)
                                .accessibilityLabel(Text(change.spoken))
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if average == nil {
                Text("No data for these days.")
                    .textStyle(.body)
                    .foregroundStyle(.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: chartHeight, alignment: .center)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(.hairlineStrong).frame(height: FBStroke.hairline)
                    }
            } else {
                chart(buckets: buckets, average: average, selected: selected)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var chartHeight: CGFloat { style == .full ? fullHeight : 72 }

    /// The mean of the shown days against the mean of the same number of days before them.
    /// Nil when either side has fewer than 3 days, so for 90 days (the points go back 90).
    private var changeOnPreviousPeriod: MetricDelta? {
        let now = points.suffix(range.rawValue).compactMap(\.value)
        let before = points.dropLast(range.rawValue).suffix(range.rawValue).compactMap(\.value)
        guard now.count >= 3, before.count >= 3 else { return nil }
        let difference = now.reduce(0, +) / Double(now.count) - before.reduce(0, +) / Double(before.count)
        let text = format(abs(difference), locale)
        if format(0, locale) == text { return MetricDelta(.flat, text) }
        return MetricDelta(difference > 0 ? .up : .down, text)
    }

    private var heading: String { [title, unit].compactMap { $0 }.joined(separator: ", ") }

    @ViewBuilder private var rangePicker: some View {
        if showsRangePicker {
            SegmentedPicker(String(localized: "Range"), selection: $range, options: TrendRange.allCases, fillsWidth: false) {
                $0.shortTitle
            }
            .fixedSize()
        }
    }

    /// "76 avg · 7 days", or while scrubbing "58 Tue 13 Oct".
    @ViewBuilder private func valueLine(average: Double?, selected: Bucket?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: FBSpace.xs) {
            if let selected, let value = selected.value {
                Text(format(value, locale))
                    .textStyle(.figureM)
                    .foregroundStyle(.textPrimary)
                Text(selectedLabel(selected.date))
                    .textStyle(.subhead)
                    .foregroundStyle(.textSecondary)
            } else if let average {
                Text(format(average, locale))
                    .textStyle(.figureM)
                    .foregroundStyle(.textPrimary)
                Text(range == .quarter ? String(localized: "weekly avg") : String(localized: "avg · \(range.title)"))
                    .textStyle(.subhead)
                    .foregroundStyle(.textSecondary)
            } else {
                Text("–")
                    .textStyle(.figureM)
                    .foregroundStyle(.textTertiary)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private func selectedLabel(_ date: Date) -> String {
        if range == .quarter {
            let day = date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
            return String(localized: "week of \(day)", comment: "Selected weekly mean")
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(locale))
    }

    private func axisNumber(_ value: Double) -> String {
        if value >= 1000 { return value.formatted(.number.notation(.compactName).locale(locale)) }
        return value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
    }

    private func chart(buckets: [Bucket], average: Double?, selected: Bucket?) -> some View {
        let bold = legibilityWeight == .bold
        let yDomain = domain(buckets, average: average)
        let bandTicks = ticks(yDomain)
        let lastKnown = buckets.last { $0.value != nil }
        let runs = Dictionary(grouping: buckets.filter { $0.value != nil }, by: \.run)
        return Chart {
            switch mark {
            case .bars:
                ForEach(buckets.filter { $0.value != nil }) { bucket in
                    BarMark(x: .value("Day", bucket.date, unit: bucketUnit),
                            y: .value(title, bucket.value ?? 0),
                            width: .ratio(0.5))
                    .foregroundStyle(tint.opacity(selected == nil || selected?.date == bucket.date ? 1 : 0.35))
                }
            case .line:
                ForEach(buckets.filter { $0.value != nil }) { bucket in
                    LineMark(x: .value("Day", bucket.date, unit: bucketUnit),
                             y: .value(title, bucket.value ?? 0),
                             series: .value("Run", bucket.run))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: FBStroke.chartLine, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
                }
                // A run of one day has no line to draw: show it as a dot.
                ForEach(runs.values.filter { $0.count == 1 }.compactMap(\.first)) { bucket in
                    PointMark(x: .value("Day", bucket.date, unit: bucketUnit), y: .value(title, bucket.value ?? 0))
                        .foregroundStyle(tint)
                        .symbolSize(24)
                }
                if selected == nil, let lastKnown, let value = lastKnown.value {
                    PointMark(x: .value("Day", lastKnown.date, unit: bucketUnit), y: .value(title, value))
                        .foregroundStyle(.surface)
                        .symbolSize(140)
                    PointMark(x: .value("Day", lastKnown.date, unit: bucketUnit), y: .value(title, value))
                        .foregroundStyle(tint)
                        .symbolSize(64)
                }
            }
            if let average {
                RuleMark(y: .value("Average", average))
                    .lineStyle(StrokeStyle(lineWidth: FBStroke.hairline, dash: [3, 3]))
                    .foregroundStyle(.textSecondary)
            }
            if let selected, let value = selected.value {
                RuleMark(x: .value("Selected", selected.date, unit: bucketUnit))
                    .lineStyle(StrokeStyle(lineWidth: FBStroke.hairline))
                    .foregroundStyle(.textSecondary)
                if mark == .line {
                    PointMark(x: .value("Day", selected.date, unit: bucketUnit), y: .value(title, value))
                        .foregroundStyle(.surface)
                        .symbolSize(140)
                    PointMark(x: .value("Day", selected.date, unit: bucketUnit), y: .value(title, value))
                        .foregroundStyle(tint)
                        .symbolSize(64)
                }
            }
        }
        .chartYScale(domain: yDomain)
        .chartXSelection(value: $selectedDate)
        .chartXAxis {
            if style == .full {
                switch range {
                case .week:
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.abbreviated).locale(locale), centered: true, collisionResolution: .greedy)
                            .font(.fb(.caption, bold: bold))
                            .foregroundStyle(.textSecondary)
                    }
                case .month:
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated).locale(locale), collisionResolution: .greedy)
                            .font(.fb(.caption, bold: bold))
                            .foregroundStyle(.textSecondary)
                    }
                case .quarter:
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).locale(locale), collisionResolution: .greedy)
                            .font(.fb(.caption, bold: bold))
                            .foregroundStyle(.textSecondary)
                    }
                }
            }
        }
        .chartYAxis {
            if style == .full {
                if let bandTicks {
                    AxisMarks(position: .trailing, values: bandTicks) { value in
                        yMark(value, bold: bold, color: .hairlineStrong)
                    }
                } else {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                        yMark(value, bold: bold, color: .hairline)
                    }
                }
            }
        }
        .chartXAxis(style == .full ? .visible : .hidden)
        .chartYAxis(style == .full ? .visible : .hidden)
        .chartPlotStyle { plot in
            plot.overlay(alignment: .bottom) {
                Rectangle().fill(.hairlineStrong).frame(height: FBStroke.hairline)
            }
        }
        .frame(height: chartHeight)
        .accessibilityLabel(heading)
        .accessibilityChartDescriptor(self)
    }

    @AxisMarkBuilder private func yMark(_ value: AxisValue, bold: Bool, color: Color) -> some AxisMark {
        AxisGridLine(stroke: StrokeStyle(lineWidth: FBStroke.hairline))
            .foregroundStyle(color)
        AxisValueLabel {
            if let number = value.as(Double.self) {
                Text(axisNumber(number))
                    .font(.fb(.caption, bold: bold))
                    .foregroundStyle(.textSecondary)
            }
        }
    }
}

extension TrendChart: AXChartDescriptorRepresentable {
    func makeChartDescriptor() -> AXChartDescriptor {
        let buckets = buckets
        let labels = buckets.map { $0.date.formatted(.dateTime.day().month(.abbreviated)) }
        let x = AXCategoricalDataAxisDescriptor(title: range == .quarter ? String(localized: "Week") : String(localized: "Day"),
                                                categoryOrder: labels)
        let yRange = domain(buckets, average: average(buckets))
        let y = AXNumericDataAxisDescriptor(title: heading, range: yRange, gridlinePositions: thresholds) { format($0, .current) }
        let points = zip(labels, buckets).map { label, bucket in AXDataPoint(x: label, y: bucket.value) }
        let series = AXDataSeriesDescriptor(name: title, isContinuous: mark == .line, dataPoints: points)
        let summary = average(buckets).map { String(localized: "Average \(format($0, .current))") }
        return AXChartDescriptor(title: heading, summary: summary, xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}

#Preview("TrendChart") {
    FBPreviewMatrix {
        Card { TrendChart(metric: .recovery, points: DesignSamples.days(DesignSamples.recovery), range: .constant(.week)) }
        Card { TrendChart(metric: .steps, points: DesignSamples.days(DesignSamples.steps), range: .constant(.month)) }
        Card { TrendChart(metric: .stress, points: [], range: .constant(.week)) }
    }
}
