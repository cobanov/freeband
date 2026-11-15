import SwiftUI

/// What stands out on the day against the person's own normal (Analytics/Insights.swift): at
/// most three rows, warnings first, each opening the trend it is about. Nothing when the day is
/// ordinary. The icon's shape carries the tone; colour only repeats it.
struct InsightList: View {
    let insights: [Insight]
    let day: DayKey

    var body: some View {
        if !insights.isEmpty {
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                SectionHeader(title: String(localized: "Worth noticing"))
                VStack(spacing: FBSpace.xs) {
                    ForEach(Array(insights.prefix(3).enumerated()), id: \.offset) { _, insight in
                        NavigationLink(value: Route.trend(insight.metric, day: day.index)) {
                            Card {
                                HStack(alignment: .firstTextBaseline, spacing: FBSpace.s) {
                                    Image(systemName: insight.symbol)
                                        .foregroundStyle(insight.color)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: FBSpace.xxs) {
                                        Text(insight.title)
                                            .textStyle(.headline)
                                            .foregroundStyle(.textPrimary)
                                        Text(insight.detail)
                                            .textStyle(.subhead)
                                            .foregroundStyle(.textSecondary)
                                    }
                                    .fixedSize(horizontal: false, vertical: true)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

extension Insight {
    var metric: TrendMetric {
        switch kind {
        case .restingHRHigh, .restingHRLowest, .hrvLow: .restingHeartRate
        case .sleepDebt, .sleepShifted: .sleepHours
        case .loadWithoutRecovery: .recovery
        }
    }

    var symbol: String {
        switch tone {
        case .warning: "exclamationmark.triangle"
        case .notice: "info.circle"
        case .good: "checkmark.circle"
        }
    }

    var color: Color {
        switch tone {
        case .warning: .low
        case .notice: .fair
        case .good: .good
        }
    }

    var title: String {
        switch kind {
        case .restingHRHigh: String(localized: "Resting heart rate is high")
        case .restingHRLowest: String(localized: "Lowest resting heart rate in two weeks")
        case .hrvLow: String(localized: "HRV is low")
        case .sleepDebt: String(localized: "You're short on sleep")
        case .sleepShifted: value > 0 ? String(localized: "You slept later than usual") : String(localized: "You slept earlier than usual")
        case .loadWithoutRecovery: String(localized: "Hard days, low recovery")
        }
    }

    var detail: String {
        let normal = reference ?? 0
        switch kind {
        case .restingHRHigh where days > 1:
            return String(localized: "\(FBFormat.bpm(value)), your normal is \(FBFormat.bpm(normal)). \(days) days in a row.")
        case .restingHRHigh, .restingHRLowest:
            return String(localized: "\(FBFormat.bpm(value)), your normal is \(FBFormat.bpm(normal)).")
        case .hrvLow where days > 1:
            return String(localized: "\(Int(value.rounded())) ms, your normal is \(Int(normal.rounded())) ms. \(days) nights in a row.")
        case .hrvLow:
            return String(localized: "\(Int(value.rounded())) ms, your normal is \(Int(normal.rounded())) ms.")
        case .sleepDebt:
            return String(localized: "\(FBFormat.duration(minutes: value)) less than you need over the last \(days) nights.")
        case .sleepShifted:
            return String(localized: "The middle of your night moved by \(FBFormat.duration(minutes: abs(value))).")
        case .loadWithoutRecovery:
            return String(localized: "Recovery is \(Int(value.rounded())) after \(days) days of strain above your normal.")
        }
    }
}
