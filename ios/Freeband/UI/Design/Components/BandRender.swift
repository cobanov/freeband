import SwiftUI

/// The band as Tesla draws the car: a flat vector object, no gradients, no shadows. A pill
/// body with strap stubs; the 10 Pro has a lighter metal frame; the Redmi Watch 5 Active
/// is a rounded rectangle. A live overlay on the screen shows the time, battery (with a bolt
/// while charging), live heart rate or "Not worn".
/// The screen is AMOLED black in both themes; the strap and frame follow the theme.
struct BandRender: View {
    enum Model: String, CaseIterable, Identifiable, Sendable {
        case band10, band10Pro, redmiWatch5Active

        var id: String { rawValue }

        var name: String {
            switch self {
            case .band10: "Band 10"
            case .band10Pro: "Band 10 Pro"
            case .redmiWatch5Active: "Redmi Watch 5 Active"
            }
        }
    }

    struct LiveState: Equatable, Sendable {
        var time: Date
        var battery: Int?
        var charging = false
        /// Live heart rate while a live session runs.
        var heartRate: Int?
        var worn = true
    }

    let model: Model
    var state: LiveState
    /// Overall height; the width follows the band's proportions.
    var height: CGFloat = 240

    @Environment(\.locale) private var locale

    // Proportions in body widths (Smart Band 10: about 22.6 × 48.3 mm; Redmi Watch 5 Active:
    // about 38.3 × 45.6 mm).
    private var bodyAspect: CGFloat { model == .redmiWatch5Active ? 1.19 : 2.14 }
    private var stub: CGFloat { model == .redmiWatch5Active ? 0.5 : 0.62 }

    private var w: CGFloat { height / (bodyAspect + 2 * stub) }
    private var bodyHeight: CGFloat { w * bodyAspect }
    private var stubLength: CGFloat { w * stub }
    /// Corner radius of a part inset by `inset`: a capsule on the bands, rounded corners on the watch.
    private func radius(_ inset: CGFloat) -> CGFloat {
        model == .redmiWatch5Active ? max(w * 0.22 - inset, 0) : (w - 2 * inset) / 2
    }
    /// Circular corners at half the width make the bands' capsule; the watch's corners are continuous.
    private var cornerStyle: RoundedCornerStyle { model == .redmiWatch5Active ? .continuous : .circular }
    /// Frame ring around the glass: thicker, metal, on the Pro.
    private var frame: CGFloat { w * (model == .band10Pro ? 0.085 : 0.06) }

    var body: some View {
        ZStack(alignment: .top) {
            straps
            RoundedRectangle(cornerRadius: radius(0), style: cornerStyle)
                .fill(Color(uiColor: model == .band10Pro ? FBUIColor.bandFramePro : FBUIColor.bandBody))
                .frame(width: w, height: bodyHeight)
                .offset(y: stubLength)
            if model == .band10Pro {
                // A dark lip between the metal and the glass, so the frame reads as a separate part.
                Capsule()
                    .fill(Color(uiColor: FBUIColor.bandBody))
                    .frame(width: w - 2 * frame, height: bodyHeight - 2 * frame)
                    .offset(y: stubLength + frame)
            }
            RoundedRectangle(cornerRadius: radius(frame + lip), style: cornerStyle)
                .fill(Color(uiColor: FBUIColor.bandScreen))
                .frame(width: w - 2 * frame - lip * 2, height: bodyHeight - 2 * frame - lip * 2)
                .offset(y: stubLength + frame + lip)
            screen
                .frame(width: w * 0.72, height: bodyHeight * 0.76)
                .offset(y: stubLength + bodyHeight * 0.12)
        }
        .frame(width: w, height: height, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.name)
        .accessibilityValue(accessibilityValue)
        .accessibilityIgnoresInvertColors()
    }

    private var lip: CGFloat { model == .band10Pro ? w * 0.025 : 0 }

