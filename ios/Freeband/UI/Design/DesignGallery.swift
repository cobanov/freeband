#if DEBUG
import SwiftUI
import UIKit

/// Every v3 token and component with realistic sample data, including empty and no-data
/// states. DEBUG only: launch with `-freeband-gallery`; add `-freeband-gallery-section <id>`
/// to open scrolled to a section (ids below, e.g. `scores`, `trends`),
/// `-freeband-gallery-only` to render just that section (screenshots at large text sizes),
/// `-freeband-gallery-sheet action|live|form` to open a sample sheet,
/// `-freeband-gallery-scheme light|dark` to force a theme and `-freeband-gallery-locale en_GB`
/// to format dates and numbers in another locale. Info.plist still pins the app to dark
/// (`UIUserInterfaceStyle`), which also hides the system setting from the screen's traits, so
/// screenshots pass the scheme explicitly until the screens agent drops that key.
struct DesignGallery: View {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-freeband-gallery") }

    static let sections: [(id: String, title: String)] = [
        ("colours", "Colour"),
        ("type", "Type"),
        ("layout", "Spacing and radius"),
        ("controls", "Buttons and controls"),
        ("scores", "Scores"),
        ("status", "Status and context"),
        ("rows", "Rows and lists"),
        ("sleep", "Sleep"),
        ("strain", "Strain"),
        ("trends", "Trends"),
        ("band", "Band"),
        ("empty", "Empty states and sheets"),
    ]

