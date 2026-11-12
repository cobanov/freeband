import SwiftData
import SwiftUI

// Demo mode (the DemoMode flag lives in DemoData.swift): the session the UI runs on, and the banner.

/// The data store and the app model the UI runs on. Switching demo mode on or off swaps both,
/// and `generation` lets the view tree start over with them.
@MainActor
final class AppSession: ObservableObject {
    @Published private(set) var container: ModelContainer
    @Published private(set) var model: AppModel
    @Published private(set) var generation = 0

    var isDemo: Bool { model.isDemo }

    /// The one session; FreebandApp creates it at launch.
    @MainActor static let shared = AppSession()

    init() {
        (container, model) = Self.make(demo: DemoMode.isOn)
    }

    /// Demo mode never touches the real store or the onboarding flag; leaving it returns to the
    /// app as it was, and to the app proper whenever a real band is already set up.
    func setDemo(_ on: Bool) {
        model.stop()
        // The old model's link goes away with it; let go of a held session first.
        model.link.hold(nil)
        DemoMode.isOn = on
        (container, model) = Self.make(demo: on)
        if !on, ((try? container.mainContext.fetchCount(FetchDescriptor<Band>())) ?? 0) > 0 {
            UserDefaults.standard.set(true, forKey: "onboarded")
        }
        generation += 1
    }

    static let models: [any PersistentModel.Type] = [Band.self, Sample.self, Webhook.self, ActivityBlob.self,
                                                     MinuteDay.self, DaySummary.self, SleepRecord.self, SleepRR.self,
                                                     ManualReading.self, DailyScore.self]

    private static func make(demo: Bool) -> (ModelContainer, AppModel) {
        let container: ModelContainer
        do {
            // New models and the two new ActivityBlob attributes all have defaults, so an existing
            // store migrates lightweight (no VersionedSchema needed for this step).
            container = try ModelContainer(for: Schema(models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: demo))
        } catch {
            fatalError("Couldn't open the data store: \(error)")
        }
        if demo {
            DemoData.seed(container.mainContext, .full)
        } else {
            #if DEBUG
            if let variant = DemoData.variant(ProcessInfo.processInfo.arguments) {
                DemoData.seed(container.mainContext, variant)
                UserDefaults.standard.set(true, forKey: "onboarded")
            }
            #endif
        }
        return (container, AppModel(context: container.mainContext, isDemo: demo))
    }
}

/// The strip above the tabs while demo mode is on.
struct DemoBanner: View {
    @EnvironmentObject private var session: AppSession

    var body: some View {
        HStack(spacing: FBSpace.s) {
            Text("Demo data. Nothing here comes from a band.")
                .textStyle(.subhead)
                .foregroundStyle(.textBody)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(String(localized: "Exit demo")) { session.setDemo(false) }
                .buttonStyle(.fbTertiary)
        }
        .padding(.horizontal, FBSpace.gutter)
        .padding(.vertical, FBSpace.xs)
        .background(.surface)
    }
}
