import SwiftUI

/// The one container: surface tone, radius 20, 16pt padding, and a hairline edge that keeps the
/// card's shape on the dark canvas. No shadow.
struct Card<Content: View>: View {
    var padding: CGFloat = FBSpace.cardPadding
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .fbCardBackground()
    }
}

extension View {
    /// Wraps a view in the card surface without padding (list cards, charts that bleed).
    func fbCardBackground() -> some View {
        background(.surface, in: RoundedRectangle(cornerRadius: FBRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: FBRadius.card, style: .continuous).strokeBorder(.hairline, lineWidth: FBStroke.hairline))
    }
}

/// Section title above a card ("Today", "Contributors"), with an optional trailing note.
struct SectionHeader: View {
    let title: String
    var trailing: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        layout {
            Text(title)
                .textStyle(.headline)
                .foregroundStyle(.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let trailing {
                Text(trailing)
                    .textStyle(.subhead)
                    .foregroundStyle(.textSecondary)
            }
        }
    }
}

/// Footnote under a card ("Compared with your 7-day average.").
struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .textStyle(.subhead)
            .foregroundStyle(.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Preview helper: the same content in light and dark, at default and AX3 text sizes.
struct FBPreviewMatrix<Content: View>: View {
    @ViewBuilder var content: Content

    private let variants: [(String, ColorScheme, DynamicTypeSize)] = [
        ("Light · default", .light, .large),
        ("Dark · default", .dark, .large),
        ("Light · AX3", .light, .accessibility3),
        ("Dark · AX3", .dark, .accessibility3),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(variants, id: \.0) { name, scheme, size in
                    VStack(alignment: .leading, spacing: FBSpace.xs) {
                        Text(name).textStyle(.caption).foregroundStyle(.textSecondary)
                        content
                    }
                    .padding(FBSpace.gutter)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.canvas)
                    .environment(\.colorScheme, scheme)
                    .environment(\.dynamicTypeSize, size)
                }
            }
        }
    }
}

#Preview("Card") {
    FBPreviewMatrix {
        SectionHeader(title: "Today", trailing: "Tue 14 Oct")
        Card {
            Text("Cards hold rows, charts and context. Nothing sits on the canvas without one.")
                .textStyle(.body)
                .foregroundStyle(.textBody)
        }
        Footnote("Compared with your 7-day average.")
    }
}
