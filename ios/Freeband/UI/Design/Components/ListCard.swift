import SwiftUI

/// A card of rows (Band controls, Settings): surface, radius 12, rows edge to edge with
/// hairlines inset to the text.
struct ListCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity)
            .fbCardBackground()
            .clipShape(RoundedRectangle(cornerRadius: FBRadius.card, style: .continuous))
    }
}

/// A 52pt row: optional 20pt icon, title (and subtitle), trailing value, then a chevron or a
/// toggle. Wrap it in `NavigationLink(value:)` with `.buttonStyle(.fbRow)` for the pressed tone.
struct ListRow: View {
    enum Accessory {
        case chevron
        case none
        /// On-state toggles are the one other place action blue appears.
        case toggle(Binding<Bool>)
    }

    let title: String
    var subtitle: String?
    var value: String?
    var systemImage: String?
    var accessory: Accessory = .chevron
    /// Hairline under the row; turn off for the last row.
    var showsDivider = true

    @ScaledMetric(relativeTo: .body) private var scaledIcon: CGFloat = FBSize.rowIcon
    private var iconSize: CGFloat { min(scaledIcon, 32) }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if case .toggle(let isOn) = accessory {
                Toggle(isOn: isOn) { labels }
                    .tint(.good)
            } else {
                HStack(spacing: FBSpace.s) {
                    labels
                    if case .chevron = accessory {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.textTertiary)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, FBSpace.s)
        .padding(.vertical, FBSpace.xs)
        .frame(minHeight: FBSize.row)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle()
                    .fill(.hairline)
                    .frame(height: FBStroke.hairline)
                    .padding(.leading, FBSpace.s + (systemImage == nil ? 0 : iconSize + FBSpace.s))
            }
        }
    }

    private var labels: some View {
        HStack(spacing: FBSpace.s) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(.textPrimary)
                    .frame(width: iconSize, height: iconSize)
                    .accessibilityHidden(true)
            }
            let stacked = dynamicTypeSize.isAccessibilitySize
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .textStyle(.body)
                    .foregroundStyle(.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .textStyle(.subhead)
                        .foregroundStyle(.textSecondary)
                }
                if stacked, let value {
                    Text(value)
                        .textStyle(.subhead)
                        .foregroundStyle(.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !stacked, let value {
                Text(value)
                    .textStyle(.body)
                    .foregroundStyle(.textSecondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Pressed rows take the raised tone; nothing moves.
struct FBRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.raised : Color.clear)
            .fbStateAnimation(configuration.isPressed)
    }
}

extension ButtonStyle where Self == FBRowButtonStyle {
    static var fbRow: FBRowButtonStyle { FBRowButtonStyle() }
}

extension View {
    /// Themed `Form` for system-control settings pages: canvas behind, surface rows.
    func fbFormStyle() -> some View {
        scrollContentBackground(.hidden)
            .background(.canvas)
            .tint(.good)
    }

    /// Surface background for a row inside a themed `Form`.
    func fbFormRow() -> some View {
        listRowBackground(Color.surface)
    }
}

#Preview("ListCard") {
    FBPreviewMatrix {
        ListCard {
            ListRow(title: "Alarms", value: "2 on", systemImage: "alarm")
            ListRow(title: "Health monitoring", value: "Smart", systemImage: "heart")
            ListRow(title: "Smart wake", subtitle: "Wakes you in light sleep.", accessory: .toggle(.constant(true)))
            ListRow(title: "About this band", value: "2.1.7", systemImage: "info.circle", showsDivider: false)
        }
    }
}
