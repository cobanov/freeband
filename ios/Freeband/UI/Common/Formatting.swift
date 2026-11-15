import SwiftUI

/// Metric or imperial for heights, weights, distances and speeds. `system` is what iOS has for
/// the phone's region, which is not always what its owner reads (a phone set to the United
/// States in Turkey shows feet and pounds).
enum UnitSetting: String, CaseIterable, Identifiable {
    case system, metric, imperial

    var id: String { rawValue }

    static let storageKey = "units"

    static var current: UnitSetting {
        UserDefaults.standard.string(forKey: storageKey).flatMap(UnitSetting.init) ?? .system
    }

    var title: String {
        switch self {
        case .system: String(localized: "units.system", defaultValue: "System", comment: "Units option")
        case .metric: String(localized: "units.metric", defaultValue: "Metric", comment: "Units option")
        case .imperial: String(localized: "units.imperial", defaultValue: "Imperial", comment: "Units option")
        }
    }

    /// The current locale with the chosen measurement system; measurements are formatted in it.
    var locale: Locale {
        guard self != .system else { return .current }
        var components = Locale.Components(locale: .current)
        components.measurementSystem = self == .metric ? .metric : .us
        return Locale(components: components)
    }

    var usesMiles: Bool { locale.measurementSystem != .metric }
}

/// Number, duration and date formats. Everything follows `Locale.current`: "7h 12m" / "7 sa 12 dk",
/// "96%" / "%96", "6,412" / "6.412".
enum FBFormat {
    static func duration(minutes: Double) -> String {
        Duration.seconds(max(0, minutes).rounded() * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .fb()))
    }

    /// Short enough for a delta column: "26m", then "2.4h" ("26 dk", "2,4 sa").
    static func compactDuration(minutes: Double) -> String {
        if minutes < 60 { return duration(minutes: minutes) }
        let turkish = Locale.current.language.languageCode == .turkish
        return Measurement(value: minutes / 60, unit: UnitDuration.hours)
            .formatted(.measurement(width: turkish ? .abbreviated : .narrow,
                                    numberFormatStyle: .number.precision(.fractionLength(1))))
    }

    static func number(_ value: Double, fraction: Int = 0) -> String {
        value.formatted(.number.precision(.fractionLength(fraction)))
    }

    static func number(_ value: Int) -> String { value.formatted(.number) }

    /// A 0...1 fraction as a whole percentage.
    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    static func bpm(_ value: Double) -> String {
        let n = Int(value.rounded())
        return String(localized: "\(n) bpm")
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// "Tuesday, 14 October".
    static func dayTitle(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// "Tue 14 Oct".
    static func shortDay(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// "Monday night, 13 October": the night is named after the evening it started.
    static func nightTitle(bedTime: Date) -> String {
        let weekday = bedTime.formatted(.dateTime.weekday(.wide))
        let day = bedTime.formatted(.dateTime.day().month(.wide))
        return String(localized: "\(weekday) night, \(day)", comment: "Sleep night title: weekday, then date")
    }

    /// "23:48 – 07:04".
    static func span(_ from: Date, _ to: Date) -> String {
        "\(time(from)) – \(time(to))"
    }

    /// One sentence from a list: "a, b and c" / "a, b ve c".
    static func list(_ items: [String]) -> String {
        items.formatted(.list(type: .and))
    }
}

extension Duration.UnitsFormatStyle.UnitWidth {
    /// "7h 12m" in English. Turkish's narrow form ("7sa 12d") reads oddly, so Turkish gets the
    /// abbreviated one ("7 sa. 12 dk.").
    static func fb(_ locale: Locale = .current) -> Self {
        locale.language.languageCode == .turkish ? .abbreviated : .narrow
    }
}

// MARK: confidence

extension ConfidenceLevel {
    var title: String {
        switch self {
        case .high: String(localized: "High confidence")
        case .medium: String(localized: "Medium confidence")
        case .low: String(localized: "Low confidence")
        case .none: String(localized: "No score")
        }
    }

    /// Marker shown under a score on Home.
    var isLow: Bool { self == .low }
}

enum ContributorName {
    /// Readable name for a contributor code (`hrv`, `resting_hr`, `duration`, …).
    static func name(_ raw: String) -> String {
        switch raw {
        case "hrv": String(localized: "Heart rate variability")
        case "resting_hr": String(localized: "Resting heart rate")
        case "sleep": String(localized: "Sleep score")
        case "strain": String(localized: "Previous-day strain")
        case "duration": String(localized: "Duration")
        case "efficiency": String(localized: "Efficiency")
        case "deep": String(localized: "Deep sleep")
        case "rem": String(localized: "REM sleep")
        case "restfulness": String(localized: "Restfulness")
        case "regularity": String(localized: "Regularity")
        case "hr_dip": String(localized: "Heart-rate dip")
        default: raw
        }
    }
}

extension ConfidenceReason {
    private func n(_ v: Double?) -> String {
        guard let v else { return "?" }
        return v.formatted(.number.precision(.fractionLength(0...1)))
    }

    /// One plain sentence, localized.
    var localizedText: String {
        switch code {
        case .baselineCalibrating:
            let days = n(a)
            if let detail {
                let name = ContributorName.name(detail)
                return String(localized: "\(name): still learning your normal (\(days) of 3 days).")
            }
            return String(localized: "Still learning your normal (\(days) of 3 days).")
        case .baselineShort:
            let days = n(a), window = n(b)
            if let detail {
                let name = ContributorName.name(detail)
                return String(localized: "\(name): your normal comes from \(days) of \(window) days.")
            }
            return String(localized: "Your normal comes from \(days) of \(window) days.")
        case .noRR:
            return String(localized: "The band recorded no beat-to-beat (RR) intervals, so heart rate variability is left out.")
        case .hrvTooFewWindows:
            let found = n(a), needed = n(b)
            return String(localized: "Heart rate variability: \(found) of \(needed) clean windows in the second half of the night.")
        case .sparseHeartRate:
            let minutes = n(a)
            return String(localized: "Heart rate was measured only every \(minutes) min.")
        case .lowHeartRateCoverage:
            let share = FBFormat.percent(a ?? 0)
            return String(localized: "Heart rate covers \(share) of your awake minutes.")
        case .restingHRFromBand:
            return String(localized: "Resting heart rate comes from the band's daily summary.")
        case .restingHRFromDaytime:
            return String(localized: "Resting heart rate comes from still daytime minutes.")
        case .restingHRAssumed:
            return String(localized: "Resting heart rate is assumed (60 bpm).")
        case .ageUnknown:
            return String(localized: "Your age is unknown, so maximum heart rate is assumed. Add your birth year in Profile.")
        case .noSleep:
            return String(localized: "No sleep was recorded.")
        case .noStages:
            return String(localized: "The band didn't record sleep stages for this night.")
        case .missingContributor:
            let name = ContributorName.name(detail ?? "")
            return String(localized: "Missing: \(name).")
        case .estimated:
            let weight = n(a)
            return String(localized: "An estimate: only \(weight) of 100 weight points had data.")
        case .noHeartRate:
            return String(localized: "No heart rate.")
        case .noData:
            return String(localized: "No data.")
        case .hrvApproximate:
            return String(localized: "Heart rate variability is approximate: the band reports beats to 10 ms.")
        }
    }
}
