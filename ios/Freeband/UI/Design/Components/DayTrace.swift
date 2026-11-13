import SwiftUI

/// The day in one picture, midnight to midnight: heart rate as a line, steps as bars under it
/// and sleep as a band along the bottom, coloured by stage. Today's focal object after the
/// scores: the scores say how the day stands, this shows what it was made of.
/// Drawn flat on the canvas, without a card, so it reads as the page's own figure.
struct DayTrace: View {
    /// The day's minutes; nil when the band has no minute file for it.
    let minutes: MinuteSeries?
    /// Sleep stages that fall anywhere in the day (last night's end, tonight's start, naps).
    let sleep: [StageSegment]
    /// Local midnight.
    let dayStart: Date
    /// For today: where the day has got to. Nothing is drawn after it.
    var now: Date?
    /// Workouts recorded on the band that day: each is shaded behind the heart rate and steps.
    var workouts: [ClosedRange<Date>] = []

    private static let height: CGFloat = 148
    /// Heart rate on top, steps under it, sleep along the bottom; y from the top.
    private static let heartBottom: CGFloat = 86
    private static let stepsTop: CGFloat = 96
    private static let stepsBottom: CGFloat = 128
    private static let sleepTop: CGFloat = 136
    /// Readings further apart than this are not joined: the band wasn't measuring in between.
    private static let maxGapMinutes = 45
    private static let binMinutes = 15

    private struct Reading { var minute: Double; var value: Double }

    /// Minutes since `dayStart`, so a file whose day starts in another time zone still lines up.
    private func minute(_ date: Date) -> Double { date.timeIntervalSince(dayStart) / 60 }

    private var heart: [Reading] {
        guard let minutes else { return [] }
        return (0 ..< MinuteSeries.slots).compactMap { i in
            ValidRange.hr(minutes.heartRate[i]).map { Reading(minute: minute(minutes.time(ofMinute: i)), value: Double($0)) }
        }.filter { (0 ..< 1440).contains($0.minute) }
    }

    private var stepBins: [Double] {
        var bins = [Double](repeating: 0, count: 1440 / Self.binMinutes)
        guard let minutes else { return bins }
        for i in 0 ..< MinuteSeries.slots {
            guard let steps = minutes.steps[i], steps > 0 else { continue }
            let at = minute(minutes.time(ofMinute: i))
            if (0 ..< 1440).contains(at) { bins[Int(at) / Self.binMinutes] += Double(steps) }
        }
        return bins
    }

    private var hasData: Bool { !heart.isEmpty || stepBins.contains { $0 > 0 } || !sleep.isEmpty }

