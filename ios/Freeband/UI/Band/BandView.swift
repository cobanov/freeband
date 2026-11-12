import SwiftData
import SwiftUI

/// The band as Tesla shows the car: the render with its live screen, one status line, context
/// while it is true, quick actions and the band's rows. Freeband settings live here too.
struct BandView: View {
    @EnvironmentObject private var router: AppRouter
    @Query(sort: \Band.addedAt) private var bands: [Band]
    @AppStorage("selectedBand") private var selectedBand = ""

    private var band: Band? { bands.first { $0.id.uuidString == selectedBand } ?? bands.first }

    var body: some View {
        NavigationStack(path: $router.bandPath) {
            Group {
                if let band {
                    BandPage(band: band, bands: bands, selectedBand: $selectedBand)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: FBSpace.l) {
                            EmptyState(systemImage: "rectangle.portrait", title: String(localized: "No band yet"),
                                       message: String(localized: "Add your band with the key Mi Fitness keeps on this phone."),
                                       actionTitle: String(localized: "Add band")) { router.addingBand = true }
                            settingsCard
                        }
                        .padding(.horizontal, FBSpace.gutter)
                    }
                    .fbScreen()
                    .navigationTitle(String(localized: "Band"))
                }
            }
            .routeDestinations()
        }
    }

    private var settingsCard: some View {
        ListCard {
            NavigationLink(value: Route.settings) {
                ListRow(title: String(localized: "Freeband settings"), systemImage: "gearshape", showsDivider: false)
            }
            .buttonStyle(.fbRow)
        }
    }
}

private struct BandPage: View {
    let band: Band
    let bands: [Band]
    @Binding var selectedBand: String

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var link: BandLink
    @EnvironmentObject private var router: AppRouter
    @State private var notifying = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(AppModel.stayConnectedKey) private var stayConnected = false