    private var straps: some View {
        let strap = Color(uiColor: FBUIColor.bandStrap)
        let width = w * (model == .redmiWatch5Active ? 0.6 : 0.8)
        let overlap = w * 0.5
        let radius = w * 0.16
        return ZStack(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius)
                .fill(strap)
                .frame(width: width, height: stubLength + overlap)
            UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius)
                .fill(strap)
                .frame(width: width, height: stubLength + overlap)
                .offset(y: height - stubLength - overlap)
        }
    }

    // MARK: screen

    private var screen: some View {
        // Hour stacks over minute, so the height bounds the type on the wide watch screen; on the
        // narrow band the width does.
        let s = model == .redmiWatch5Active ? bodyHeight * 0.45 : w * 0.72
        let text = Color(uiColor: FBUIColor.bandScreenText)
        let dim = Color(uiColor: FBUIColor.bandScreenDim)
        return VStack(spacing: 0) {
            if let battery = state.battery {
                HStack(spacing: s * 0.03) {
                    Image(systemName: state.charging ? "bolt.fill" : batterySymbol(battery))
                        .font(.system(size: s * 0.11, weight: .medium))
                        .foregroundStyle(state.charging ? Color(hex: FBTokenTable.Colors.good.dark) : dim)
                    Text(verbatim: battery.percentText(locale: locale))
                        .font(FBTextStyle.figureS.fixedFont(size: s * 0.13))
                        .foregroundStyle(dim)
                }
                .padding(.top, s * 0.06)
            }
            Spacer(minLength: 0)
            VStack(spacing: -s * 0.07) {
                Text(state.time.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).locale(locale)))
                Text(state.time.formatted(.dateTime.minute(.twoDigits).locale(locale)))
            }
            .font(FBTextStyle.figureXL.fixedFont(size: s * 0.46))
            .foregroundStyle(state.worn ? text : dim)
            Text(state.time.formatted(.dateTime.weekday(.abbreviated).day().locale(locale)))
                .font(FBTextStyle.caption.fixedFont(size: s * 0.12))
                .foregroundStyle(dim)
                .padding(.top, s * 0.04)
            Spacer(minLength: 0)
            Group {
                if let bpm = state.heartRate, state.worn {
                    HStack(spacing: s * 0.04) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: s * 0.12))
                            .foregroundStyle(Color(hex: FBTokenTable.Colors.heart.dark))
                        Text("\(bpm)")
                            .font(FBTextStyle.figureS.fixedFont(size: s * 0.17))
                            .foregroundStyle(text)
                    }
                } else if !state.worn {
                    Text("Not worn")
                        .font(FBTextStyle.caption.fixedFont(size: s * 0.12))
                        .foregroundStyle(dim)
                } else {
                    Color.clear
                }
            }
            .frame(height: s * 0.2)
            .padding(.bottom, s * 0.06)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }

    private func batterySymbol(_ battery: Int) -> String {
        switch battery {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }

    private var accessibilityValue: String {
        var parts = [state.time.formatted(.dateTime.hour().minute().locale(locale))]
        if let battery = state.battery { parts.append(String(localized: "\(battery)% battery")) }
        if state.charging { parts.append(String(localized: "Charging")) }
        if !state.worn {
            parts.append(String(localized: "Not worn"))
        } else if let bpm = state.heartRate {
            parts.append(String(localized: "Live heart rate \(bpm) bpm"))
        }
        return parts.joined(separator: ", ")
    }
}

/// The band's outline (body and strap stubs) as one shape, for icons and masks.
struct BandSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.height / (2.14 + 1.24)
        let x = rect.midX - w / 2
        var path = Path()
        let strap = w * 0.8
        path.addRoundedRect(in: CGRect(x: rect.midX - strap / 2, y: rect.minY, width: strap, height: rect.height),
                            cornerSize: CGSize(width: w * 0.16, height: w * 0.16))
        path.addRoundedRect(in: CGRect(x: x, y: rect.minY + w * 0.62, width: w, height: w * 2.14),
                            cornerSize: CGSize(width: w / 2, height: w / 2))
        return path
    }
}

#Preview("BandRender") {
    FBPreviewMatrix {
        HStack(spacing: FBSpace.xl) {
            BandRender(model: .band10Pro, state: .init(time: .now, battery: 82, charging: true, heartRate: 72))
            BandRender(model: .band10, state: .init(time: .now, battery: 41, worn: false))
            BandRender(model: .redmiWatch5Active, state: .init(time: .now, battery: 39, heartRate: 64))
        }
        .frame(maxWidth: .infinity)
    }
}
