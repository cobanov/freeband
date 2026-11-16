import SwiftUI
import UIKit

/// The v3 type scale: Open Sauce Sans in two weights (400, 500), sentence case, tracking 0.
/// Sizes scale with Dynamic Type relative to a system text style; line height comes from
/// `.lineSpacing`; figures use tabular digits. Bold Text maps 400 → 500 and 500 → 600.
enum FBTextStyle: String, CaseIterable, Identifiable, Sendable {
    /// 56/56 · 500 · detail arc, live HR
    case figureXL
    /// 40/44 · 500 · sleep duration, battery
    case figureL
    /// 28/34 · 500 · screen titles, day verdict
    case title
    /// 28/32 · 500 · Home arcs, alarm times
    case figureM
    /// 17/22 · 500 · section and sheet titles, band name
    case headline
    /// 16/23 · 400 · paragraphs, row titles
    case body
    /// 15/20 · 500 · buttons, segments
    case button
    /// 16/20 · 500 · row values
    case figureS
    /// 14/20 · 400 · status line, footers
    case subhead
    /// 12/16 · 400 · axes, units, quick-action labels
    case caption

    var id: String { rawValue }

    var token: FBTokenTable.TypeEntry {
        typealias T = FBTokenTable.TypeScale
        switch self {
        case .figureXL: return T.figureXL
        case .figureL: return T.figureL
        case .title: return T.title
        case .figureM: return T.figureM
        case .headline: return T.headline
        case .body: return T.body
        case .button: return T.button
        case .figureS: return T.figureS
        case .subhead: return T.subhead
        case .caption: return T.caption
        }
    }

    var size: CGFloat { token.size }
    var lineHeight: CGFloat { token.lineHeight }
    var weight: Int { token.weight }
    var isFigure: Bool { token.isFigure }
    var relativeTo: Font.TextStyle { token.relativeTo }

    /// PostScript name for this style's weight; `bold` is the Bold Text accessibility setting.
    func fontName(bold: Bool = false) -> String {
        // 600 (figures and titles since v4) is already the heaviest cut bundled.
        if weight >= 600 { return FBTokenTable.FontName.semibold }
        switch (weight >= 500, bold) {
        case (false, false): return FBTokenTable.FontName.regular
        case (false, true): return FBTokenTable.FontName.medium
        case (true, false): return FBTokenTable.FontName.medium
        case (true, true): return FBTokenTable.FontName.semibold
        }
    }

    /// The SwiftUI font. Prefer `.textStyle(_:)`, which also sets line height and reads Bold Text.
    func font(bold: Bool = false) -> Font {
        let font = Font.custom(fontName(bold: bold), size: size, relativeTo: relativeTo)
        return isFigure ? font.monospacedDigit() : font
    }

    /// A font that ignores Dynamic Type, for illustrations drawn to scale (BandRender's screen).
    func fixedFont(size: CGFloat, bold: Bool = false) -> Font {
        let font = Font.custom(fontName(bold: bold), fixedSize: size)
        return isFigure ? font.monospacedDigit() : font
    }

    var uiTextStyle: UIFont.TextStyle {
        switch relativeTo {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }

    /// A UIKit font scaled for the given traits (navigation bars, attributed strings).
    func uiFont(bold: Bool = false, compatibleWith traits: UITraitCollection? = nil) -> UIFont {
        let base = UIFont(name: fontName(bold: bold), size: size) ?? .systemFont(ofSize: size, weight: weight >= 500 ? .medium : .regular)
        return UIFontMetrics(forTextStyle: uiTextStyle).scaledFont(for: base, compatibleWith: traits)
    }

    /// Extra space between lines so wrapped text sits on the token's line height.
    func lineSpacing(for dynamicTypeSize: DynamicTypeSize, bold: Bool) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        let metrics = UIFontMetrics(forTextStyle: uiTextStyle)
        let scaledLine = metrics.scaledValue(for: lineHeight, compatibleWith: traits)
        let font = uiFont(bold: bold, compatibleWith: traits)
        return max(0, scaledLine - font.lineHeight)
    }
}

private struct FBTextStyleModifier: ViewModifier {
    let style: FBTextStyle
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        let bold = legibilityWeight == .bold
        content
            .font(style.font(bold: bold))
            .lineSpacing(style.lineSpacing(for: dynamicTypeSize, bold: bold))
    }
}

extension View {
    /// Applies a v3 text style: font, Dynamic Type, line height, tabular figures and Bold Text.
    func textStyle(_ style: FBTextStyle) -> some View {
        modifier(FBTextStyleModifier(style: style))
    }
}

extension Font {
    /// The v3 font for a style, for places that only take a `Font` (chart axes, `Text` concatenation).
    static func fb(_ style: FBTextStyle, bold: Bool = false) -> Font { style.font(bold: bold) }
}

enum FBAppearance {
    /// Navigation bar titles in Open Sauce 500 (headline and title tokens), scaled with
    /// `UIFontMetrics`. Leaves bar backgrounds to the system (Liquid Glass on iOS 26).
    /// Call once at launch when the v3 screens land.
    @MainActor static func configureNavigationBars() {
        let bar = UINavigationBar.appearance()
        bar.titleTextAttributes = [.font: FBTextStyle.headline.uiFont(), .foregroundColor: FBUIColor.textPrimary]
        bar.largeTitleTextAttributes = [.font: FBTextStyle.title.uiFont(), .foregroundColor: FBUIColor.textPrimary]
    }
}

extension Int {
    /// A whole-number percentage in the locale's own form: "82%" in English, "%82" in Turkish.
    func percentText(locale: Locale = .current) -> String {
        (Double(self) / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }
}
