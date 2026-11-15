import Charts
import SwiftData
import SwiftUI

/// How the night stands against what is needed, and how the last week does.
struct SleepNeedCard: View {
    /// Minutes asleep in the night, and in that day's naps.
    let slept: Double
    let naps: Double
    let need: Double
    /// Minutes under the need over the last nights (`Analysis.sleepDebt`); negative when over.
    let debt: (minutes: Double, nights: Int)?

    private var fraction: Double { need > 0 ? min((slept + naps) / need, 1) : 0 }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: FBSpace.m) {
                HStack(alignment: .firstTextBaseline, spacing: FBSpace.xs) {
                    Text(FBFormat.percent(need > 0 ? (slept + naps) / need : 0))
                        .textStyle(.figureL)
                        .foregroundStyle(.textPrimary)
                    Text("of your need").textStyle(.subhead).foregroundStyle(.textSecondary)
                }
                .accessibilityElement(children: .combine)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.hairline)
                        Capsule().fill(Color.sleep).frame(width: geo.size.width * min(slept / max(need, 1), 1))
                        if naps > 0 {
                            Capsule().fill(Color.sleep.opacity(0.4)).frame(width: geo.size.width * fraction)
                        }
                    }
                }
                .frame(height: 8)
                .accessibilityHidden(true)
                VStack(spacing: FBSpace.xs) {
                    FactRow(String(localized: "Needed"), FBFormat.duration(minutes: need))
                    FactRow(String(localized: "Slept"), FBFormat.duration(minutes: slept))
                    if naps > 0 { FactRow(String(localized: "Napped"), FBFormat.duration(minutes: naps)) }
                    if let debt {
                        FactRow(String(localized: "Last \(debt.nights) nights"), balance(debt.minutes))
                    }
                }
            }
        }
    }

    private func balance(_ debt: Double) -> String {
        if debt >= 15 { return String(localized: "\(FBFormat.duration(minutes: debt)) short") }
        if debt <= -15 { return String(localized: "\(FBFormat.duration(minutes: -debt)) over") }
        return String(localized: "On target")
    }
}

/// Heart rate variability through the night: one point per usable 5-minute window of the
/// band's beat-to-beat data. The night's value is the median of the second half, which is shaded.
struct NightHRVSection: View {
    let night: SleepRecord
    let value: Double?
    @Query private var rr: [SleepRR]

    init(night: SleepRecord, value: Double?) {
        self.night = night
        self.value = value
        let file = night.sourceFileID
        let band = night.bandID
        _rr = Query(filter: #Predicate<SleepRR> { $0.bandID == band && $0.sourceFileID == file })
    }

    private struct Point: Identifiable {
        let date: Date
        let rmssd: Double
        var id: Date { date }
    }

    var body: some View {
        let points = (rr.first.map { HRV.windows($0.segments, bedTime: night.bedTime, wakeTime: night.wakeTime) } ?? [])
            .filter(\.usable).compactMap { w in w.rmssd.map { Point(date: w.start.addingTimeInterval(w.seconds / 2), rmssd: $0) } }
        if points.count > 2 {
            let middle = night.bedTime.addingTimeInterval(night.wakeTime.timeIntervalSince(night.bedTime) / 2)
            let top = (points.map(\.rmssd).max() ?? 50) * 1.15
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                SectionHeader(title: String(localized: "Heart rate variability, ms"),
                              trailing: value.map { String(localized: "≈ \(FBFormat.number($0)) ms") })
                Card {
                    Chart {
                        RectangleMark(xStart: .value("Time", middle), xEnd: .value("Time", night.wakeTime),
                                      yStart: .value("ms", 0), yEnd: .value("ms", top))
                            .foregroundStyle(Color.textPrimary.opacity(0.05))
                        ForEach(points) { p in
                            LineMark(x: .value("Time", p.date), y: .value("ms", p.rmssd))
                                .foregroundStyle(Color.textTertiary)
                                .lineStyle(StrokeStyle(lineWidth: 1))
                            PointMark(x: .value("Time", p.date), y: .value("ms", p.rmssd))
                                .foregroundStyle(Color.good)
                                .symbolSize(18)
                        }
                        if let value {
                            RuleMark(y: .value("Night", value))
                                .foregroundStyle(Color.textSecondary)
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        }
                    }
                    .chartXScale(domain: night.bedTime ... night.wakeTime)
                    .chartYScale(domain: 0 ... top)
                    .chartXAxis {
                        AxisMarks(values: [night.bedTime, night.wakeTime]) { mark in
                            AxisValueLabel(anchor: mark.index == 0 ? .topLeading : .topTrailing) {
                                if let date = mark.as(Date.self) {
                                    Text(FBFormat.time(date)).font(.fb(.caption)).foregroundStyle(.textSecondary)
                                }
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { mark in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: FBStroke.hairline)).foregroundStyle(.hairline)
                            AxisValueLabel {
                                if let v = mark.as(Double.self) {
                                    Text(FBFormat.number(v)).font(.fb(.caption)).foregroundStyle(.textSecondary)
                                }
                            }
                        }
                    }
                    .frame(height: 140)
                    .accessibilityLabel(Text("Heart rate variability through the night"))
                }
                Footnote(String(localized: "Each point is five minutes. The night's value is the middle one of the shaded second half, when the body is most settled."))
            }
        }
    }
}

/// The night in a few sentences (Analysis.nightNotes), from the first night on.
struct NightReviewCard: View {
    let notes: [NightNote]
    /// The day's naps are counted towards the need; the sentence says so when there were any.
    var napped = false

    var body: some View {
        if !notes.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: FBSpace.s) {
                    ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                        NoteRow(tone: note.tone, title: note.title, detail: note.detail(napped: napped))
                    }
                }
            }
        }
    }
}

extension NightNote {
    var title: String {
        switch kind {
        case .needMet: String(localized: "You met your sleep need")
        case .short: String(localized: "Under your sleep need")
        case .restorativeHigh: String(localized: "Plenty of deep and REM sleep")
        case .restorativeLow: String(localized: "Little deep and REM sleep")
        case .restless: String(localized: "A restless night")
        case .heartRateStayedUp: String(localized: "Heart rate stayed up")
        }
    }

    func detail(napped: Bool) -> String {
        switch kind {
        case .needMet, .short:
            let slept = FBFormat.duration(minutes: value), need = FBFormat.duration(minutes: reference ?? 0)
            return napped ? String(localized: "\(slept) with the day's naps, against a need of \(need).")
                          : String(localized: "\(slept) against a need of \(need).")
        case .restorativeHigh, .restorativeLow:
            return String(localized: "\(FBFormat.duration(minutes: value)) together, \(FBFormat.percent(reference ?? 0)) of the night.")
        case .restless:
            return String(localized: "\(FBFormat.duration(minutes: value)) awake in bed; \(FBFormat.percent(reference ?? 0)) of the time in bed was sleep.")
        case .heartRateStayedUp:
            return String(localized: "It fell \(FBFormat.percent(value)) from the evening before bed; a fall of 10% or more is usual.")
        }
    }
}
