import AppIntents
import SwiftData

// Siri and Shortcuts: the same actions as the Band tab. They open the app because
// CoreBluetooth needs it running (there is no background Bluetooth mode yet).

private extension AppModel {
    @MainActor
    func selectedBand() -> Band? {
        let bands = ((try? context.fetch(FetchDescriptor<Band>())) ?? []).sorted { $0.addedAt < $1.addedAt }
        let chosen = UserDefaults.standard.string(forKey: "selectedBand")
        return bands.first { $0.id.uuidString == chosen } ?? bands.first
    }
}

struct FindBandIntent: AppIntent {
    static var title: LocalizedStringResource = "Find band"
    static var description = IntentDescription("Makes the band vibrate. Tap the band to stop it.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppModel.shared, let band = model.selectedBand() else {
            return .result(dialog: "There's no band in Freeband yet.")
        }
        guard band.supportsFind else { return .result(dialog: "\(band.shortName) can't vibrate on request.") }
        model.findBand(band, start: true)
        return .result(dialog: "\(band.shortName) is vibrating.")
    }
}

struct SendToBandIntent: AppIntent {
    static var title: LocalizedStringResource = "Send a notification to the band"
    static var description = IntentDescription("Shows a notification from Freeband on the band.")
    static var openAppWhenRun = true

    @Parameter(title: "Message")
    var message: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppModel.shared, let band = model.selectedBand() else {
            return .result(dialog: "There's no band in Freeband yet.")
        }
        model.notify(band, title: "Freeband", body: message)
        return .result(dialog: "Sending the notification to your band.")
    }
}

struct SyncBandIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync band"
    static var description = IntentDescription("Reads today's data and the band's records.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let model = AppModel.shared, let band = model.selectedBand() else {
            return .result(dialog: "There's no band in Freeband yet.")
        }
        model.start(band, .sync)
        return .result(dialog: "Syncing.")
    }
}

struct FreebandShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: FindBandIntent(),
                    phrases: ["Find my band with \(.applicationName)", "\(.applicationName) find my band"],
                    shortTitle: "Find band", systemImageName: "dot.radiowaves.left.and.right")
        AppShortcut(intent: SendToBandIntent(),
                    phrases: ["Send a message to my band with \(.applicationName)"],
                    shortTitle: "Send to band", systemImageName: "text.bubble")
        AppShortcut(intent: SyncBandIntent(),
                    phrases: ["Sync my band with \(.applicationName)"],
                    shortTitle: "Sync band", systemImageName: "arrow.triangle.2.circlepath")
    }
}
