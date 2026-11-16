import SwiftUI

/// A 270° arc open at the bottom: starts at 135° (lower left) and sweeps clockwise to 45°.
/// The same shape is the app icon.
struct ArcShape: InsettableShape {
    var insetAmount: CGFloat = 0

    static let startAngle = Angle.degrees(135)
    static let sweep = 270.0

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2 - insetAmount
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: max(0, radius),
                    startAngle: Self.startAngle, endAngle: .degrees(Self.startAngle.degrees + Self.sweep), clockwise: false)
        return path
    }

    func inset(by amount: CGFloat) -> ArcShape {
        var arc = self
        arc.insetAmount += amount
        return arc
    }

    /// The point on the arc's centre line at `fraction` (0...1) of the sweep.
    static func point(at fraction: Double, in rect: CGRect, inset: CGFloat = 0) -> CGPoint {
        let radius = min(rect.width, rect.height) / 2 - inset
        let angle = (startAngle.degrees + sweep * fraction) * .pi / 180
        return CGPoint(x: rect.midX + radius * cos(angle), y: rect.midY + radius * sin(angle))
    }
}

/// A score as an open gauge: 1pt track with notches at the band thresholds, the value arc in
/// its band colour (Strain: activity), the number inside and the band word in the gap.
/// No value draws the track only, with "–".
struct ScoreArc: View {
    enum Style {
        /// 104pt, 3pt stroke, figureM: the Home triad.
        case home
        /// 200pt, 4pt stroke, figureXL with the word in the gap: score detail.
        case detail
        /// 64pt, 6pt stroke, figureS: the Sleep and Strain cards on Home.
        case compact
        /// 148pt, 12pt stroke, figureL: the Recovery card on Home.
        case hero
    }

    let kind: ScoreKind
    let value: Double?
    var style: Style = .home
    /// Shows the band word in the gap. Defaults to on for `.detail`.
    var showsWord: Bool?

    @ScaledMetric(relativeTo: .title2) private var homeDiameter: CGFloat = 104
    @ScaledMetric(relativeTo: .largeTitle) private var detailDiameter: CGFloat = 200
    @ScaledMetric(relativeTo: .body) private var compactDiameter: CGFloat = FBSize.scoreArcCompact
    @ScaledMetric(relativeTo: .title2) private var heroDiameter: CGFloat = 148
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @Environment(\.legibilityWeight) private var legibilityWeight
    @State private var revealed = false

    private var diameter: CGFloat {
        // Scales with Dynamic Type, capped so three still fit a phone; at XXL and up Home
        // switches the triad to rows of compact arcs anyway.
        switch style {
        case .home: min(homeDiameter, 150)
        case .detail: min(detailDiameter, 280)
        case .compact: min(compactDiameter, 88)
        case .hero: min(heroDiameter, 180)
        }
    }

    private var stroke: CGFloat {
        switch style {
        case .home: FBStroke.arcHome
        case .detail: FBStroke.arcDetail
        case .compact: 6
        case .hero: 12
        }
    }

    private var fraction: Double? {
        guard let value else { return nil }
        return min(max(value / kind.maximum, 0), 1)
    }

    private var band: ScoreBand? { value.map(kind.band(for:)) }

    private var wordVisible: Bool { showsWord ?? (style == .detail) }

    var body: some View {
        ZStack {
            // The ring: a track in the score's own colour, the value over it with round ends,
            // and the band thresholds cut out of both.
            ZStack {
                ArcShape()
                    .inset(by: stroke / 2)
                    .stroke(band.map { $0.color.opacity(0.2) } ?? Color.hairlineStrong, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                if let fraction, let band, fraction > 0 {
                    ArcShape()
                        .inset(by: stroke / 2)
                        .trim(from: 0, to: revealed ? fraction : 0)
                        .stroke(band.color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                }
                notches.blendMode(.destinationOut)
            }
            .compositingGroup()
            number
            if wordVisible { gapWord }
        }
        .frame(width: diameter, height: diameter)
        .onAppear { FBMotion.reveal(reduceMotion: reduceMotion) { revealed = true } }
        .animation(FBMotion.arcReveal(reduceMotion: reduceMotion), value: fraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.name)
        .accessibilityValue(Self.accessibilityValue(kind: kind, value: value, locale: locale))
    }

    private var notches: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let half = stroke / 2 + 2
            for threshold in kind.thresholds {
                let f = threshold / kind.maximum
                let angle = (ArcShape.startAngle.degrees + ArcShape.sweep * f) * .pi / 180
                let r = min(size.width, size.height) / 2 - stroke / 2
                let c = CGPoint(x: rect.midX, y: rect.midY)
                var tick = Path()
                tick.move(to: CGPoint(x: c.x + (r - half) * cos(angle), y: c.y + (r - half) * sin(angle)))
                tick.addLine(to: CGPoint(x: c.x + (r + half) * cos(angle), y: c.y + (r + half) * sin(angle)))
                context.stroke(tick, with: .color(.black), style: StrokeStyle(lineWidth: FBStroke.notch, lineCap: .butt))
            }
        }
        .accessibilityHidden(true)
    }