    private static func argument(after flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private var forcedScheme: ColorScheme? {
        switch Self.argument(after: "-freeband-gallery-scheme") {
        case "light": .light
        case "dark": .dark
        default:
            // Info.plist forces dark on the app's windows; the screen still reports the system setting.
            UIScreen.main.traitCollection.userInterfaceStyle == .light ? .light : .dark
        }
    }

    private var locale: Locale {
        Self.argument(after: "-freeband-gallery-locale").map(Locale.init(identifier:)) ?? .current
    }

    var body: some View {
        GalleryContent(initialSection: Self.argument(after: "-freeband-gallery-section"),
                       only: ProcessInfo.processInfo.arguments.contains("-freeband-gallery-only"),
                       initialSheet: Self.argument(after: "-freeband-gallery-sheet"))
            .environment(\.locale, locale)
            .preferredColorScheme(forcedScheme)
    }
}

private struct GalleryContent: View {
    let initialSection: String?
    var only = false
    var initialSheet: String?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Interactive sample state
    @State private var range: TrendRange = .week
    @State private var sleepRange: TrendRange = .month
    @State private var hrRange: TrendRange = .quarter
    @State private var measure = "Smart"
    @State private var highAlert = 120
    @State private var dnd = true
    @State private var smartWake = true
    @State private var sheet: FBSheetKind?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: FBSpace.xl) {
                    if !only { header }
                    section("colours") { ColoursSection(scheme: colorScheme, highContrast: contrast == .increased) }
                    section("type") { TypeSection() }
                    section("layout") { LayoutSection() }
                    section("controls") { controls }
                    section("scores") { scores }
                    section("status") { status }
                    section("rows") { rows }
                    section("sleep") { sleep }
                    section("strain") { strain }
                    section("trends") { trends }
                    section("band") { band }
                    section("empty") { empty }
                }
                .padding(.horizontal, FBSpace.gutter)
                .padding(.vertical, FBSpace.m)
            }
            .background(.canvas)
            .task {
                switch initialSheet {
                case "action": sheet = .action
                case "live": sheet = .live
                case "form": sheet = .form
                default: break
                }
                guard let initialSection, !only else { return }
                try? await Task.sleep(for: .milliseconds(300))
                proxy.scrollTo(initialSection, anchor: .top)
            }
        }
        .sheet(item: $sheet) { kind in SampleSheet(kind: kind) }
    }

    // MARK: chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: FBSpace.xs) {
            Text("Freeband v3")
                .textStyle(.title)
                .foregroundStyle(.textPrimary)
            Text("Tesla language: one focal object, two weights, blue only to commit.")
                .textStyle(.body)
                .foregroundStyle(.textSecondary)
            Text(environmentSummary)
                .textStyle(.caption)
                .foregroundStyle(.textSecondary)
        }
    }

    private var environmentSummary: String {
        [colorScheme == .dark ? "Dark" : "Light",
         String(describing: dynamicTypeSize),
         contrast == .increased ? "Increase Contrast" : nil,
         legibilityWeight == .bold ? "Bold Text" : nil,
         reduceMotion ? "Reduce Motion" : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// Side by side normally, stacked at accessibility sizes.
    private var adaptiveStack: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: FBSpace.xs))
            : AnyLayout(HStackLayout(spacing: FBSpace.xs))
    }

    @ViewBuilder private func section<Content: View>(_ id: String, @ViewBuilder content: () -> Content) -> some View {
        if !only || id == initialSection {
            sectionBody(id, content: content)
        }
    }

    private func sectionBody<Content: View>(_ id: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: FBSpace.s) {
            Text(DesignGallery.sections.first { $0.id == id }?.title ?? id)
                .textStyle(.title)
                .foregroundStyle(.textPrimary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .id(id)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .textStyle(.caption)
            .foregroundStyle(.textSecondary)
    }

    // MARK: sections

    private var controls: some View {
        VStack(alignment: .leading, spacing: FBSpace.m) {
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                label("Primary · the only blue")
                Button("Save") {}.buttonStyle(.fbPrimary)
                Button("Send to band") {}.buttonStyle(.fbPrimary).disabled(true)
            }
            adaptiveStack {
                Button("Choose folder") {}.buttonStyle(.fbSecondary)
                Button("Skip for now") {}.buttonStyle(.fbTertiary)
            }
            FBDestructiveButton(title: "Delete alarm", message: "The band stops ringing at 06:45.") {}
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                label("Segmented picker")
                SegmentedPicker("Range", selection: $range, options: TrendRange.allCases) { $0.title }
                SegmentedPicker("Measure every", selection: $measure,
                                options: ["Off", "Smart", "1 min", "10 min", "30 min"]) { $0 }
            }
            Card {
                SnapSlider("High heart rate alert", stops: [0, 100, 110, 120, 130, 140, 150], selection: $highAlert) {
                    $0 == 0 ? String(localized: "Off") : "\($0)"
                }
            }
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                label("Quick actions · on state inverts, never blue")
                QuickActionRow {
                    QuickActionButton(title: "Sync", systemImage: "arrow.triangle.2.circlepath", isBusy: true) {}
                    QuickActionButton(title: "Live HR", systemImage: "heart") {}
                    QuickActionButton(title: "Find", systemImage: "dot.radiowaves.left.and.right") {}
                    QuickActionButton(title: "Do Not Disturb", systemImage: "moon", isOn: dnd) { dnd.toggle() }
                }
            }
        }
    }

    private var scores: some View {
        VStack(alignment: .leading, spacing: FBSpace.m) {
            VStack(alignment: .leading, spacing: FBSpace.xxs) {
                Text(DayVerdict(recovery: 54).word)
                    .textStyle(.title)
                    .foregroundStyle(.textPrimary)
                Text(DesignSamples.now, format: .dateTime.weekday(.wide).day().month(.wide))
                    .textStyle(.body)
                    .foregroundStyle(.textSecondary)
                StatusLine(name: "Band 10 Pro", battery: 82, state: .nearby,
                           lastSync: .now.addingTimeInterval(-120), showsChevron: true)
            }
            ScoreTriad(sleep: 82, recovery: 54, strain: 11.2)
            label("No data yet")
            ScoreTriad(sleep: nil, recovery: 31, strain: nil)
            label("Detail · figureXL, word in the gap")
            HStack {
                Spacer()
                ScoreArc(kind: .recovery, value: 54, style: .detail)
                Spacer()
            }
            label("Home size with the word in the gap")
            ViewThatFits(in: .horizontal) {
                HStack {
                    ScoreArc(kind: .sleep, value: 91, style: .home, showsWord: true)
                    Spacer()
                    ScoreArc(kind: .strain, value: 18.6, style: .home, showsWord: true)
                    Spacer()
                    ScoreArc(kind: .recovery, value: nil, style: .home, showsWord: true)
                }
                VStack(alignment: .leading, spacing: FBSpace.s) {
                    ScoreArc(kind: .sleep, value: 91, style: .home, showsWord: true)
                    ScoreArc(kind: .strain, value: 18.6, style: .home, showsWord: true)
                    ScoreArc(kind: .recovery, value: nil, style: .home, showsWord: true)
                }
            }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: FBSpace.m) {
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                StatusLine(name: "Band 10 Pro", battery: 82, state: .nearby, lastSync: .now.addingTimeInterval(-120))
                StatusLine(name: "Band 10 Pro", battery: 82, state: .outOfRange, lastSync: .now.addingTimeInterval(-3 * 3600))
                StatusLine(name: "Band 10 Pro", battery: 82, state: .syncing(done: 4, total: 12), lastSync: nil)
                StatusLine(name: "Band 10 Pro", battery: 82, state: .live, lastSync: .now)
                StatusLine(name: "Band 10 Pro", battery: 8, state: .nearby, lastSync: .now.addingTimeInterval(-40 * 60))
                StatusLine(name: "Band 10 Pro", battery: nil, state: .failed("Close Mi Fitness and try again"), lastSync: nil)
                StatusLine(name: "Band 10 Pro", battery: nil, state: .bluetoothOff, lastSync: nil)
            }
            VStack(spacing: FBSpace.xs) {
                ContextCard.live(bpm: 72, endsAt: .now.addingTimeInterval(94)) {}
                ContextCard.charging(battery: 64, minutesToFull: 40)
                ContextCard.finding {}
                ContextCard.alert("Bluetooth is off", actionTitle: "Settings") {}
            }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: FBSpace.m) {
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                SectionHeader(title: "Today")
                VStack(spacing: 0) {
                    MetricRow(title: "Steps", value: "6,412", trend: DesignSamples.week(DesignSamples.steps), delta: .init(.up, "8%"))
                    MetricRow(title: "Resting HR", value: "56", unit: "bpm", trend: DesignSamples.week(DesignSamples.restingHR), delta: .init(.down, "2"))
                    MetricRow(title: "Sleep", value: "7h 12m", trend: DesignSamples.week(DesignSamples.sleepHours), delta: .init(.flat, "0"))
                    MetricRow(title: "Active minutes", value: "42", unit: "min", trend: [30, 28, 51, 44, 35, 39, 42], delta: .init(.up, "12"))
                    MetricRow(title: "Blood oxygen", value: nil, unit: "%")
                }
                .padding(.horizontal, FBSpace.s)
                .fbCardBackground()
                Footnote("Compared with your 7-day average.")
            }
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                SectionHeader(title: "Contributors")
                Card {
                    VStack(spacing: 0) {
                        ContributorRow(name: "Resting heart rate", value: "58 bpm", fraction: 0.62, baseline: 0.52,
                                       note: "3 above usual", flagged: true)
                        ContributorRow(name: "Sleep score", value: "72", fraction: 0.72, baseline: 0.8, note: "8 below usual")
                        ContributorRow(name: "Overnight SpO₂", value: "96%", fraction: 0.96, baseline: 0.96, note: "Usual")
                        ContributorRow(name: "Previous-day strain", value: "14.1", fraction: 14.1 / 21, baseline: 10.8 / 21, note: "High")
                        ContributorRow(name: "Heart rate variability", value: nil, note: "Needs RR data")
                    }
                }
            }
            ListCard {
                ListRow(title: "Alarms", value: "2 on", systemImage: "alarm")
                ListRow(title: "Health monitoring", value: "Smart", systemImage: "heart")
                ListRow(title: "Sleep schedule", value: "23:30–07:00", systemImage: "moon")
                ListRow(title: "Display & Do Not Disturb", systemImage: "rectangle.portrait")
                ListRow(title: "About this band", value: "2.1.7", systemImage: "info.circle", showsDivider: false)
            }
            ListCard {
                ListRow(title: "06:45", subtitle: "Weekdays · Smart wake", accessory: .toggle($smartWake))
                ListRow(title: "08:30", subtitle: "Sat, Sun", accessory: .toggle(.constant(false)), showsDivider: false)
            }
        }
    }

    private var sleep: some View {
        VStack(alignment: .leading, spacing: FBSpace.m) {
            VStack(alignment: .leading, spacing: FBSpace.xxs) {
                Text("Monday night, 13 October")
                    .textStyle(.body)
                    .foregroundStyle(.textSecondary)
                Text("7h 12m")
                    .textStyle(.figureL)
                    .foregroundStyle(.textPrimary)
                Text("23:52 – 07:04 · 94% efficient")
                    .textStyle(.subhead)
                    .foregroundStyle(.textSecondary)
            }
            Card { Hypnogram(segments: DesignSamples.night) }
            label("No stage data")
            Card { Hypnogram(segments: []) }
        }
    }

    private var strain: some View {
        VStack(alignment: .leading, spacing: FBSpace.m) {
            Card {
                VStack(alignment: .leading, spacing: FBSpace.s) {
                    SectionHeader(title: "Heart-rate zones", trailing: "2h 17m")
                    ZoneBar(zones: DesignSamples.zones)
                }
            }
            label("No heart-rate data")
            Card { ZoneBar(zones: DesignSamples.emptyZones, showsLegend: false) }
        }
    }

    private var trends: some View {
        VStack(alignment: .leading, spacing: FBSpace.m) {
            Card { TrendChart(metric: .recovery, points: DesignSamples.days(DesignSamples.recovery), range: $range) }
            Card { TrendChart(metric: .sleepHours, points: DesignSamples.days(DesignSamples.sleepHours), range: $sleepRange) }
            Card { TrendChart(metric: .restingHeartRate, points: DesignSamples.days(DesignSamples.restingHR), range: $hrRange) }
            label("Scrubbing · the selected day replaces the header value")
                .id("trends-scrub")
            Card {
                TrendChart(metric: .sleepScore, points: DesignSamples.days(DesignSamples.sleepScore), range: .constant(.week),
                           selected: Calendar.current.date(byAdding: .day, value: -2, to: Calendar.current.startOfDay(for: DesignSamples.now)))
            }
            label("Trends list cards · static")
            Card {
                TrendChart(metric: .steps, points: DesignSamples.days(DesignSamples.steps), range: .constant(.week),
                           showsRangePicker: false, style: .compact)
            }
            Card {
                TrendChart(metric: .strain, points: DesignSamples.days(DesignSamples.strain), range: .constant(.month),
                           showsRangePicker: false, style: .compact)
            }
            label("No data")
            Card { TrendChart(metric: .stress, points: [], range: .constant(.week), showsRangePicker: false) }
        }
    }

    private var band: some View {
        VStack(alignment: .leading, spacing: FBSpace.m) {
            HStack(alignment: .bottom, spacing: FBSpace.xl) {
                Spacer(minLength: 0)
                BandRender(model: .band10Pro,
                           state: .init(time: DesignSamples.now, battery: 82, charging: true, heartRate: 72), height: 260)
                BandRender(model: .band10, state: .init(time: DesignSamples.now, battery: 41, worn: false), height: 200)
                Spacer(minLength: 0)
            }
            label("Watches and the Band 8")
            HStack(alignment: .bottom, spacing: FBSpace.l) {
                Spacer(minLength: 0)
                BandRender(model: .watchS1Active, state: .init(time: DesignSamples.now, battery: 30, heartRate: 52), height: 200)
                BandRender(model: .redmiWatch5Active, state: .init(time: DesignSamples.now, battery: 39), height: 200)
                BandRender(model: .band8, state: .init(time: DesignSamples.now, battery: 64), height: 200)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: FBSpace.xxs) {
                Text("Band 10 Pro")
                    .textStyle(.headline)
                    .foregroundStyle(.textPrimary)
                Text("82% · Nearby · Synced 2 min ago")
                    .textStyle(.subhead)
                    .foregroundStyle(.textSecondary)
            }
            ContextCard.charging(battery: 82, minutesToFull: 40)
            QuickActionRow {
                QuickActionButton(title: "Sync", systemImage: "arrow.triangle.2.circlepath") {}
                QuickActionButton(title: "Find", systemImage: "dot.radiowaves.left.and.right") {}
                QuickActionButton(title: "Notify", systemImage: "envelope") {}
                QuickActionButton(title: "Do Not Disturb", systemImage: "moon", isOn: false) {}
            }
            label("Light and dark frames, live screen")
            HStack(spacing: FBSpace.l) {
                Spacer(minLength: 0)
                BandRender(model: .band10Pro, state: .init(time: DesignSamples.now, battery: 9), height: 150)
                    .environment(\.colorScheme, .light)
                    .padding(FBSpace.s)
                    .background(Color(hex: FBTokenTable.Colors.canvas.light), in: RoundedRectangle(cornerRadius: FBRadius.card))
                BandRender(model: .band10Pro, state: .init(time: DesignSamples.now, battery: 9), height: 150)
                    .environment(\.colorScheme, .dark)
                    .padding(FBSpace.s)
                    .background(Color(hex: FBTokenTable.Colors.canvas.dark), in: RoundedRectangle(cornerRadius: FBRadius.card))
                Spacer(minLength: 0)
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: FBSpace.m) {
            EmptyState(systemImage: "antenna.radiowaves.left.and.right", title: "Add your band",
                       message: "Freeband reads the band directly. No account, nothing leaves this phone.",
                       actionTitle: "Add band") {}
            EmptyState(systemImage: "moon", title: "No sleep yet",
                       message: "Wear the band tonight. Your first night shows here after the morning sync.")
            EmptyState(systemImage: "chart.line.uptrend.xyaxis", title: "Calibrating · 2 of 3 nights",
                       message: "Recovery needs three nights to learn your usual.")
            label("Sheet anatomy")
            VStack(alignment: .leading, spacing: 0) {
                Capsule().fill(.hairlineStrong).frame(width: 36, height: 5).frame(maxWidth: .infinity).padding(.top, 6)
                SheetHeader(title: "New alarm") {}
                Text("Smart wake wakes you in light sleep, up to 30 minutes early.")
                    .textStyle(.body)
                    .foregroundStyle(.textSecondary)
                    .padding(.horizontal, FBSpace.gutter)
                FBDestructiveButton(title: "Delete alarm") {}
                    .padding(.horizontal, FBSpace.gutter - FBSpace.xs)
                Button("Save") {}
                    .buttonStyle(.fbPrimary)
                    .padding(FBSpace.gutter)
            }
            .background(.raised, in: RoundedRectangle(cornerRadius: FBRadius.card))
            // In a real sheet the dimmed backdrop draws this edge.
            .overlay(RoundedRectangle(cornerRadius: FBRadius.card).stroke(.hairline, lineWidth: FBStroke.hairline))
            adaptiveStack {
                Button("Action sheet") { sheet = .action }.buttonStyle(.fbSecondary)
                Button("Live sheet") { sheet = .live }.buttonStyle(.fbSecondary)
                Button("Form sheet") { sheet = .form }.buttonStyle(.fbSecondary)
            }
        }
    }
}

