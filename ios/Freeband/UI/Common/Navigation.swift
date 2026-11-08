import SwiftData
import SwiftUI

/// Band control commands (alarms, health monitoring, display and Do Not Disturb) land in a
/// later phase. Their rows stay hidden until then.
enum BandFeatures {
    static let controls = false
}

enum AppTab: String, Hashable, CaseIterable {
    case today, sleep, trends, band
}

/// Every pushed screen. Days travel as `DayKey.index` so routes stay plain values.
enum Route: Hashable {
    case score(ScoreKind, day: Int)
    case scoreMethod(ScoreKind, day: Int)
    case trend(TrendMetric, day: Int)
    case night(day: Int)
    case aboutBand(UUID)
    case settings
    case bands
    case profile
    case webAccess
    case appleHealth
    case webhooks
    case shortcuts
    case diagnostics
    case about
}

/// Tab selection, each tab's path and the app-wide sheets.
@MainActor
final class AppRouter: ObservableObject {
    @Published var tab: AppTab = .today
    @Published var todayPath: [Route] = []
    @Published var sleepPath: [Route] = []
    @Published var trendsPath: [Route] = []
    @Published var bandPath: [Route] = []
    @Published var showsLive = false
    @Published var addingBand = false
    /// When the running live session ends (BandLink stops live after `liveLimit`).
    @Published var liveEndsAt: Date?
    /// The band was asked to vibrate; cleared by Stop or after a minute.
    @Published var findingSince: Date?

    var isFinding: Bool { findingSince.map { Date().timeIntervalSince($0) < 60 } ?? false }

    func path(_ tab: AppTab) -> Binding<[Route]> {
        switch tab {
        case .today: Binding(get: { self.todayPath }, set: { self.todayPath = $0 })
        case .sleep: Binding(get: { self.sleepPath }, set: { self.sleepPath = $0 })
        case .trends: Binding(get: { self.trendsPath }, set: { self.trendsPath = $0 })
        case .band: Binding(get: { self.bandPath }, set: { self.bandPath = $0 })
        }
    }

    // MARK: band actions shared by Today, Band and the Live sheet

    func startLive(_ band: Band, model: AppModel) {
        if !(model.link.phase == .live && model.link.bandID == band.id) {
            guard !model.link.phase.isBusy else { showsLive = true; return }
            model.start(band, .live)
        }
        showsLive = true
    }

    func find(_ band: Band, model: AppModel) {
        guard !model.link.phase.isBusy else { return }
        model.findBand(band, start: true)
        findingSince = Date()
    }

    func stopFinding(_ band: Band, model: AppModel) {
        findingSince = nil
        guard !model.link.phase.isBusy else { return }
        model.findBand(band, start: false)
    }
}

/// The band shown everywhere (shared selection), or nil before one is added.
struct SelectedBand<Content: View>: View {
    @Query(sort: \Band.addedAt) private var bands: [Band]
    @AppStorage("selectedBand") private var selectedBand = ""
    @ViewBuilder let content: (Band?) -> Content

    var body: some View {
        content(bands.first { $0.id.uuidString == selectedBand } ?? bands.first)
    }
}

extension View {
    /// The destinations every tab's stack can reach.
    func routeDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            RouteView(route: route)
        }
    }

    /// Canvas behind a scrolling screen.
    func fbScreen() -> some View {
        background(.canvas)
            .scrollContentBackground(.hidden)
    }
}

private struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .settings: SettingsView()
        case .bands: BandsView()
        case .profile: ProfileView()
        case .webAccess: WebAccessView()
        case .appleHealth: AppleHealthView()
        case .webhooks: WebhooksView()
        case .shortcuts: ShortcutsView()
        case .diagnostics: DiagnosticsView()
        case .about: AboutView()
        case .aboutBand(let id): AboutBandView(bandID: id)
        default:
            SelectedBand { band in
                if let band {
                    BandHealthReader(band: band) { history in
                        switch route {
                        case .score(let kind, let day): ScoreDetailView(kind: kind, day: DayKey(index: day), band: band, history: history)
                        case .scoreMethod(let kind, let day): ScoreMethodView(kind: kind, day: DayKey(index: day), history: history)
                        case .trend(let metric, let day): TrendDetailView(metric: metric, day: DayKey(index: day), band: band, history: history)
                        case .night(let day): SleepNightScreen(band: band, history: history, initialDay: DayKey(index: day))
                        default: EmptyView()
                        }
                    }
                }
            }
        }
    }
}
