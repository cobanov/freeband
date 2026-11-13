import SwiftData
import SwiftUI

/// How Freeband and the band deal with each other: the held connection, what happens to
/// records once Freeband has them, and what the phone tells the band. Each switch is off until
/// the user turns it on.
struct BandOptionsView: View {
    let bandID: UUID

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var link: BandLink
    @Query private var matches: [Band]
    @AppStorage(AppModel.stayConnectedKey) private var stayConnected = false
    @AppStorage(AppModel.clearBandKey) private var clearBand = false
    @AppStorage(AppModel.shareLocationKey) private var shareLocation = false
    @AppStorage(AppModel.sleepToBandKey) private var sleepToBand = false

    init(bandID: UUID) {
        self.bandID = bandID
        _matches = Query(filter: #Predicate<Band> { $0.id == bandID })
    }

    private var name: String { matches.first?.shortName ?? String(localized: "the band") }

    /// What Stay connected does, and while it's on, whether the session is open right now.
    private var stayConnectedSubtitle: String {
        guard stayConnected else {
            return String(localized: "Lets \(name) find this phone and sync on its own. Mi Fitness can't connect while it's on.")
        }
        switch link.holdState {
        case .connected where link.bandID == bandID: return String(localized: "Connected. \(name) can find this phone.")
        default: return String(localized: "Waiting for \(name)…")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FBSpace.l) {
                group(String(localized: "Connection")) {
                    ListRow(title: String(localized: "Stay connected"), subtitle: stayConnectedSubtitle, systemImage: "link",
                            accessory: .toggle(Binding(get: { stayConnected }, set: { model.setStayConnected($0) })),
                            showsDivider: false)
                }
                group(String(localized: "Records")) {
                    ListRow(title: String(localized: "Clear the band after sync"),
                            subtitle: String(localized: "The band deletes records Freeband has stored. Mi Fitness won't get them."),
                            systemImage: "tray.and.arrow.down", accessory: .toggle($clearBand))
                    ListRow(title: String(localized: "Show sleep on the band"),
                            subtitle: String(localized: "Experimental. After a night is synced, Freeband sends its summary to the band, as Mi Fitness does to fill the band's own sleep screen. Not tried on a band yet."),
                            systemImage: "moon", accessory: .toggle($sleepToBand), showsDivider: false)
                }
                group(String(localized: "Phone")) {
                    ListRow(title: String(localized: "Share location with the band"),
                            subtitle: String(localized: "The band asks where this phone is at every sync. Freeband answers only while this is on."),
                            systemImage: "location",
                            accessory: .toggle(Binding(get: { shareLocation }, set: { model.setShareLocation($0) })),
                            showsDivider: false)
                }
            }
            .padding(.horizontal, FBSpace.gutter)
            .padding(.bottom, FBSpace.xl)
        }
        .fbScreen()
        .navigationTitle(String(localized: "Connection and data"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func group(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: FBSpace.xs) {
            SectionHeader(title: title)
            ListCard { rows() }
        }
    }
}
