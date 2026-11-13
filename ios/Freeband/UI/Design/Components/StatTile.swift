import SwiftUI

/// One number on Home's grid: what it is, the value large, how it moved against the 7-day
/// average, and the last days as a line in the metric's colour. VoiceOver reads it as one
/// element. `wide` lays it out in a row with a longer line, for the tile that spans the grid.
struct StatTile: View {
    let title: String
    var value: String?
    var unit: String?
    var trend: [Double?] = []
    var delta: MetricDelta?
    var color: Color = .textSecondary
    var wide = false

    var body: some View {
        Card {
            if wide {
                HStack(alignment: .center, spacing: FBSpace.s) {
                    VStack(alignment: .leading, spacing: FBSpace.xxs) { label; figure; change }
                    Spacer(minLength: 0)
                    Sparkline(values: trend, color: color).frame(width: 132, height: 44)
                }
            } else {
                VStack(alignment: .leading, spacing: FBSpace.xxs) {
                    label
                    figure
                    HStack(alignment: .center, spacing: FBSpace.xs) {
                        change
                        Spacer(minLength: 0)
                        Sparkline(values: trend, color: color).frame(width: 56, height: 22)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue([value.map { [$0, unit].compactMap { $0 }.joined(separator: " ") }, delta?.spoken].compactMap { $0 }.joined(separator: ", "))
    }

    private var label: some View {
        Text(title)
            .textStyle(.subhead)
            .foregroundStyle(.textSecondary)
            .lineLimit(1)
    }

    private var figure: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value ?? "–")
                .textStyle(.figureM)
                .foregroundStyle(value == nil ? Color.textTertiary : Color.textPrimary)
            if let unit, value != nil {
                Text(unit)
                    .textStyle(.caption)
                    .foregroundStyle(.textSecondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    @ViewBuilder private var change: some View {
        if let delta, value != nil {
            Text("\(Image(systemName: delta.symbol)) \(delta.text)")
                .textStyle(.caption)
                .imageScale(.small)
                .monospacedDigit()
                .foregroundStyle(.textSecondary)
                .lineLimit(1)
        } else {
            // Keeps the tile's height when there is nothing to compare with yet.
            Text(verbatim: " ").textStyle(.caption)
        }
    }
}
