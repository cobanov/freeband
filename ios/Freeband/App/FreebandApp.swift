import CoreBluetooth
import SwiftData
import SwiftUI

@main
struct FreebandApp: App {
    @StateObject private var session = AppSession.shared

    init() {
        FBAppearance.configureNavigationBars()
        // Created now, not with the first window: when iOS relaunches the app in the background for
        // the held session there is no window, and the Bluetooth manager must exist at launch
        // (docs/STAY-CONNECTED.md section 3).
        _ = AppSession.shared
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if DesignGallery.isRequested { DesignGallery() } else { app }
            #else
            app
            #endif
        }
    }

    private var app: some View {
        RootView()
            .environmentObject(session)
            .environmentObject(session.model)
            .environmentObject(session.model.link)
            .modelContainer(session.container)
            .id(session.generation)
    }
}

struct RootView: View {
    @AppStorage("onboarded") private var onboarded = false
    @AppStorage(AppearanceSetting.storageKey) private var appearance = AppearanceSetting.system.rawValue
    @AppStorage("selectedBand") private var selectedBand = ""
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var link: BandLink
    @EnvironmentObject private var session: AppSession
    @StateObject private var router = AppRouter()
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Band.addedAt) private var bands: [Band]
    @State private var showsOnboarding = DebugScreen.current == .onboarding

    private var band: Band? { bands.first { $0.id.uuidString == selectedBand } ?? bands.first }

    var body: some View {
        Group {
            if (onboarded || session.isDemo) && !showsOnboarding {
                VStack(spacing: 0) {
                    if session.isDemo { DemoBanner() }
                    TabView(selection: $router.tab) {
                        TodayView()
                            .tabItem { Label("Today", systemImage: "circle.dashed") }
                            .tag(AppTab.today)
                        SleepView()
                            .tabItem { Label("Sleep", systemImage: "moon") }
                            .tag(AppTab.sleep)
                        TrendsView()
                            .tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }
                            .tag(AppTab.trends)
                        BandView()
                            .tabItem { Label("Band", systemImage: "rectangle.portrait") }
                            .tag(AppTab.band)
                    }
                }
                .sheet(item: $model.pendingInvite) { JoinSheet(invite: $0) }
                .sheet(isPresented: $router.showsLive) {
                    if let band { LiveSheet(band: band) }
                }
                .sheet(isPresented: $router.addingBand) {
                    KeyImportSheet { _ in router.addingBand = false }
                }
            } else {
                OnboardingView()
            }
        }
        .environmentObject(router)
        .tint(.textPrimary)
        .preferredColorScheme(AppearanceSetting(rawValue: appearance)?.colorScheme)
        .onOpenURL { model.handle($0) }
        .onChange(of: scenePhase) { _, phase in
            // Live mode keeps the band measuring; never leave it running in the background.
            if phase == .background { model.enterBackground() }
            if phase == .active {
                autoSync()
                // A held session waiting out a retry opens now (after the sync, if one started).
                model.updateHold()
            }
        }
        .onChange(of: link.bluetooth) { _, state in
            if state == .poweredOn { autoSync() }
        }
        .onChange(of: selectedBand) { model.updateHold() }
        .onChange(of: bands.count) { model.updateHold() }
        .fullScreenCover(isPresented: Binding(get: { model.phoneRinging }, set: { if !$0 { model.stopFindPhone() } })) {
            FindPhoneView()
        }
        .onChange(of: link.phase) { old, new in
            if new == .live, old != .live { router.liveEndsAt = Date().addingTimeInterval(BandLink.liveLimit) }
            if new != .live, old == .live { router.liveEndsAt = nil }
        }
        .onChange(of: onboarded) { _, done in
            if !done { showsOnboarding = false }
        }
        .task(id: bands.count) {
            while !Task.isCancelled {
                link.refreshNearby(bands.map { ($0.id, $0.macSuffix) })
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .onAppear(perform: applyDebugScreen)
    }

    /// Plan section 4: sync on open when the last sync is over 15 minutes old.
    private func autoSync() {
        #if DEBUG
        if DemoData.variant(ProcessInfo.processInfo.arguments) != nil { return }
        #endif
        guard !session.isDemo else { return }
        model.autoSyncIfNeeded(band, onboarded: onboarded)
    }

    private func applyDebugScreen() {
        #if DEBUG
        guard let screen = DebugScreen.current else { return }
        let today = DayKey.current(model.today).index + DebugScreen.dayOffset
        switch screen {
        case .today: router.tab = .today
        case .sleep: router.tab = .sleep
        case .trends: router.tab = .trends
        case .band: router.tab = .band
        case .scoreRecovery: router.tab = .today; router.todayPath = [.score(.recovery, day: today)]
        case .scoreSleep: router.tab = .today; router.todayPath = [.score(.sleep, day: today)]
        case .scoreStrain: router.tab = .today; router.todayPath = [.score(.strain, day: today)]
        case .settings: router.tab = .band; router.bandPath = [.settings]
        case .onboarding: showsOnboarding = true
        case .live: router.tab = .today; router.showsLive = true
        }
        #endif
    }
}

/// DEBUG `-freeband-screen <name>` jumps to a screen for screenshots.
enum DebugScreen: String {
    case today, sleep, trends, band, settings, onboarding, live
    case scoreRecovery = "score-recovery"
    case scoreSleep = "score-sleep"
    case scoreStrain = "score-strain"

    /// DEBUG `-freeband-day <offset>`: the day Today and the score screens open on (-1 = yesterday).
    static var dayOffset: Int {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-freeband-day"), i + 1 < args.count else { return 0 }
        return min(0, Int(args[i + 1]) ?? 0)
        #else
        return 0
        #endif
    }

    static var current: DebugScreen? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-freeband-screen"), i + 1 < args.count else { return nil }
        return DebugScreen(rawValue: args[i + 1])
        #else
        return nil
        #endif
    }
}
