import SwiftData
import SwiftUI

// Workouts the band recorded (docs/ACTIVITY.md 6.6): the day's list on Today and one workout's facts.

extension Workout {
    var sportName: String {
        switch sport {
        case "outdoor_running": String(localized: "Outdoor run", comment: "Workout sport")
        case "trail_running": String(localized: "Trail run", comment: "Workout sport")
        case "treadmill": String(localized: "Treadmill", comment: "Workout sport")
        case "walking": String(localized: "Walk", comment: "Workout sport")
        case "outdoor_walking": String(localized: "Outdoor walk", comment: "Workout sport")
        case "indoor_walking": String(localized: "Indoor walk", comment: "Workout sport")
        case "hiking": String(localized: "Hike", comment: "Workout sport")
        case "trekking": String(localized: "Trek", comment: "Workout sport")
        case "outdoor_cycling": String(localized: "Outdoor ride", comment: "Workout sport")
        case "indoor_cycling": String(localized: "Indoor ride", comment: "Workout sport")
        case "freestyle": String(localized: "Free training", comment: "Workout sport")
        case "indoor_fitness": String(localized: "Indoor fitness", comment: "Workout sport")
        case "hiit": String(localized: "HIIT", comment: "Workout sport")
        case "rowing": String(localized: "Rowing", comment: "Workout sport")
        case "elliptical": String(localized: "Elliptical", comment: "Workout sport")
        default: String(localized: "Workout", comment: "Activity file kind")
        }
    }

    var symbol: String {
        switch sport {
        case "outdoor_running", "trail_running", "treadmill": "figure.run"
        case "walking", "outdoor_walking", "indoor_walking": "figure.walk"
        case "hiking", "trekking": "figure.hiking"
        case "outdoor_cycling": "figure.outdoor.cycle"
        case "indoor_cycling": "figure.indoor.cycle"
        case "rowing": "figure.rower"
        case "elliptical": "figure.elliptical"
        case "hiit": "figure.highintensity.intervaltraining"
        default: "figure.mixed.cardio"
        }
    }

    var durationText: String { FBFormat.duration(minutes: Double(activeSeconds) / 60) }

    /// Kilometres or miles, as Settings > Units has them.
    var distanceText: String? {
        distanceMeters.map {
            Measurement(value: Double($0), unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0 ... 2)))
                    .locale(UnitSetting.current.locale))
        }
    }

    static func kcal(_ value: Int?) -> String? {
        value.map { "\(FBFormat.number($0)) \(String(localized: "kcal"))" }
    }

    /// Seconds per kilometre as "5:42 /km", or per mile as "9:10 /mi".
    static func pace(_ secondsPerKm: Int?) -> String? {
        secondsPerKm.map {
            let miles = UnitSetting.current.usesMiles
            let time = Duration.seconds(miles ? (Double($0) * 1.609344).rounded() : Double($0)).formatted(.time(pattern: .minuteSecond))
            return miles ? String(localized: "\(time) /mi", comment: "Pace: minutes and seconds per mile")
                : String(localized: "\(time) /km", comment: "Pace: minutes and seconds per kilometre")
        }
    }

    static func speed(_ kmh: Double?) -> String? {
        kmh.map {
            Measurement(value: $0, unit: UnitSpeed.kilometersPerHour)
                .formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(1)))
                    .locale(UnitSetting.current.locale))
        }
    }

    static func cadence(_ perMinute: Int?) -> String? {
        perMinute.map { String(localized: "\($0) spm", comment: "Cadence: steps per minute") }
    }
}

/// Today's "Workouts": one row per workout that starts on the shown day; nothing when there is none.
struct WorkoutsSection: View {
    @Query private var workouts: [Workout]