extension FBSheetKind: Identifiable {
    var id: String { String(describing: self) }
}

private struct SampleSheet: View {
    let kind: FBSheetKind

    var body: some View {
        VStack(alignment: .leading, spacing: FBSpace.s) {
            SheetHeader(title: kind == .live ? "Live heart rate" : kind == .form ? "New alarm" : "Find band")
            if kind == .live {
                VStack(alignment: .leading, spacing: FBSpace.xxs) {
                    Text("72").textStyle(.figureXL).foregroundStyle(.textPrimary)
                    Text("bpm · Live · 1:34 left").textStyle(.subhead).foregroundStyle(.textSecondary)
                }
                .padding(.horizontal, FBSpace.gutter)
            } else {
                Text(kind == .form ? "Alarms live on the band and vibrate without your phone."
                                   : "The band vibrates until you stop it or tap it.")
                    .textStyle(.body)
                    .foregroundStyle(.textSecondary)
                    .padding(.horizontal, FBSpace.gutter)
            }
            Spacer(minLength: 0)
        }
        .fbPinnedPrimary(kind == .form ? "Save" : "Stop", secondary: kind != .form) {}
        .fbSheet(kind)
    }
}

// MARK: token sections

private struct ColoursSection: View {
    let scheme: ColorScheme
    let highContrast: Bool

