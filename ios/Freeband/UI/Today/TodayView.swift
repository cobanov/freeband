import SwiftData
import SwiftUI

/// Home: the day's verdict, the band in one line, the score triad, context while it is true,
/// quick actions and today's metrics against the 7-day average.
struct TodayView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        NavigationStack(path: $router.todayPath) {
            SelectedBand { band in
                if let band {
                    BandHealthReader(band: band) { history in
                        TodayContent(band: band, history: history)
                    }
                    // A new day (midnight, clock change) rebuilds the day's queries.
                    .id("\(band.id.uuidString)-\(model.today.timeIntervalSince1970)")
                } else {
                    NoBandView()
                }
            }
            .routeDestinations()
        }
    }
}

/// Before any band is added.
private struct NoBandView: View {
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FBSpace.l) {
                Text("Today")
                    .textStyle(.title)
                    .foregroundStyle(.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                EmptyState(systemImage: "rectangle.portrait",
                           title: String(localized: "No band yet"),
                           message: String(localized: "Add your band with the key Mi Fitness keeps on this phone."),
                           actionTitle: String(localized: "Add band")) { router.addingBand = true }
            }
            .padding(.horizontal, FBSpace.gutter)
            .padding(.top, FBSpace.m)
        }
        .fbScreen()
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct TodayContent: View {
    let band: Band
    let history: HealthHistory

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var link: BandLink
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.modelContext) private var context
    @ScaledMetric(relativeTo: .body) private var chevronSize: CGFloat = 17
    @Query private var liveSamples: [Sample]
    @State private var dayOffset = DebugScreen.dayOffset

    init(band: Band, history: HealthHistory) {
        self.band = band
        self.history = history
        let id = band.id
        let start = Calendar.current.startOfDay(for: Date())
        _liveSamples = Query(filter: #Predicate<Sample> { $0.bandID == id && $0.kind == "live" && $0.ts >= start },
                             sort: \Sample.ts)
    }

    private var today: DayKey { DayKey.current(model.today) }
    private var day: DayKey { today.adding(days: dayOffset) }
    private var isToday: Bool { dayOffset == 0 }
    private var syncing: Bool { BandPresentation.isSyncing(link, band) || model.ingestBusy }

    /// Today's steps include the latest live reading (AppModel.daySteps).
    private var todaySteps: Double? {
        let live = liveSamples.last?.steps
        return [model.daySteps(bandID: band.id), live].compactMap { $0 }.max().map(Double.init)
    }

    private var overrides: [DayKey: Double] { todaySteps.map { [today: $0] } ?? [:] }

    /// Early in the day there is nothing fair to compare with yet.
    private func hidesTodayDelta(_ metric: TodayMetric, _ averages: [TodayMetric: Double]) -> Bool {
        switch metric {
        case .activeMinutes: true
        case .steps: (averages[.steps] ?? 0) < 500
        default: false
        }
    }

    /// Today is not over: steps compare with the last 7 days' steps by this time of day, from
    /// their minute files. (Active minutes have no per-minute history, so today shows no delta.)
    private var todayAverages: [TodayMetric: Double] {
        let now = Date()
        let minute = Int(now.timeIntervalSince(Calendar.current.startOfDay(for: now)) / 60)
        let id = band.id
        var totals: [Double] = []
        for back in 1...7 {
            let index = today.adding(days: -back).index
            guard let row = try? context.fetch(FetchDescriptor<MinuteDay>(
                predicate: #Predicate { $0.bandID == id && $0.dayIndex == index })).first else { continue }
            let steps = row.series.steps.prefix(min(max(minute, 0), MinuteSeries.slots))
            totals.append(Double(steps.reduce(0) { $0 + ($1 ?? 0) }))
        }
        guard !totals.isEmpty else { return [:] }
        return [.steps: totals.reduce(0, +) / Double(totals.count)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FBSpace.l) {
                VStack(alignment: .leading, spacing: FBSpace.xs) {
                    header
                    Button { router.tab = .band } label: {
                        StatusLine(name: band.shortName, battery: BandPresentation.battery(link, band),
                                   state: BandPresentation.statusState(link, band), lastSync: band.lastSyncAt,
                                   showsChevron: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Opens the Band tab"))
                    progressLine
                }

                emptyState

                if !isFirstSync {
                    triad
                        .opacity(syncing ? 0.5 : 1)
                        .fbStateAnimation(syncing)
                }

                if isToday {
                    BandContextCard(band: band)
                }

                QuickActionRow {
                    QuickActionButton(title: String(localized: "Sync"), systemImage: "arrow.triangle.2.circlepath",
                                      isBusy: BandPresentation.isSyncing(link, band)) {
                        model.start(band, .sync)
                    }
                    .disabled(link.phase.isBusy)
                    QuickActionButton(title: String(localized: "Live HR"), systemImage: "heart",
                                      isOn: BandPresentation.isLive(link, band)) {
                        router.startLive(band, model: model)
                    }
                    QuickActionButton(title: String(localized: "Find"), systemImage: "dot.radiowaves.left.and.right",
                                      isOn: router.isFinding) {
                        if router.isFinding { router.stopFinding(band, model: model) } else { router.find(band, model: model) }
                    }
                    if BandFeatures.controls {
                        QuickActionButton(title: String(localized: "Alarms"), systemImage: "alarm") {}
                    }
                }

                if !isFirstSync {
                    metrics
                        .opacity(syncing ? 0.5 : 1)
                        .fbStateAnimation(syncing)
                }
            }
            .padding(.horizontal, FBSpace.gutter)
            .padding(.top, FBSpace.xs)
            .padding(.bottom, FBSpace.xl)
            .animation(FBMotion.standard, value: router.isFinding)
        }
        .fbScreen()
        .refreshable { await model.syncAndWait(band) }
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: header

    private var verdict: String {
        if let recovery = history.score(.recovery, day) { return DayVerdict(recovery: recovery).word }
        if let sleep = history.score(.sleep, day) { return ScoreBand.sleep(sleep).word }
        return isToday ? String(localized: "Today") : day.noon.formatted(.dateTime.weekday(.wide))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: FBSpace.xs) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verdict)
                    .textStyle(.title)
                    .foregroundStyle(.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(FBFormat.dayTitle(day.noon))
                    .textStyle(.subhead)
                    .foregroundStyle(.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            pagerButton("chevron.left", label: String(localized: "Previous day"),
                        enabled: history.firstDay.map { day > $0 } ?? false) { dayOffset -= 1 }
            pagerButton("chevron.right", label: String(localized: "Next day"), enabled: dayOffset < 0) { dayOffset += 1 }
        }
        .padding(.top, FBSpace.s)
    }

    private func pagerButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: min(chevronSize, 28), weight: .regular))
                .foregroundStyle(enabled ? Color.textPrimary : Color.textTertiary)
                .frame(width: FBSize.minTarget, height: FBSize.minTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    @ViewBuilder private var progressLine: some View {
        if BandPresentation.isSyncing(link, band), let progress = link.fileProgress, progress.total > 0 {
            ProgressView(value: Double(progress.done), total: Double(progress.total))
                .progressViewStyle(.linear)
                .tint(.textPrimary)
                .accessibilityLabel(Text("Sync progress"))
        }
    }

    // MARK: empty states

    private var isFirstSync: Bool { history.isEmpty && liveSamples.isEmpty }

    @ViewBuilder private var emptyState: some View {
        if isFirstSync {
            EmptyState(systemImage: "arrow.triangle.2.circlepath",
                       title: String(localized: "First sync"),
                       message: String(localized: "Close Mi Fitness, keep the band close and sync. The first sync reads the records the band keeps, up to a week."),
                       actionTitle: String(localized: "Sync")) { model.start(band, .sync) }
                .disabled(link.phase.isBusy)
        } else if isToday, history.score(.recovery, day) == nil, calibratingNights < 3 {
            EmptyState(systemImage: "hourglass",
                       title: String(localized: "Calibrating · \(calibratingNights) of 3 days"),
                       message: String(localized: "Recovery needs at least three earlier valid days of resting heart rate or HRV. Freeband uses history available on the band and this phone; history only in Mi Fitness is not accessible. Keep wearing and syncing the band to build a baseline."))
        }
    }

    /// Use the same previous-day baseline as the score, including older valid days in its lookback.
    private var calibratingNights: Int {
        let counts = history.result(day)?.recovery.contributors.filter { $0.name == .restingHR || $0.name == .hrv }
            .compactMap { $0.baseline?.count } ?? []
        return min(3, counts.max() ?? history.baselineDays(.restingHeartRate, before: day))
    }

    // MARK: scores

    private var triad: some View {
        let rows = dynamicTypeSize >= .xxLarge
        let layout = rows ? AnyLayout(VStackLayout(alignment: .leading, spacing: FBSpace.s))
                          : AnyLayout(HStackLayout(alignment: .top, spacing: 0))
        return layout {
            ForEach([ScoreKind.sleep, .recovery, .strain]) { kind in
                NavigationLink(value: Route.score(kind, day: day.index)) {
                    VStack(alignment: rows ? .leading : .center, spacing: FBSpace.xxs) {
                        ScoreTile(kind: kind, value: history.score(kind, day), layout: rows ? .row : .column)
                        confidenceMarker(kind)
                    }
                    .frame(maxWidth: .infinity, alignment: rows ? .leading : .center)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private func confidenceMarker(_ kind: ScoreKind) -> some View {
        if history.score(kind, day) != nil, let confidence = history.confidence(kind, day), confidence.level.isLow {
            HStack(spacing: FBSpace.xxs) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 10))
                    .accessibilityHidden(true)
                Text("Low confidence")
            }
            .textStyle(.caption)
            .foregroundStyle(.textSecondary)
        }
    }

    // MARK: metrics

    private var metrics: some View {
        VStack(alignment: .leading, spacing: FBSpace.xs) {
            SectionHeader(title: isToday ? String(localized: "Today") : FBFormat.shortDay(day.noon))
            VStack(spacing: 0) {
                let averages = isToday ? todayAverages : [:]
                ForEach(TodayMetric.allCases) { metric in
                    NavigationLink(value: Route.trend(metric.trend, day: day.index)) {
                        let reading = metric.reading(history: history, day: day, overrides: metric == .steps ? overrides : [:],
                                                     average: averages[metric], hidesDelta: isToday && hidesTodayDelta(metric, averages))
                        MetricRow(title: metric.title, value: reading.value, unit: reading.unit,
                                  trend: reading.trend, delta: reading.delta)
                    }
                    .buttonStyle(.fbRow)
                }
            }
            .padding(.horizontal, FBSpace.s)
            .fbCardBackground()
            Footnote(String(localized: "Compared with your 7-day average."))
        }
    }
}

/// The five metrics on Home, each with its value, a 7-day shape and a neutral delta.
enum TodayMetric: String, CaseIterable, Identifiable {
    case steps, restingHeartRate, sleep, activeMinutes, bloodOxygen

    var id: String { rawValue }

    var trend: TrendMetric {
        switch self {
        case .steps: .steps
        case .restingHeartRate: .restingHeartRate
        case .sleep: .sleepHours
        case .activeMinutes: .activeMinutes
        case .bloodOxygen: .bloodOxygen
        }
    }

    var title: String {
        switch self {
        case .steps: String(localized: "Steps")
        case .restingHeartRate: String(localized: "Resting HR")
        case .sleep: String(localized: "Sleep")
        case .activeMinutes: String(localized: "Active minutes")
        case .bloodOxygen: String(localized: "Blood oxygen")
        }
    }

    struct Reading {
        var value: String?
        var unit: String?
        var trend: [Double?]
        var delta: MetricDelta?
    }

    @MainActor
    func reading(history: HealthHistory, day: DayKey, overrides: [DayKey: Double], average override: Double? = nil,
                 hidesDelta: Bool = false) -> Reading {
        func value(_ d: DayKey) -> Double? { overrides[d] ?? history.value(trend, on: d) }
        let current = value(day)
        let week = (0..<7).reversed().map { value(day.adding(days: -$0)) }
        let previous = (1...7).compactMap { value(day.adding(days: -$0)) }
        let average = override ?? (previous.isEmpty ? nil : previous.reduce(0, +) / Double(previous.count))
        var delta: MetricDelta?
        if !hidesDelta, let current, let average {
            delta = makeDelta(current - average, average: average)
        }
        switch self {
        case .steps:
            return Reading(value: current.map { FBFormat.number(Int($0)) }, trend: week, delta: delta)
        case .restingHeartRate:
            return Reading(value: current.map { FBFormat.number($0) }, unit: String(localized: "bpm"), trend: week, delta: delta)
        case .sleep:
            return Reading(value: current.map { FBFormat.duration(minutes: $0 * 60) }, trend: week, delta: delta)
        case .activeMinutes:
            return Reading(value: current.map { FBFormat.number($0) }, unit: String(localized: "min"), trend: week, delta: delta)
        case .bloodOxygen:
            return Reading(value: current.map { FBFormat.percent($0 / 100) }, trend: week, delta: delta)
        }
    }

    private func makeDelta(_ diff: Double, average: Double) -> MetricDelta {
        switch self {
        case .steps:
            guard average > 0 else { return MetricDelta(.flat, "0") }
            let share = diff / average
            if abs(share) < 0.01 { return MetricDelta(.flat, FBFormat.percent(0)) }
            return MetricDelta(share > 0 ? .up : .down, FBFormat.percent(abs(share)))
        case .sleep:
            let minutes = diff * 60
            if abs(minutes) < 5 { return MetricDelta(.flat, "0") }
            return MetricDelta(minutes > 0 ? .up : .down, FBFormat.compactDuration(minutes: abs(minutes)))
        case .restingHeartRate, .activeMinutes, .bloodOxygen:
            let rounded = diff.rounded()
            if rounded == 0 { return MetricDelta(.flat, "0") }
            return MetricDelta(rounded > 0 ? .up : .down, FBFormat.number(abs(rounded)))
        }
    }
}