    init(bandID: UUID, day: DayKey) {
        let index = day.index
        _workouts = Query(filter: #Predicate<Workout> { $0.bandID == bandID && $0.dayIndex == index }, sort: \Workout.start)
    }

    var body: some View {
        if !workouts.isEmpty {
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                SectionHeader(title: String(localized: "Workouts"))
                ListCard {
                    ForEach(workouts) { workout in
                        NavigationLink(value: Route.workout(fileID: workout.sourceFileID)) {
                            ListRow(title: workout.sportName,
                                    subtitle: [FBFormat.time(workout.start), workout.durationText].joined(separator: " · "),
                                    value: workout.distanceText ?? Workout.kcal(workout.calories ?? workout.totalCalories),
                                    systemImage: workout.symbol,
                                    showsDivider: workout.persistentModelID != workouts.last?.persistentModelID)
                        }
                        .buttonStyle(.fbRow)
                    }
                }
            }
        }
    }
}

/// One workout's summary, as the band wrote it. Rows the band has no value for are left out.
struct WorkoutDetailView: View {
    @Query private var workouts: [Workout]

    init(bandID: UUID, fileID: String) {
        _workouts = Query(filter: #Predicate<Workout> { $0.bandID == bandID && $0.sourceFileID == fileID })
    }

    var body: some View {
        ScrollView {
            if let w = workouts.first {
                VStack(alignment: .leading, spacing: FBSpace.l) {
                    Text([FBFormat.dayTitle(w.start), FBFormat.span(w.start, w.end)].joined(separator: " · "))
                        .textStyle(.subhead)
                        .foregroundStyle(.textSecondary)
                    group(nil, [
                        (String(localized: "Duration"), w.durationText),
                        (String(localized: "Distance"), w.distanceText),
                        (String(localized: "Steps"), w.steps.map { FBFormat.number($0) }),
                        (String(localized: "Active calories"), Workout.kcal(w.calories)),
                        (String(localized: "Total calories"), Workout.kcal(w.totalCalories)),
                    ])
                    group(String(localized: "Heart rate"), [
                        (String(localized: "Average"), w.hrAvg.map { FBFormat.bpm(Double($0)) }),
                        (String(localized: "Max"), w.hrMax.map { FBFormat.bpm(Double($0)) }),
                        (String(localized: "Min"), w.hrMin.map { FBFormat.bpm(Double($0)) }),
                    ])
                    group(String(localized: "Pace and cadence"), [
                        (String(localized: "Average pace"), Workout.pace(w.paceAvg)),
                        (String(localized: "Best pace"), Workout.pace(w.paceBest)),
                        (String(localized: "Average speed"), Workout.speed(w.speedAvg)),
                        (String(localized: "Top speed"), Workout.speed(w.speedMax)),
                        (String(localized: "Average cadence"), Workout.cadence(w.cadenceAvg)),
                        (String(localized: "Highest cadence"), Workout.cadence(w.cadenceMax)),
                    ])
                    group(String(localized: "Training"), [
                        (String(localized: "Aerobic effect"), w.aerobicEffect.map { FBFormat.number($0, fraction: 1) }),
                        (String(localized: "Anaerobic effect"), w.anaerobicEffect.map { FBFormat.number($0, fraction: 1) }),
                        (String(localized: "Training load"), w.load.map { FBFormat.number($0) }),
                        (String(localized: "VO₂ max"), w.vo2max.map { FBFormat.number($0) }),
                        (String(localized: "Recovery time"), w.recoveryHours.map { FBFormat.duration(minutes: Double($0) * 60) }),
                    ])
                }
                .padding(.horizontal, FBSpace.gutter)
                .padding(.bottom, FBSpace.xl)
            }
        }
        .fbScreen()
        .navigationTitle(workouts.first?.sportName ?? String(localized: "Workout", comment: "Activity file kind"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func group(_ title: String?, _ facts: [(label: String, value: String?)]) -> some View {
        let shown = facts.filter { $0.value != nil }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                if let title { SectionHeader(title: title) }
                Card {
                    VStack(spacing: FBSpace.s) {
                        ForEach(shown, id: \.label) { FactRow($0.label, $0.value) }
                    }
                }
            }
        }
    }
}
