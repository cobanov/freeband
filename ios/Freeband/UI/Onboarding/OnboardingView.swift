import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// First run, three steps: what Freeband is (with the one warning that matters), the band's key,
/// connect. Progress is three hairline segments, read as "Step 1 of 3".
struct OnboardingView: View {
    @AppStorage("onboarded") private var onboarded = false
    @EnvironmentObject private var session: AppSession
    @State private var step = 1
    @State private var added: [Band] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProgressSegments(step: step, total: 3)
                .padding(.horizontal, FBSpace.gutter)
                .padding(.top, FBSpace.s)
            Group {
                switch step {
                case 1: WelcomeStep(next: { step = 2 }, demo: { session.setDemo(true) })
                case 2: KeyImportStep { bands in added = bands; step = 3 }
                default: ConnectStep(bands: added) { onboarded = true }
                }
            }
            .transition(.fbFade)
        }
        .animation(FBMotion.standard, value: step)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.canvas)
    }
}

struct ProgressSegments: View {
    let step: Int
    let total: Int

    var body: some View {
        HStack(spacing: FBSpace.xs) {
            ForEach(1...total, id: \.self) { i in
                Rectangle()
                    .fill(i <= step ? Color.textPrimary : Color.hairlineStrong)
                    .frame(height: 2)
            }
        }
        .frame(height: FBSpace.m)
        .fbStateAnimation(step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Step \(step) of \(total)"))
    }
}

private struct StepTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .textStyle(.title)
            .foregroundStyle(.textPrimary)
            .accessibilityAddTraits(.isHeader)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct WelcomeStep: View {
    let next: () -> Void
    let demo: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FBSpace.m) {
                BandRender(model: .band10Pro, state: .init(time: Date(), battery: nil),
                           height: dynamicTypeSize.isAccessibilitySize ? 120 : 200)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, FBSpace.m)
                    .accessibilityHidden(true)
                StepTitle(text: String(localized: "Your band, only yours."))
                Text("Freeband talks to your Xiaomi band or watch directly. No account: your data stays on this phone and only leaves it if you turn that on.")
                    .textStyle(.body)
                    .foregroundStyle(.textBody)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Keep Mi Fitness. Freeband reads the band's key from it, and the band still needs it for updates now and then.")
                    .textStyle(.body)
                    .foregroundStyle(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Card {
                    HStack(alignment: .firstTextBaseline, spacing: FBSpace.s) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.low)
                            .accessibilityHidden(true)
                        Text("Don't reset the band or remove it from Mi Fitness. Its key would change and Freeband couldn't connect.")
                            .textStyle(.body)
                            .foregroundStyle(.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
                VStack(alignment: .leading, spacing: FBSpace.xxs) {
                    Button(String(localized: "Try with demo data"), action: demo)
                        .buttonStyle(.fbTertiary)
                    Text("No band at hand? See every screen with 30 days of made-up data. Your real data isn't touched.")
                        .textStyle(.subhead)
                        .foregroundStyle(.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, FBSpace.gutter)
            .padding(.bottom, FBSpace.m)
        }
        .fbPinnedPrimary(String(localized: "Get started"), background: .canvas, action: next)
    }
}

/// Onboarding step 2: pick the Mi Fitness folder, read the keys on the phone, choose bands.
struct KeyImportStep: View {
    var title = String(localized: "Get your band's key")
    let done: ([Band]) -> Void

