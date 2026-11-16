import SwiftData
import SwiftUI

/// Trends: one range for every card; each card opens the full chart with scrubbing and a day list.
struct TrendsView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var model: AppModel
    @AppStorage("trendRange") private var rangeValue = TrendRange.month.rawValue

    static let metrics: [TrendMetric] = [.recovery, .sleepHours, .strain, .restingHeartRate, .steps, .bloodOxygen, .stress]

    private var range: Binding<TrendRange> {
        Binding(get: { TrendRange(rawValue: rangeValue) ?? .month }, set: { rangeValue = $0.rawValue })
    }

    var body: some View {
        NavigationStack(path: $router.trendsPath) {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: FBSpace.m) {
                    SegmentedPicker(String(localized: "Range"), selection: range, options: TrendRange.allCases) { $0.title }
                    SelectedBand { band in
                        if let band {
                            BandHealthReader(band: band) { history in
                                let today = DayKey.current(model.today)
                                AnalysisSection(history: history, today: today, range: range.wrappedValue)
                                SectionHeader(title: String(localized: "Every metric"))
                                    .padding(.top, FBSpace.s)
                                ForEach(Self.metrics) { metric in
                                    NavigationLink(value: Route.trend(metric, day: today.index)) {
                                        Card {
                                            TrendChart(metric: metric, points: history.points(metric, ending: today),
                                                       range: range, showsRangePicker: false, style: .compact)
                                                .padding(.trailing, FBSpace.xs)
                                        }
                                        .overlay(alignment: .topTrailing) {
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(.textTertiary)
                                                .padding(.top, FBSpace.m)
                                                .padding(.trailing, FBSpace.s - 2)
                                                .accessibilityHidden(true)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } else {
                            EmptyState(systemImage: "chart.xyaxis.line", title: String(localized: "No band yet"),
                                       message: String(localized: "Add your band to see how your days compare."))
                        }
                    }
                }
                .padding(.horizontal, FBSpace.gutter)
                .padding(.bottom, FBSpace.xl)
            }
            .debugScroll(proxy)
            }
            .fbScreen()
            .navigationTitle(String(localized: "Trends"))
            .navigationBarTitleDisplayMode(.large)
            .routeDestinations()
        }
    }
}

/// The period in review and the charts behind it, above the single-metric cards.
private struct AnalysisSection: View {
    let history: HealthHistory
    let today: DayKey
    let range: TrendRange

    var body: some View {
        let length = range.rawValue
        let need = Double(Profile.load().sleepNeed)
        // Twice the range: the review compares it with the period before.
        let all = history.analysisRows(ending: today, count: 2 * length)
        let rows = Array(all.suffix(length))
        let review = Analysis.review(all.map(\.day), ending: today, length: length, sleepNeedMinutes: need, endingIsUnfinished: true)

        ReviewCard(review: review)
        chart(String(localized: "Strain and recovery")) { StrainRecoveryChart(rows: rows, range: range) }
        chart(String(localized: "Sleep against need"), trailing: String(localized: "Need \(FBFormat.duration(minutes: need))")) {
            SleepNeedChart(rows: rows, range: range, needMinutes: need)
        }
        chart(String(localized: "Sleep timing")) { SleepTimingChart(rows: rows, range: range, timing: review.timing) }
        VStack(alignment: .leading, spacing: FBSpace.xs) {
            // The vitals are the night's: before tonight's sleep is in, yesterday is the latest full reading.
            let reference = history.mainSleep(today) != nil ? today : today.adding(days: -1)
            SectionHeader(title: String(localized: "Health monitor"), trailing: FBFormat.shortDay(reference.noon))
            HealthMonitorCard(rows: vitals(reference, lastFullDay: today.adding(days: -1)))
        }
        .padding(.top, FBSpace.s)
        .id("Health monitor")
        chart(String(localized: "Heart-rate zones"), trailing: String(localized: "Minutes a day")) { ZoneDaysChart(rows: rows, range: range) }
    }

