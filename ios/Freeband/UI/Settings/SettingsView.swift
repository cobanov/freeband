import SwiftData
import SwiftUI
import UIKit

enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    static let storageKey = "appearance"

    var title: String {
        switch self {
        case .system: String(localized: "appearance.system", defaultValue: "System", comment: "Appearance option")
        case .light: String(localized: "appearance.light", defaultValue: "Light", comment: "Appearance option")
        case .dark: String(localized: "appearance.dark", defaultValue: "Dark", comment: "Appearance option")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Freeband settings (under Band): bands, profile, integrations, data, appearance and language,
/// diagnostics and about.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSession
    @Environment(\.modelContext) private var context
    @Query(sort: \Band.addedAt) private var bands: [Band]
    @Query private var hooks: [Webhook]
    @AppStorage(AppearanceSetting.storageKey) private var appearance = AppearanceSetting.system.rawValue
    @State private var share: ShareItem?
    @State private var exportError: String?

    private var sampleCount: Int { (try? context.fetchCount(FetchDescriptor<Sample>())) ?? 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FBSpace.l) {
                ListCard {
                    link(.bands, String(localized: "Bands"), value: FBFormat.number(bands.count), icon: "rectangle.portrait")
                    link(.profile, String(localized: "Profile"), value: profileSummary, icon: "person", last: true)
                }

                section(String(localized: "Integrations")) {
                    ListCard {
                        link(.appleHealth, String(localized: "Apple Health"), icon: "heart")
                        link(.webAccess, String(localized: "Web access"),
                             value: model.hubEnabled ? String(localized: "On · \(model.hubURL.host ?? "")") : String(localized: "Off"),
                             icon: "globe")
                        link(.webhooks, String(localized: "Webhooks"), value: webhookSummary, icon: "arrow.up.forward.app")
                        link(.shortcuts, String(localized: "Shortcuts & Siri"), icon: "square.2.layers.3d", last: true)
                    }
                }

                section(String(localized: "Data")) {
                    ListCard {
                        Button { export { try Exporter.write(csv: allSamples(), bands: bands) } } label: {
                            ListRow(title: String(localized: "Export CSV"), systemImage: "tablecells", accessory: .none)
                        }
                        .buttonStyle(.fbRow)
                        Button { export { try Exporter.write(json: allSamples(), bands: bands) } } label: {
                            ListRow(title: String(localized: "Export JSON"), systemImage: "curlybraces", accessory: .none)
                        }
                        .buttonStyle(.fbRow)
                        Button { Task { await model.reparseAll() } } label: {
                            ListRow(title: String(localized: "Parse all files again"),
                                    value: model.ingestBusy ? String(localized: "Working…") : nil,
                                    systemImage: "arrow.clockwise", accessory: .none)
                        }
                        .buttonStyle(.fbRow)
                        .disabled(model.ingestBusy)
                        ListRow(title: String(localized: "Demo data"),
                                subtitle: String(localized: "30 made-up days. Your own data stays as it is."),
                                systemImage: "sparkles",
                                accessory: .toggle(Binding(get: { session.isDemo }, set: { session.setDemo($0) })),
                                showsDivider: false)
                    }
                    Footnote(exportError ?? String(localized: "\(FBFormat.number(sampleCount)) readings on this phone. Parsing again rebuilds sleep, minutes and scores from the stored raw files."))
                    FBDestructiveButton(title: String(localized: "Delete data on this phone"),
                                        confirmTitle: String(localized: "Delete data"),
                                        message: String(localized: "Readings, raw files, sleep and scores are deleted. Bands and keys stay. Server and Apple Health data are not deleted. Older history will not be exported again.")) {
                        model.deleteAllData()
                    }
                    if let error = model.dataDeletionError { Footnote(error) }
                }

                section(String(localized: "Appearance")) {
                    SegmentedPicker(String(localized: "Appearance"), selection: Binding(
                        get: { AppearanceSetting(rawValue: appearance) ?? .system },
                        set: { appearance = $0.rawValue }), options: AppearanceSetting.allCases) { $0.title }
                    ListCard {
                        Button { BandPresentation.openSystemSettings() } label: {
                            ListRow(title: String(localized: "Language"), value: languageName, systemImage: "character.bubble",
                                    showsDivider: false)
                        }
                        .buttonStyle(.fbRow)
                    }
                    Footnote(String(localized: "Freeband follows the language you choose for it in iOS Settings."))
                }

                ListCard {
                    link(.diagnostics, String(localized: "Diagnostics"), icon: "stethoscope")
                    link(.about, String(localized: "About"), icon: "info.circle", last: true)
                }
            }
            .padding(.horizontal, FBSpace.gutter)
            .padding(.bottom, FBSpace.xl)
        }
        .fbScreen()
        .navigationTitle(String(localized: "Freeband settings"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $share) { ActivitySheet(items: $0.urls) }
    }

    private func link(_ route: Route, _ title: String, value: String? = nil, icon: String, last: Bool = false) -> some View {
        NavigationLink(value: route) {
            ListRow(title: title, value: value, systemImage: icon, showsDivider: !last)
        }
        .buttonStyle(.fbRow)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: FBSpace.xs) {
            SectionHeader(title: title)
            content()
        }
    }

    private var profileSummary: String? {
        let profile = Profile.load()
        return profile == .unknown ? String(localized: "Not set") : nil
    }

    private var webhookSummary: String? {
        let active = hooks.filter(\.enabled).count
        return active == 0 ? nil : String(localized: "\(active) active")
    }

    private var languageName: String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale.current.localizedString(forLanguageCode: code)?.capitalized(with: Locale.current) ?? code
    }

    private func allSamples() -> [Sample] {
        (try? context.fetch(FetchDescriptor<Sample>(sortBy: [SortDescriptor(\.ts)]))) ?? []
    }

    private func export(_ make: () throws -> URL) {
        do {
            share = ShareItem(urls: [try make()])
            exportError = nil
        } catch {
            exportError = String(localized: "Couldn't export: \(error.localizedDescription)")
        }
    }
}