    /// What Stay connected does, and while it's on, whether the session is open right now.
    private var stayConnectedSubtitle: String {
        guard stayConnected else {
            return String(localized: "Lets \(band.shortName) find this phone. Mi Fitness can't connect while it's on.")
        }
        switch link.holdState {
        case .connected where link.bandID == band.id: return String(localized: "Connected. \(band.shortName) can find this phone.")
        default: return String(localized: "Waiting for \(band.shortName)…")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FBSpace.l) {
                if bands.count > 1 {
                    switcher
                }
                TimelineView(.everyMinute) { timeline in
                    BandRender(model: BandPresentation.model(band), state: liveState(timeline.date),
                               height: dynamicTypeSize.isAccessibilitySize ? 150 : 220)
                        .frame(maxWidth: .infinity)
                        .padding(.top, FBSpace.xs)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(band.shortName))
                        .accessibilityValue(Text(renderDescription))
                }

                VStack(alignment: .leading, spacing: FBSpace.xxs) {
                    Text(band.shortName)
                        .textStyle(.headline)
                        .foregroundStyle(.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    StatusLine(name: band.macSuffix.map { String(localized: "ID \($0)") } ?? band.shortName,
                               battery: BandPresentation.battery(link, band),
                               state: BandPresentation.statusState(link, band), lastSync: band.lastSyncAt)
                    if BandPresentation.isSyncing(link, band), let progress = link.fileProgress, progress.total > 0 {
                        ProgressView(value: Double(progress.done), total: Double(progress.total))
                            .tint(.textPrimary)
                            .padding(.top, FBSpace.xxs)
                    }
                }

                BandContextCard(band: band)

                QuickActionRow {
                    QuickActionButton(title: String(localized: "Sync"), systemImage: "arrow.triangle.2.circlepath",
                                      isBusy: BandPresentation.isSyncing(link, band)) { model.start(band, .sync) }
                        .disabled(link.phase.isBusy)
                    if band.supportsFind {
                        QuickActionButton(title: String(localized: "Find"), systemImage: "dot.radiowaves.left.and.right",
                                          isOn: router.isFinding) {
                            if router.isFinding { router.stopFinding(band, model: model) } else { router.find(band, model: model) }
                        }
                    }
                    QuickActionButton(title: String(localized: "Notify"), systemImage: "text.bubble") { notifying = true }
                    QuickActionButton(title: String(localized: "Live HR"), systemImage: "heart",
                                      isOn: BandPresentation.isLive(link, band)) { router.startLive(band, model: model) }
                }

                ListCard {
                    if BandFeatures.controls {
                        ListRow(title: String(localized: "Alarms"), systemImage: "alarm")
                        ListRow(title: String(localized: "Health monitoring"), systemImage: "heart.text.square")
                        ListRow(title: String(localized: "Display & Do Not Disturb"), systemImage: "moon")
                    }
                    ListRow(title: String(localized: "Stay connected"), subtitle: stayConnectedSubtitle,
                            systemImage: "link",
                            accessory: .toggle(Binding(get: { stayConnected }, set: { model.setStayConnected($0) })))
                    NavigationLink(value: Route.aboutBand(band.id)) {
                        ListRow(title: String(localized: "About this band"), value: band.firmware,
                                systemImage: "info.circle", showsDivider: false)
                    }
                    .buttonStyle(.fbRow)
                }

                ListCard {
                    NavigationLink(value: Route.settings) {
                        ListRow(title: String(localized: "Freeband settings"), systemImage: "gearshape", showsDivider: false)
                    }
                    .buttonStyle(.fbRow)
                }
            }
            .padding(.horizontal, FBSpace.gutter)
            .padding(.bottom, FBSpace.xl)
            .animation(FBMotion.standard, value: router.isFinding)
        }
        .fbScreen()
        .refreshable { await model.syncAndWait(band) }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $notifying) { NotifySheet(band: band) }
    }

    /// "Band 10 Pro ⌄" in the top corner when there is more than one band.
    private var switcher: some View {
        HStack {
            Spacer()
            Menu {
                Picker(String(localized: "Band"), selection: $selectedBand) {
                    ForEach(bands) { b in Text(b.displayName).tag(b.id.uuidString) }
                }
            } label: {
                HStack(spacing: FBSpace.xxs) {
                    Text(band.displayName)
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .medium))
                }
                .textStyle(.subhead)
                .foregroundStyle(.textPrimary)
                .frame(minHeight: FBSize.minTarget)
            }
            .accessibilityLabel(Text("Switch band"))
        }
    }

    private func liveState(_ now: Date) -> BandRender.LiveState {
        let live = BandPresentation.isLive(link, band)
        let worn = BandPresentation.isMine(link, band) ? (link.deviceState?.worn ?? true) : true
        return BandRender.LiveState(time: now, battery: BandPresentation.battery(link, band),
                                    charging: BandPresentation.isCharging(link, band),
                                    heartRate: live ? link.stats.map { Int($0.heartRate) }.flatMap { $0 > 0 ? $0 : nil } : nil,
                                    worn: worn)
    }

    private var renderDescription: String {
        var parts: [String] = []
        if let battery = BandPresentation.battery(link, band) { parts.append(String(localized: "Battery \(FBFormat.percent(Double(battery) / 100))")) }
        if BandPresentation.isCharging(link, band) { parts.append(String(localized: "Charging")) }
        return parts.joined(separator: ", ")
    }
}

/// Shows a notification on the band (ported from the Tools sheet).
struct NotifySheet: View {
    let band: Band

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var link: BandLink
    @Environment(\.dismiss) private var dismiss
    @State private var title = "Freeband"
    @State private var message = String(localized: "Hello wrist, it's your phone.")
    @State private var sent = false