    private func chart(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: FBSpace.xs) {
            SectionHeader(title: title, trailing: trailing)
            Card { content() }
        }
        .padding(.top, FBSpace.s)
        .id(title)
    }

    /// The day's vitals against the 60 days before (Baseline uses the latest 14 valid ones).
    /// `night`: the day whose night is read. Stress is a whole day's average, so it is read from
    /// `lastFullDay` when `night` is the day still running.
    private func vitals(_ night: DayKey, lastFullDay: DayKey) -> [VitalRow] {
        func row(_ title: String, on day: DayKey, _ floor: Baseline.Floor, bounds: ClosedRange<Double>? = nil,
                 _ value: (DayKey) -> Double?, _ text: (Double) -> String) -> VitalRow {
            let now = value(day)
            let before = (1 ... Baseline.lookbackDays).compactMap { value(day.adding(days: -$0)) }
            return VitalRow(title: title, value: now, text: now.map(text) ?? "",
                            range: Analysis.range(now, previous: before, floor: floor, bounds: bounds))
        }
        return [
            row(String(localized: "Resting heart rate"), on: night, .restingHR, { history.settledRestingHR($0) }, FBFormat.bpm),
            row(String(localized: "Heart rate variability"), on: night, .hrv, { history.score($0)?.hrv },
                { String(localized: "\(FBFormat.number($0)) ms") }),
            row(String(localized: "Blood oxygen"), on: night, Baseline.Floor(absolute: 1, relative: 0), bounds: 0 ... 100, { history.value(.bloodOxygen, on: $0) },
                { FBFormat.percent($0 / 100) }),
            row(String(localized: "Stress"), on: min(night, lastFullDay), Baseline.Floor(absolute: 5, relative: 0), bounds: 0 ... 100, { history.value(.stress, on: $0) },
                { FBFormat.number($0) }),
        ]
    }
}

/// The full chart for one metric with scrubbing, then every day of the range, newest first.
struct TrendDetailView: View {
    let metric: TrendMetric
    let day: DayKey
    let band: Band
    let history: HealthHistory

    @EnvironmentObject private var model: AppModel
    @AppStorage("trendRange") private var rangeValue = TrendRange.month.rawValue
    @Query private var liveSamples: [Sample]

    init(metric: TrendMetric, day: DayKey, band: Band, history: HealthHistory) {
        self.metric = metric
        self.day = day
        self.band = band
        self.history = history
        let id = band.id
        let start = Calendar.current.startOfDay(for: Date())
        _liveSamples = Query(filter: #Predicate<Sample> { $0.bandID == id && $0.kind == "live" && $0.ts >= start },
                             sort: \Sample.ts)
    }

    private var range: Binding<TrendRange> {
        Binding(get: { TrendRange(rawValue: rangeValue) ?? .month }, set: { rangeValue = $0.rawValue })
    }

    /// Today's steps include the latest live reading, as on Today.
    private var overrides: [DayKey: Double] {
        guard metric == .steps else { return [:] }
        let today = DayKey.current(model.today)
        let steps = [model.daySteps(bandID: band.id), liveSamples.last?.steps].compactMap { $0 }.max()
        return steps.map { [today: Double($0)] } ?? [:]
    }

    var body: some View {
        let points = history.points(metric, ending: day, override: overrides)
        let days = points.suffix(range.wrappedValue.rawValue).reversed().filter { $0.value != nil }
        ScrollView {
            VStack(alignment: .leading, spacing: FBSpace.l) {
                Card { TrendChart(metric: metric, points: points, range: range) }
                VStack(alignment: .leading, spacing: FBSpace.xs) {
                    SectionHeader(title: String(localized: "Days"))
                    if days.isEmpty {
                        Footnote(String(localized: "No data for these days."))
                    } else {
                        ListCard {
                            ForEach(Array(days.enumerated()), id: \.element.id) { i, point in
                                ListRow(title: FBFormat.shortDay(point.date.addingTimeInterval(12 * 3600)),
                                        value: point.value.map { metric.display($0) }, accessory: .none,
                                        showsDivider: i < days.count - 1)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, FBSpace.gutter)
            .padding(.bottom, FBSpace.xl)
        }
        .fbScreen()
        .navigationTitle(metric.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension TrendMetric {
    /// A value with its unit, for lists: "7h 12m", "56 bpm", "96%", "6,412".
    func display(_ value: Double) -> String {
        switch self {
        case .sleepHours: FBFormat.duration(minutes: value * 60)
        case .restingHeartRate: FBFormat.bpm(value)
        case .bloodOxygen: FBFormat.percent(value / 100)
        case .activeMinutes: String(localized: "\(Int(value.rounded())) min")
        default: format(value)
        }
    }
}
