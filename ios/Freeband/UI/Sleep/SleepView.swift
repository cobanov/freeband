import Charts
import SwiftUI

/// The Sleep tab: one night at a time, newest first.
struct SleepView: View {
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        NavigationStack(path: $router.sleepPath) {
            SelectedBand { band in
                if let band {
                    BandHealthReader(band: band) { history in
                        SleepNightScreen(band: band, history: history, initialDay: nil)
                    }
                } else {
                    ScrollView {
                        EmptyState(systemImage: "moon", title: String(localized: "No band yet"),
                                   message: String(localized: "Add your band to see your nights."))
                            .padding(.horizontal, FBSpace.gutter)
                    }
                    .fbScreen()
                    .navigationTitle(String(localized: "Sleep"))
                }
            }
            .routeDestinations()
        }
    }
}

/// A night: duration, bed and wake, the score, stages, heart rate, blood oxygen, HRV, naps and
/// where the numbers came from.
struct SleepNightScreen: View {
    let band: Band
    let history: HealthHistory
    let initialDay: DayKey?

    @State private var selected: DayKey?
    @ScaledMetric(relativeTo: .body) private var chevronSize: CGFloat = 17

    private var nights: [DayKey] { history.nights }
    private var day: DayKey? { selected ?? initialDay ?? nights.last }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FBSpace.l) {
                if let day, let night = history.mainSleep(day) {
                    content(day: day, night: night)
                } else {
                    EmptyState(systemImage: "moon", title: String(localized: "No nights yet"),
                               message: String(localized: "No sleep history is stored in Freeband yet. Sync the band and check Diagnostics for the files it returned. History available only in Mi Fitness cannot be imported."))
                }
            }
            .padding(.horizontal, FBSpace.gutter)
            .padding(.bottom, FBSpace.xl)
        }
        .fbScreen()
        .navigationTitle(String(localized: "Sleep"))
        .navigationBarTitleDisplayMode(.large)
    }

    private func step(_ by: Int) {
        guard let day, let i = nights.firstIndex(of: day) else { return }
        let j = i + by
        if nights.indices.contains(j) { selected = nights[j] }
    }

    @ViewBuilder private func content(day: DayKey, night: SleepRecord) -> some View {
        let result = history.result(day)
        let metrics = result?.sleep.metrics
        let index = nights.firstIndex(of: day) ?? 0

        VStack(alignment: .leading, spacing: FBSpace.xxs) {
            HStack(alignment: .center, spacing: FBSpace.xs) {
                Text(FBFormat.nightTitle(bedTime: night.bedTime))
                    .textStyle(.subhead)
                    .foregroundStyle(.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                pager("chevron.left", String(localized: "Previous night"), enabled: index > 0) { step(-1) }
                pager("chevron.right", String(localized: "Next night"), enabled: index < nights.count - 1) { step(1) }
            }
            Text(FBFormat.duration(minutes: metrics?.totalSleepMinutes ?? Double(night.totalSleepMinutes ?? 0)))
                .textStyle(.figureL)
                .foregroundStyle(.textPrimary)
                .accessibilityLabel(Text("Slept \(FBFormat.duration(minutes: metrics?.totalSleepMinutes ?? 0))"))
            Text(spanLine(night: night, metrics: metrics))
                .textStyle(.subhead)
                .foregroundStyle(.textSecondary)
        }

        ListCard {
            NavigationLink(value: Route.score(.sleep, day: day.index)) {
                ListRow(title: String(localized: "Sleep score"), value: scoreValue(day), systemImage: "moon", showsDivider: false)
            }
            .buttonStyle(.fbRow)
        }

        let segments = night.hypnogramSegments
        if !segments.isEmpty {
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                SectionHeader(title: String(localized: "Stages"))
                Card { Hypnogram(segments: segments) }
            }
        }

        let hr = night.heartRatePoints
        if hr.count > 1 {
            let values = hr.map(\.value)
            let minimum = metrics?.hrMinimum ?? values.min() ?? 0
            let average = metrics?.hrAverage ?? values.reduce(0, +) / Double(values.count)
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                SectionHeader(title: String(localized: "Heart rate, bpm"),
                              trailing: String(localized: "min \(FBFormat.number(minimum)) · avg \(FBFormat.number(average))"))
                Card { NightLineChart(points: hr, tint: .heart, label: String(localized: "Heart rate")) }
            }
        }

        let spo2 = night.spo2Points
        if spo2.count > 1 {
            let values = spo2.map(\.value)
            let average = metrics?.spo2Average ?? values.reduce(0, +) / Double(values.count)
            let minimum = metrics?.spo2Minimum ?? values.min() ?? 0
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                SectionHeader(title: String(localized: "Blood oxygen, %"),
                              trailing: String(localized: "avg \(FBFormat.number(average)) · min \(FBFormat.number(minimum))"))
                Card { NightLineChart(points: spo2, tint: .textPrimary, label: String(localized: "Blood oxygen")) }
                if let below = metrics?.spo2Below90Minutes {
                    Footnote(below > 0 ? String(localized: "\(FBFormat.number(below)) min below 90%.")
                                       : String(localized: "No minutes below 90%."))
                }
            }
        }

        details(day: day, night: night, result: result)

        let naps = history.naps(day)
        if !naps.isEmpty {
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                SectionHeader(title: String(localized: "Naps"))
                ListCard {
                    ForEach(Array(naps.enumerated()), id: \.offset) { i, nap in
                        ListRow(title: FBFormat.span(nap.bedTime, nap.wakeTime),
                                value: FBFormat.duration(minutes: nap.wakeTime.timeIntervalSince(nap.bedTime) / 60),
                                accessory: .none, showsDivider: i < naps.count - 1)
                    }
                }
            }
        }

        Footnote(sourceNote(night: night, result: result))
    }

    @ViewBuilder private func details(day: DayKey, night: SleepRecord, result: DayScoreResult?) -> some View {
        let metrics = result?.sleep.metrics
        let rows: [(String, String)] = [
            result?.hrv.map { (String(localized: "Heart rate variability"), String(localized: "≈ \(FBFormat.number($0.rmssd)) ms")) },
            (metrics?.wakeCount ?? night.wakeCount).map { (String(localized: "Wakings"), FBFormat.number($0)) },
            metrics?.wasoMinutes.map { (String(localized: "Awake after falling asleep"), FBFormat.duration(minutes: $0)) },
            metrics?.hrLowest5Min.map { (String(localized: "Lowest heart rate"), FBFormat.bpm($0)) },
        ].compactMap { $0 }
        if !rows.isEmpty {
            ListCard {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    ListRow(title: row.0, value: row.1, accessory: .none, showsDivider: i < rows.count - 1)
                }
            }
        }
    }

    private func pager(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: min(chevronSize, 28)))
                .foregroundStyle(enabled ? Color.textPrimary : Color.textTertiary)
                .frame(width: FBSize.minTarget, height: FBSize.minTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func spanLine(night: SleepRecord, metrics: SleepMetrics?) -> String {
        var parts = [FBFormat.span(night.bedTime, night.wakeTime)]
        if let efficiency = metrics?.efficiency {
            parts.append(String(localized: "\(FBFormat.percent(efficiency)) efficient", comment: "Sleep efficiency"))
        }
        return parts.joined(separator: " · ")
    }

    private func scoreValue(_ day: DayKey) -> String {
        guard let score = history.score(.sleep, day) else { return String(localized: "No score") }
        return "\(ScoreKind.sleep.format(score)) · \(ScoreBand.sleep(score).word)"
    }

    private func sourceNote(night: SleepRecord, result: DayScoreResult?) -> String {
        let source = night.kind == "stages" ? String(localized: "From the band's sleep stages file.")
                                            : String(localized: "From the band's sleep file.")
        guard let confidence = result?.sleep.confidence else { return source }
        let reasons = confidence.reasons.prefix(2).map(\.localizedText).joined(separator: " ")
        return [source, confidence.level.title + ".", reasons].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

struct NightPoint: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

extension SleepRecord {
    var heartRatePoints: [NightPoint] {
        guard let hrStart else { return [] }
        return hrValues.enumerated().compactMap { i, v in
            ValidRange.hr(Int(v)).map { NightPoint(date: hrStart.addingTimeInterval(TimeInterval(i * hrIntervalSeconds)), value: Double($0)) }
        }
    }

    var spo2Points: [NightPoint] {
        guard let spo2Start else { return [] }
        return spo2Values.enumerated().compactMap { i, v in
            ValidRange.spo2(Int(v)).map { NightPoint(date: spo2Start.addingTimeInterval(TimeInterval(i * spo2IntervalSeconds)), value: Double($0)) }
        }
    }
}

/// A night's series as a thin line; bed and wake label the ends.
struct NightLineChart: View {
    let points: [NightPoint]
    let tint: Color
    let label: String

    var body: some View {
        let values = points.map(\.value)
        let lo = (values.min() ?? 0) - 2
        let hi = (values.max() ?? 1) + 2
        Chart(points) { p in
            LineMark(x: .value(String(localized: "Time"), p.date), y: .value(label, p.value))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: FBStroke.chartLine))
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: lo...hi)
        .chartXAxis {
            AxisMarks(values: [points.first?.date, points.last?.date].compactMap { $0 }) { value in
                AxisValueLabel(anchor: value.index == 0 ? .topLeading : .topTrailing) {
                    if let date = value.as(Date.self) {
                        Text(FBFormat.time(date)).font(.fb(.caption)).foregroundStyle(.textSecondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: FBStroke.hairline)).foregroundStyle(.hairline)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(FBFormat.number(v)).font(.fb(.caption)).foregroundStyle(.textSecondary)
                    }
                }
            }
        }
        .frame(height: 120)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(String(localized: "From \(FBFormat.number(values.min() ?? 0)) to \(FBFormat.number(values.max() ?? 0))")))
    }
}
