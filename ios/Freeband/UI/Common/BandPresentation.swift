import CoreBluetooth
import SwiftUI
import UIKit

/// Maps BandLink's session and Bluetooth state onto the design system's plain values.
@MainActor
enum BandPresentation {
    static func isMine(_ link: BandLink, _ band: Band) -> Bool { link.bandID == band.id }

    static func isLive(_ link: BandLink, _ band: Band) -> Bool { isMine(link, band) && link.phase == .live }

    static func isSyncing(_ link: BandLink, _ band: Band) -> Bool {
        isMine(link, band) && link.phase.isBusy && link.phase != .live
    }

    static func statusState(_ link: BandLink, _ band: Band) -> StatusLine.State {
        // Demo data: show the band as it looks on a phone, whatever Bluetooth is doing.
        if DemoData.isActive, link.bluetooth != .poweredOn { return .nearby }
        switch link.bluetooth {
        case .poweredOff: return .bluetoothOff
        case .unauthorized: return .bluetoothUnauthorized
        case .unsupported: return .bluetoothUnsupported
        default: break
        }
        if isMine(link, band) {
            switch link.phase {
            case .searching: return .searching
            case .connecting: return .connecting
            case .authenticating: return .authenticating
            case .reading:
                if let progress = link.fileProgress, progress.total > 0 {
                    return .syncing(done: progress.done, total: progress.total)
                }
                return .reading
            case .live: return .live
            case .failed(let message): return .failed(message)
            default: break
            }
        }
        return link.nearby.contains(band.id) ? .nearby : .outOfRange
    }

    static func model(_ band: Band) -> BandRender.Model {
        // By name, like Band.shortName: the watch shares the band10 model code.
        if band.name.localizedCaseInsensitiveContains(Band.redmiWatch5Active) { return .redmiWatch5Active }
        return band.model == "band10pro" ? .band10Pro : .band10
    }

    /// The latest battery: the running session's, else the stored one.
    static func battery(_ link: BandLink, _ band: Band) -> Int? {
        (isMine(link, band) ? link.battery : nil) ?? band.lastBattery
    }

    static func isCharging(_ link: BandLink, _ band: Band) -> Bool {
        isMine(link, band) && link.deviceState?.charging == true
    }

    /// The one action that fixes a failed session.
    enum Fix {
        case retry, readKey, openSettings

        var title: String {
            switch self {
            case .retry: String(localized: "Try again")
            case .readKey: String(localized: "Read key")
            case .openSettings: String(localized: "Settings")
            }
        }
    }

    static func fix(for error: BandLink.LinkError) -> Fix {
        switch error {
        case .wrongKey: .readKey
        case .bluetoothOff, .unauthorized: .openSettings
        default: .retry
        }
    }

    static func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

/// The one ContextCard that is true right now, if any: live, finding, charging, a failed
/// session or Bluetooth off.
struct BandContextCard: View {
    let band: Band
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var link: BandLink
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        Group {
            if BandPresentation.isLive(link, band) {
                ContextCard.live(bpm: link.stats.map { Int($0.heartRate) }.flatMap { $0 > 0 ? $0 : nil },
                                 endsAt: router.liveEndsAt ?? Date().addingTimeInterval(BandLink.liveLimit)) {
                    model.stop()
                }
                .onTapGesture { router.showsLive = true }
            } else if router.isFinding {
                ContextCard.finding { router.stopFinding(band, model: model) }
            } else if BandPresentation.isCharging(link, band), let battery = BandPresentation.battery(link, band) {
                ContextCard.charging(battery: battery, minutesToFull: nil)
            } else if !DemoData.isActive, link.bluetooth == .poweredOff || link.bluetooth == .unauthorized {
                ContextCard.alert(BandLink.message(for: link.bluetooth),
                                  actionTitle: BandPresentation.Fix.openSettings.title) {
                    BandPresentation.openSystemSettings()
                }
            } else if BandPresentation.isMine(link, band), case .failed(let error)? = link.lastOutcome, case .failed = link.phase {
                let fix = BandPresentation.fix(for: error)
                ContextCard.alert(error.message, actionTitle: fix.title) {
                    switch fix {
                    case .retry: model.start(band, .sync)
                    case .readKey: router.addingBand = true
                    case .openSettings: BandPresentation.openSystemSettings()
                    }
                }
            } else if BandPresentation.isMine(link, band), case .partial(let reason) = link.phase {
                ContextCard.alert(reason, actionTitle: String(localized: "Sync")) { model.start(band, .sync) }
            }
        }
        .transition(.fbFade)
    }
}

/// A file (or files) to hand to the share sheet.
struct ShareItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