    private var busy: Bool { link.phase.isBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: String(localized: "Send a notification"))
            ScrollView {
                VStack(alignment: .leading, spacing: FBSpace.m) {
                    VStack(spacing: 0) {
                        TextField(String(localized: "Title"), text: $title)
                            .padding(FBSpace.s)
                        Rectangle().fill(.hairline).frame(height: FBStroke.hairline).padding(.leading, FBSpace.s)
                        TextField(String(localized: "Message"), text: $message, axis: .vertical)
                            .lineLimit(2...4)
                            .padding(FBSpace.s)
                    }
                    .textStyle(.body)
                    .foregroundStyle(.textPrimary)
                    .fbCardBackground()

                    if sent, link.bandID == band.id, link.phase != .idle {
                        Text(status)
                            .textStyle(.subhead)
                            .foregroundStyle(isFailure ? Color.textPrimary : Color.textSecondary)
                    }
                    Footnote(String(localized: "Close Mi Fitness first. Freeband connects to the band for a moment and then lets go."))
                }
                .padding(.horizontal, FBSpace.gutter)
                .padding(.top, FBSpace.xs)
            }
        }
        .fbPinnedPrimary(String(localized: "Send to band"),
                         isEnabled: !busy && !message.trimmingCharacters(in: .whitespaces).isEmpty) {
            sent = true
            model.notify(band, title: title, body: message)
        }
        .fbSheet(.action)
    }

    private var isFailure: Bool {
        if case .failed = link.phase { return true }
        return false
    }

    private var status: String {
        switch link.phase {
        case .done: String(localized: "Sent to the band.")
        case .failed(let message): message
        default: link.phase.label
        }
    }
}

/// Model, identity, key, firmware, battery and last sync; read the key again or remove the band.
struct AboutBandView: View {
    let bandID: UUID

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Query private var matches: [Band]
    @State private var rereading = false

    init(bandID: UUID) {
        self.bandID = bandID
        _matches = Query(filter: #Predicate<Band> { $0.id == bandID })
    }

    var body: some View {
        ScrollView {
            if let band = matches.first {
                VStack(alignment: .leading, spacing: FBSpace.l) {
                    ListCard {
                        let rows = facts(band)
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                            ListRow(title: row.0, value: row.1, accessory: .none, showsDivider: i < rows.count - 1)
                        }
                    }
                    ListCard {
                        Button { rereading = true } label: {
                            ListRow(title: String(localized: "Read the key again"), systemImage: "key", showsDivider: false)
                        }
                        .buttonStyle(.fbRow)
                    }
                    VStack(alignment: .leading, spacing: FBSpace.xs) {
                        FBDestructiveButton(title: String(localized: "Remove band"),
                                            message: String(localized: "This band's records, raw files, scores and key are deleted from this phone.")) {
                            model.remove(band)
                            dismiss()
                        }
                        Footnote(String(localized: "Removing only deletes the band from Freeband. Its pairing in Mi Fitness stays."))
                    }
                }
                .padding(.horizontal, FBSpace.gutter)
                .padding(.bottom, FBSpace.xl)
            }
        }
        .fbScreen()
        .navigationTitle(matches.first?.displayName ?? String(localized: "About this band"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $rereading) {
            KeyImportSheet(title: String(localized: "Read the key again")) { _ in rereading = false }
        }
    }

    private func facts(_ band: Band) -> [(String, String)] {
        [
            (String(localized: "Model"), band.shortName),
            band.macSuffix.map { (String(localized: "ID"), $0) },
            (String(localized: "Key"), Vault.bandKey(band.id).map { BandKey(hex: $0).masked } ?? String(localized: "None")),
            band.firmware.map { (String(localized: "Firmware"), $0) },
            band.hardwareModel.map { (String(localized: "Hardware"), $0) },
            band.lastBattery.map { (String(localized: "Battery"), FBFormat.percent(Double($0) / 100)) },
            (String(localized: "Last sync"), band.lastSyncAt.map { $0.formatted(date: .abbreviated, time: .shortened) }
                ?? String(localized: "Not synced yet")),
        ].compactMap { $0 }
    }
}