    private let groups: [(String, [FBTokenTable.ColorEntry])] = {
        typealias T = FBTokenTable.Colors
        return [
            ("Surfaces and text", [T.canvas, T.surface, T.raised, T.hairline, T.hairlineStrong,
                                   T.textPrimary, T.textBody, T.textSecondary, T.textTertiary]),
            ("Action", [T.action, T.actionPressed, T.onAction, T.destructive]),
            ("Score bands and domains", [T.good, T.fair, T.low, T.sleep, T.activity, T.heart]),
            ("Sleep stages", [T.stageAwake, T.stageRem, T.stageLight, T.stageDeep]),
            ("Heart-rate zones", [T.zone1, T.zone2, T.zone3, T.zone4, T.zone5]),
            ("Band render", [T.bandStrap, T.bandBody, T.bandFramePro, T.bandScreen]),
        ]
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: FBSpace.m) {
            ForEach(groups, id: \.0) { title, entries in
                VStack(alignment: .leading, spacing: FBSpace.xs) {
                    Text(title).textStyle(.headline).foregroundStyle(.textPrimary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: FBSpace.xs, alignment: .top), count: 3),
                              alignment: .leading, spacing: FBSpace.s) {
                        ForEach(entries, id: \.name) { swatch($0) }
                    }
                }
            }
            bandWords
        }
    }

    private func hex(_ entry: FBTokenTable.ColorEntry) -> UInt32 {
        switch (scheme == .dark, highContrast) {
        case (false, false): entry.light
        case (false, true): entry.lightContrast
        case (true, false): entry.dark
        case (true, true): entry.darkContrast
        }
    }

    private func swatch(_ entry: FBTokenTable.ColorEntry) -> some View {
        VStack(alignment: .leading, spacing: FBSpace.xxs) {
            RoundedRectangle(cornerRadius: FBRadius.control)
                .fill(Color(uiColor: UIColor(token: entry)))
                .frame(height: 40)
                .overlay(RoundedRectangle(cornerRadius: FBRadius.control).stroke(.hairline, lineWidth: FBStroke.hairline))
            Text(entry.name)
                .textStyle(.caption)
                .foregroundStyle(.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(String(format: "#%06X", hex(entry)))
                .textStyle(.caption)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .foregroundStyle(.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Colour always travels with a word.
    private var bandWords: some View {
        VStack(alignment: .leading, spacing: FBSpace.xs) {
            Text("Bands carry words").textStyle(.headline).foregroundStyle(.textPrimary)
            ForEach([(ScoreKind.recovery, [80.0, 50, 20]), (.sleep, [86, 70, 41]), (.strain, [6.2, 11.2, 15.8, 19.4])], id: \.0) { kind, values in
                VStack(alignment: .leading, spacing: FBSpace.xxs) {
                    Text(kind.name)
                        .textStyle(.body)
                        .foregroundStyle(.textPrimary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: FBSpace.s, alignment: .leading)],
                              alignment: .leading, spacing: FBSpace.xxs) {
                        ForEach(values, id: \.self) { value in
                            let band = kind.band(for: value)
                            HStack(spacing: FBSpace.xxs) {
                                Rectangle().fill(band.color).frame(width: 8, height: 8)
                                Text("\(kind.format(value)) \(band.word)")
                                    .textStyle(.subhead)
                                    .foregroundStyle(.textSecondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct TypeSection: View {
    private func sample(_ style: FBTextStyle) -> String {
        switch style {
        case .figureXL: "54"
        case .figureL: "7h 12m"
        case .title: "Ready"
        case .figureM: "06:45"
        case .headline: "Contributors"
        case .body: "Lower than usual: resting heart rate is up and sleep was short."
        case .button: "Send to band"
        case .figureS: "6,412"
        case .subhead: "Band 10 Pro · 82% · Synced 2 min ago"
        case .caption: "Mon  Tue  Wed · İğdır ışık"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FBSpace.s) {
            ForEach(FBTextStyle.allCases) { style in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(style.rawValue) · \(Int(style.size))/\(Int(style.lineHeight)) · \(style.weight)")
                        .textStyle(.caption)
                        .foregroundStyle(.textSecondary)
                    Text(sample(style))
                        .textStyle(style)
                        .foregroundStyle(.textPrimary)
                }
            }
        }
    }
}

private struct LayoutSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: FBSpace.m) {
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                ForEach(FBTokenTable.Space.all.filter { ["xxs", "xs", "s", "m", "l", "xl"].contains($0.name) }, id: \.name) { item in
                    HStack(spacing: FBSpace.s) {
                        Text("\(item.name) · \(Int(item.value))")
                            .textStyle(.caption)
                            .foregroundStyle(.textSecondary)
                            .frame(width: 64, alignment: .leading)
                        Rectangle().fill(.textPrimary).frame(width: item.value, height: 8)
                    }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: FBSpace.s, alignment: .leading)], alignment: .leading,
                      spacing: FBSpace.s) {
                ForEach([("chart 0", FBRadius.chart), ("control 4", FBRadius.control), ("card 12", FBRadius.card)], id: \.0) { name, radius in
                    VStack(spacing: FBSpace.xxs) {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(.surface)
                            .frame(width: 72, height: 48)
                        Text(name).textStyle(.caption).foregroundStyle(.textSecondary)
                    }
                }
            }
        }
    }
}
#endif
