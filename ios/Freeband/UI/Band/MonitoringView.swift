import SwiftData
import SwiftUI

/// How often the band measures (docs/CAPABILITIES.md §9.1-9.3). Opening the screen reads the
/// settings from the band; a change is written and read back, so a row always shows the band's
/// own answer. A setting the band didn't return has no row.
struct MonitoringView: View {
    let bandID: UUID

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var link: BandLink
    @Query private var matches: [Band]

    init(bandID: UUID) {
        self.bandID = bandID
        _matches = Query(filter: #Predicate<Band> { $0.id == bandID })
    }

    private var band: Band? { matches.first }
    private var busy: Bool { link.phase.isBusy }

    var body: some View {
        Form {
            if let band {
                let heartRate = model.monitoring(band, .heartRate)
                let spo2 = model.monitoring(band, .spo2)
                let stress = model.monitoring(band, .stress)
                if heartRate == nil, spo2 == nil, stress == nil {
                    Section {
                        Text(busy ? String(localized: "Reading from the band…")
                                  : String(localized: "Couldn't read the settings. Close Mi Fitness, keep the band close and try again."))
                            .foregroundStyle(.textSecondary)
                        if !busy {
                            Button(String(localized: "Try again")) { model.readMonitoring(band) }
                        }
                    }
                    .fbFormRow()
                }
                if let heartRate, let mode = MiMonitoring.heartRateMode(heartRate) {
                    Section {
                        Picker(String(localized: "Heart rate"), selection: Binding(get: { mode }, set: {
                            model.writeMonitoring(band, .heartRate, MiMonitoring.heartRate(heartRate, mode: $0))
                        })) {
                            Text("Off").tag(MiMonitoring.HeartRateMode.off)
                            Text("Smart").tag(MiMonitoring.HeartRateMode.smart)
                            ForEach(Self.intervals(mode), id: \.self) {
                                Text(FBFormat.duration(minutes: Double($0))).tag(MiMonitoring.HeartRateMode.every($0))
                            }
                        }
                        if let sleep = MiMonitoring.sleepHeartRate(heartRate) {
                            Toggle(String(localized: "Heart rate during sleep"), isOn: Binding(get: { sleep }, set: {
                                model.writeMonitoring(band, .heartRate, MiMonitoring.heartRate(heartRate, sleep: $0))
                            }))
                        }
                    } footer: {
                        Text("Every minute gives Strain and resting heart rate the most to work with, and uses the most battery.")
                    }
                    .fbFormRow()
                }
                if let spo2, let mode = MiMonitoring.spo2Mode(spo2) {
                    Section {
                        Picker(String(localized: "Blood oxygen"), selection: Binding(get: { mode }, set: {
                            model.writeMonitoring(band, .spo2, MiMonitoring.spo2(spo2, mode: $0))
                        })) {
                            Text("Off").tag(0)
                            // shortcut: "during sleep" (1) is only listed when the band reports it; a Band 10
                            // accepts it but shows it as off. List it for all once a band is seen to honour it.
                            if mode == 1 { Text("During sleep").tag(1) }
                            Text("All day").tag(2)
                        }
                    }
                    .fbFormRow()
                }
                if let stress, let allDay = MiMonitoring.stressAllDay(stress) {
                    Section {
                        Toggle(String(localized: "Stress, all day"), isOn: Binding(get: { allDay }, set: {
                            model.writeMonitoring(band, .stress, MiMonitoring.stress(stress, allDay: $0))
                        }))
                    }
                    .fbFormRow()
                }
            }
        }
        .fbFormStyle()
        .disabled(busy)
        .navigationTitle(String(localized: "Health monitoring"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if let band, !busy { model.readMonitoring(band) } }
    }

    /// 1, 10 and 30 minutes, plus the band's own interval when it is another one.
    private static func intervals(_ mode: MiMonitoring.HeartRateMode) -> [Int] {
        var all = [1, 10, 30]
        if case .every(let minutes) = mode, !all.contains(minutes) { all.append(minutes) }
        return all.sorted()
    }
}