    private var numberStyle: FBTextStyle {
        switch style {
        case .home: .figureM
        case .detail: .figureXL
        case .compact: .figureS
        case .hero: .figureL
        }
    }

    private var number: some View {
        let text = Text(value.map { kind.format($0, locale: locale) } ?? "–")
        return Group {
            if style == .compact {
                // The compact arc sits beside its scaled name and word; its number follows the arc.
                text.font(FBTextStyle.figureS.fixedFont(size: diameter * 0.28, bold: legibilityWeight == .bold))
            } else {
                text.textStyle(numberStyle)
            }
        }
        .foregroundStyle(value == nil ? Color.textTertiary : Color.textPrimary)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .padding(.horizontal, stroke + FBSpace.xs)
        .fbNumericTransition(value ?? 0)
    }

    private var gapWord: some View {
        Text(band?.word ?? String(localized: "No data"))
            .textStyle(style == .detail ? .headline : .caption)
            .foregroundStyle(value == nil ? Color.textTertiary : Color.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: diameter * 0.6)
            .offset(y: diameter * 0.39)
    }

    /// "54 of 100, Fair" / "No data".
    static func accessibilityValue(kind: ScoreKind, value: Double?, locale: Locale = .current) -> String {
        guard let value else { return String(localized: "No data") }
        let number = kind.format(value, locale: locale)
        let maximum = kind.maximum.formatted(.number.precision(.fractionLength(0)).locale(locale))
        return String(localized: "\(number) of \(maximum), \(kind.band(for: value).word)",
                      comment: "Score accessibility value, e.g. 54 of 100, Fair")
    }
}

/// One score on Home: the arc, its name and its band word. At XXL and larger the triad switches
/// to rows (64pt arc on the left, name and word on the right).
struct ScoreTile: View {
    let kind: ScoreKind
    let value: Double?
    var layout: Layout = .column

    enum Layout { case column, row }

    @Environment(\.locale) private var locale

    var body: some View {
        Group {
            switch layout {
            case .column:
                VStack(spacing: FBSpace.xs) {
                    ScoreArc(kind: kind, value: value, style: .home)
                    labels(alignment: .center)
                }
            case .row:
                HStack(spacing: FBSpace.s) {
                    ScoreArc(kind: kind, value: value, style: .compact)
                    labels(alignment: .leading)
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.name)
        .accessibilityValue(ScoreArc.accessibilityValue(kind: kind, value: value, locale: locale))
    }

    private func labels(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(kind.name)
                .textStyle(.body)
                .foregroundStyle(.textPrimary)
            Text(value.map { kind.band(for: $0).word } ?? String(localized: "No data"))
                .textStyle(.subhead)
                .foregroundStyle(value == nil ? Color.textTertiary : Color.textSecondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .multilineTextAlignment(alignment == .center ? .center : .leading)
    }
}

/// The Home focal object: Sleep, Recovery and Strain side by side; rows at XXL and up.
struct ScoreTriad: View {
    let sleep: Double?
    let recovery: Double?
    let strain: Double?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize >= .xxLarge {
            VStack(alignment: .leading, spacing: FBSpace.s) {
                ScoreTile(kind: .sleep, value: sleep, layout: .row)
                ScoreTile(kind: .recovery, value: recovery, layout: .row)
                ScoreTile(kind: .strain, value: strain, layout: .row)
            }
        } else {
            HStack(alignment: .top, spacing: 0) {
                ScoreTile(kind: .sleep, value: sleep).frame(maxWidth: .infinity)
                ScoreTile(kind: .recovery, value: recovery).frame(maxWidth: .infinity)
                ScoreTile(kind: .strain, value: strain).frame(maxWidth: .infinity)
            }
        }
    }
}

#Preview("ScoreArc") {
    FBPreviewMatrix {
        ScoreTriad(sleep: 82, recovery: 54, strain: 11.2)
        ScoreTriad(sleep: nil, recovery: nil, strain: nil)
        HStack {
            Spacer()
            ScoreArc(kind: .recovery, value: 54, style: .detail)
            Spacer()
        }
    }
}