    @EnvironmentObject private var model: AppModel
    @State private var picking = false
    @State private var found: [BandKey] = []
    @State private var chosen: Set<String> = []
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FBSpace.m) {
                StepTitle(text: title)
                    .padding(.top, FBSpace.m)
                Text("The band only talks to an app that knows its key. Mi Fitness keeps it in its folder on this phone; Freeband reads it from there and stores it only in this phone's keychain.")
                    .textStyle(.body)
                    .foregroundStyle(.textBody)
                    .fixedSize(horizontal: false, vertical: true)

                if found.isEmpty {
                    VStack(alignment: .leading, spacing: FBSpace.s) {
                        instruction(1, String(localized: "Tap Choose folder."))
                        instruction(2, String(localized: "Browse › On My iPhone › Mi Fitness."))
                        instruction(3, String(localized: "Tap Open."))
                    }
                } else {
                    Text(BandKey.groupedByBand(found).count == 1 ? String(localized: "Found this band:")
                                                                 : String(localized: "Found these bands. Choose the ones to add:"))
                        .textStyle(.body)
                        .foregroundStyle(.textSecondary)
                    ListCard {
                        let groups = BandKey.groupedByBand(found)
                        ForEach(Array(groups.enumerated()), id: \.offset) { i, group in
                            bandRow(group, last: i == groups.count - 1)
                        }
                    }
                }

                if let error {
                    Card {
                        VStack(alignment: .leading, spacing: FBSpace.xs) {
                            Label {
                                Text(error).fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.low)
                            }
                            .textStyle(.body)
                            .foregroundStyle(.textPrimary)
                            Text("If the Mi Fitness folder isn't there, open Mi Fitness once and let the band sync.")
                                .textStyle(.subhead)
                                .foregroundStyle(.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if !found.isEmpty {
                    Button(String(localized: "Choose another folder")) { picking = true }
                        .buttonStyle(.fbTertiary)
                }
            }
            .padding(.horizontal, FBSpace.gutter)
            .padding(.bottom, FBSpace.m)
        }
        .fbPinnedPrimary(found.isEmpty ? String(localized: "Choose folder") : String(localized: "Continue"),
                         isEnabled: found.isEmpty || !chosen.isEmpty, background: .canvas) {
            if found.isEmpty {
                picking = true
            } else {
                done(model.add(keys: found.filter { chosen.contains($0.hex) }))
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder, .item]) { result in
            guard case .success(let url) = result else { return }
            do {
                found = try KeyLoader.load(from: url)
                chosen = Set(found.map(\.hex))
                error = nil
            } catch {
                found = []
                self.error = error.localizedDescription
            }
        }
    }

    private func bandRow(_ group: [BandKey], last: Bool) -> some View {
        let lead = group[0]
        let picked = group.allSatisfy { chosen.contains($0.hex) }
        return Button {
            for key in group { if picked { chosen.remove(key.hex) } else { chosen.insert(key.hex) } }
        } label: {
            HStack(spacing: FBSpace.s) {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(picked ? Color.action : Color.textSecondary)
                    .accessibilityHidden(true)
                ListRow(title: Band.displayName(name: BandKey.bestName(group), mac: lead.mac),
                        subtitle: group.count == 1 ? String(localized: "Key \(lead.masked)")
                                                   : String(localized: "\(group.count) keys found; Freeband picks the one that works"),
                        accessory: .none, showsDivider: false)
            }
            .padding(.leading, FBSpace.s)
            .overlay(alignment: .bottom) {
                if !last { Rectangle().fill(.hairline).frame(height: FBStroke.hairline).padding(.leading, FBSpace.s) }
            }
        }
        .buttonStyle(.fbRow)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: FBSpace.s) {
            Text(verbatim: "\(number)")
                .textStyle(.figureS)
                .foregroundStyle(.textSecondary)
                .frame(minWidth: 16, alignment: .leading)
            Text(text)
                .textStyle(.body)
                .foregroundStyle(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Adding a band or reading a key again, from Settings: the key step in a form sheet.
struct KeyImportSheet: View {
    var title = String(localized: "Add band")
    let done: ([Band]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: title)
            KeyImportStep(title: String(localized: "Get your band's key"), done: done)
        }
        .fbSheet(.form)
    }
}

private struct ConnectStep: View {
    let bands: [Band]
    let finish: () -> Void

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var link: BandLink
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var tried = false

    private var band: Band? { bands.first }
    private var succeeded: Bool { tried && link.phase == .done && link.bandID == band?.id }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FBSpace.m) {
                BandRender(model: band.map(BandPresentation.model) ?? .band10Pro,
                           state: .init(time: Date(), battery: succeeded ? link.battery : nil),
                           height: dynamicTypeSize.isAccessibilitySize ? 120 : 200)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, FBSpace.m)
                    .accessibilityHidden(true)
                StepTitle(text: succeeded ? String(localized: "Connected") : String(localized: "Connect"))
                if succeeded {
                    Text(summary)
                        .textStyle(.headline)
                        .foregroundStyle(.textPrimary)
                    if bands.count > 1 {
                        Text("The other bands connect on their first sync.")
                            .textStyle(.body)
                            .foregroundStyle(.textSecondary)
                    }
                } else {
                    Text("Close Mi Fitness from the app switcher and keep \(band?.shortName ?? String(localized: "the band")) on your wrist, close to the phone.")
                        .textStyle(.body)
                        .foregroundStyle(.textBody)
                        .fixedSize(horizontal: false, vertical: true)
                    if let band, tried || link.phase.isBusy {
                        StatusLine(name: band.shortName, battery: nil, state: BandPresentation.statusState(link, band), lastSync: nil)
                    }
                }
            }
            .padding(.horizontal, FBSpace.gutter)
            .padding(.bottom, FBSpace.m)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: FBSpace.xs) {
                if succeeded {
                    Button(String(localized: "Start"), action: finish).buttonStyle(.fbPrimary)
                } else {
                    Button(tried ? String(localized: "Try again") : String(localized: "Connect")) {
                        guard let band else { return }
                        tried = true
                        model.start(band, .check)
                    }
                    .buttonStyle(.fbPrimary)
                    .disabled(link.phase.isBusy || band == nil)
                    Button(String(localized: "Skip for now"), action: finish)
                        .buttonStyle(.fbTertiary(fullWidth: true))
                }
            }
            .padding(.horizontal, FBSpace.gutter)
            .padding(.vertical, FBSpace.xs)
            .background(.canvas)
        }
    }

    private var summary: String {
        var parts: [String] = []
        if let battery = link.battery { parts.append(String(localized: "Battery \(FBFormat.percent(Double(battery) / 100))")) }
        if let stats = link.stats { parts.append(String(localized: "\(FBFormat.number(Int(stats.steps))) steps today")) }
        return parts.isEmpty ? String(localized: "The band answered.") : parts.joined(separator: " · ")
    }
}