/// Every band on this phone: add, merge duplicates, open one to remove it.
struct BandsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: AppRouter
    @Query(sort: \Band.addedAt) private var bands: [Band]
    @AppStorage("selectedBand") private var selectedBand = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FBSpace.l) {
                if !bands.isEmpty {
                    ListCard {
                        ForEach(Array(bands.enumerated()), id: \.element.id) { i, band in
                            NavigationLink(value: Route.aboutBand(band.id)) {
                                ListRow(title: band.displayName,
                                        subtitle: StatusLine.synced(band.lastSyncAt, now: Date()),
                                        value: band.id.uuidString == selectedBand || (selectedBand.isEmpty && i == 0)
                                            ? String(localized: "Shown") : nil,
                                        systemImage: "rectangle.portrait", showsDivider: i < bands.count - 1)
                            }
                            .buttonStyle(.fbRow)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: FBSpace.xs) {
                    Button(String(localized: "Add band")) { router.addingBand = true }
                        .buttonStyle(.fbSecondary(fullWidth: true))
                    Button(String(localized: "Merge duplicates")) { model.mergeDuplicateBands() }
                        .buttonStyle(.fbTertiary(fullWidth: true))
                    Footnote(String(localized: "Mi Fitness can list one band more than once. Merging keeps one band per device and moves its records, files and keys."))
                }
            }
            .padding(.horizontal, FBSpace.gutter)
            .padding(.bottom, FBSpace.xl)
        }
        .fbScreen()
        .navigationTitle(String(localized: "Bands"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// What the formulas need to know about you. Saving scores the last 90 days again.
struct ProfileView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = Profile.load()
    @State private var saved = Profile.load()

    private static let currentYear = Calendar.current.component(.year, from: Date())

    private var birthYear: Binding<Int> {
        Binding(get: { draft.age.map { Self.currentYear - $0 } ?? 0 },
                set: { draft.age = $0 == 0 ? nil : Self.currentYear - $0 })
    }

    private func optionalInt(_ keyPath: WritableKeyPath<Profile, Int?>) -> Binding<Int> {
        Binding(get: { draft[keyPath: keyPath] ?? 0 }, set: { draft[keyPath: keyPath] = $0 == 0 ? nil : $0 })
    }

    private func optionalDouble(_ keyPath: WritableKeyPath<Profile, Double?>) -> Binding<Int> {
        Binding(get: { Int(draft[keyPath: keyPath] ?? 0) }, set: { draft[keyPath: keyPath] = $0 == 0 ? nil : Double($0) })
    }

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Birth year"), selection: birthYear) {
                    Text("Not set").tag(0)
                    ForEach((1930...(Self.currentYear - 10)).reversed(), id: \.self) { Text(verbatim: "\($0)").tag($0) }
                }
                Picker(String(localized: "Sex"), selection: $draft.sex) {
                    Text("Not set").tag(Profile.Sex.unknown)
                    Text("Female").tag(Profile.Sex.female)
                    Text("Male").tag(Profile.Sex.male)
                }
                Picker(String(localized: "Height"), selection: optionalDouble(\.heightCm)) {
                    Text("Not set").tag(0)
                    ForEach(120...220, id: \.self) { cm in
                        Text(Measurement(value: Double(cm), unit: UnitLength.centimeters)
                            .formatted(.measurement(width: .abbreviated, usage: .personHeight))).tag(cm)
                    }
                }
                Picker(String(localized: "Weight"), selection: optionalDouble(\.weightKg)) {
                    Text("Not set").tag(0)
                    ForEach(35...200, id: \.self) { kg in
                        Text(Measurement(value: Double(kg), unit: UnitMass.kilograms)
                            .formatted(.measurement(width: .abbreviated, usage: .personWeight))).tag(kg)
                    }
                }
            } footer: {
                Text("Age sets your maximum heart rate (208 − 0.7 × age); sex sets how strain weighs effort. Unknown values use averages, and the scores say so.")
            }
            .fbFormRow()

            Section {
                Picker(String(localized: "Maximum heart rate"), selection: optionalInt(\.maxHROverride)) {
                    Text("From age").tag(0)
                    ForEach(150...220, id: \.self) { Text(FBFormat.bpm(Double($0))).tag($0) }
                }
                Picker(String(localized: "Sleep need"), selection: optionalInt(\.sleepNeedMinutes)) {
                    Text("8 hours (default)").tag(0)
                    ForEach(Array(stride(from: 360, through: 600, by: 15)), id: \.self) {
                        Text(FBFormat.duration(minutes: Double($0))).tag($0)
                    }
                }
            } footer: {
                Text("Set a maximum heart rate only if you measured it. Sleep need is what a full sleep score asks for.")
            }
            .fbFormRow()
        }
        .fbFormStyle()
        .navigationTitle(String(localized: "Profile"))
        .navigationBarTitleDisplayMode(.inline)
        .fbPinnedPrimary(String(localized: "Save"), isEnabled: draft != saved, background: .canvas) {
            draft.save()
            saved = draft
            model.rescoreAll()
            dismiss()
        }
    }
}