    var body: some View {
        if hasData {
            let heart = heart
            let low = heart.map(\.value).min()
            let high = heart.map(\.value).max()
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                Canvas { context, size in
                    draw(&context, size, heart: heart)
                }
                .frame(height: Self.height)
                HStack(spacing: 0) {
                    ForEach([0, 6, 12, 18], id: \.self) { hour in
                        Text(verbatim: String(format: "%02d", hour))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .textStyle(.caption)
                .foregroundStyle(.textTertiary)
                HStack(spacing: FBSpace.s) {
                    if let low, let high {
                        key(.heart, String(localized: "\(Int(low))–\(Int(high)) bpm", comment: "Heart rate range in the day trace's key"))
                    }
                    key(.activity, String(localized: "Steps"))
                    if !sleep.isEmpty { key(.stageLight, String(localized: "Sleep")) }
                    if !workouts.isEmpty { key(.activity.opacity(0.4), String(localized: "Workout")) }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("The day, hour by hour"))
        }
    }

    private func key(_ color: Color, _ text: String) -> some View {
        HStack(spacing: FBSpace.xxs) {
            Rectangle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
        .textStyle(.caption)
        .foregroundStyle(.textSecondary)
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize, heart: [Reading]) {
        let width = size.width
        func x(_ minute: Double) -> CGFloat { CGFloat(minute / 1440) * width }
        let end = now.map { min(max(minute($0), 0), 1440) } ?? 1440

        // Six-hour lines, and the floor the steps stand on.
        for hour in stride(from: 0, through: 24, by: 6) {
            let lineX = min(x(Double(hour) * 60), width - FBStroke.hairline)
            context.fill(Path(CGRect(x: lineX, y: 0, width: FBStroke.hairline, height: Self.stepsBottom)), with: .color(.hairline))
        }
        context.fill(Path(CGRect(x: 0, y: Self.stepsBottom, width: width, height: FBStroke.hairline)), with: .color(.hairlineStrong))

        // Workouts: a shaded stretch, so the peaks under it explain themselves.
        for workout in workouts {
            let from = max(minute(workout.lowerBound), 0)
            let to = min(minute(workout.upperBound), end)
            guard to > from else { continue }
            let rect = CGRect(x: x(from), y: 0, width: max(x(to) - x(from), 2), height: Self.stepsBottom)
            context.fill(Path(rect), with: .color(.activity.opacity(0.16)))
        }

        // Steps: a bar per quarter hour, scaled to the day's busiest one.
        let bins = stepBins
        if let top = bins.max(), top > 0 {
            let barWidth = width / CGFloat(bins.count)
            for (i, steps) in bins.enumerated() where steps > 0 {
                let h = max(1, CGFloat(steps / top) * (Self.stepsBottom - Self.stepsTop))
                let rect = CGRect(x: CGFloat(i) * barWidth + 0.5, y: Self.stepsBottom - h, width: max(barWidth - 1, 1), height: h)
                context.fill(Path(rect), with: .color(.activity))
            }
        }

        // Sleep: one band, each stretch in its stage's colour.
        for segment in sleep {
            guard let color = Self.color(segment.stage) else { continue }
            let from = max(minute(segment.start), 0)
            let to = min(minute(segment.end), end)
            guard to > from else { continue }
            let rect = CGRect(x: x(from), y: Self.sleepTop, width: max(x(to) - x(from), 1), height: Self.height - Self.sleepTop)
            context.fill(Path(rect), with: .color(color))
        }

        // Heart rate: joined where the band kept measuring, a dot where a reading stands alone.
        if let low = heart.map(\.value).min(), let high = heart.map(\.value).max() {
            let span = max(high - low, 30)
            func y(_ value: Double) -> CGFloat { 4 + CGFloat(1 - (value - low) / span) * (Self.heartBottom - 4) }
            var line = Path()
            var run = 0
            for (i, reading) in heart.enumerated() {
                let point = CGPoint(x: x(reading.minute), y: y(reading.value))
                let joined = i > 0 && reading.minute - heart[i - 1].minute <= Double(Self.maxGapMinutes)
                if joined {
                    line.addLine(to: point)
                    run += 1
                } else {
                    if i > 0, run == 0 { dot(&context, CGPoint(x: x(heart[i - 1].minute), y: y(heart[i - 1].value))) }
                    line.move(to: point)
                    run = 0
                }
            }
            if let last = heart.last, run == 0 { dot(&context, CGPoint(x: x(last.minute), y: y(last.value))) }
            context.stroke(line, with: .color(.heart), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
        }

        // Now: the day so far ends here.
        if now != nil, end < 1440 {
            context.fill(Path(CGRect(x: x(end), y: 0, width: 1, height: Self.height)), with: .color(.textPrimary))
        }
    }

    private func dot(_ context: inout GraphicsContext, _ at: CGPoint) {
        context.fill(Path(ellipseIn: CGRect(x: at.x - 1.5, y: at.y - 1.5, width: 3, height: 3)), with: .color(.heart))
    }

    private static func color(_ stage: StageKind) -> Color? {
        switch stage {
        case .deep: .stageDeep
        case .light: .stageLight
        case .rem: .stageRem
        case .awake: .stageAwake
        case .notSleep, .unknown: nil
        }
    }
}
