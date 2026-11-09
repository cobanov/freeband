import Foundation

/// Converts only explicitly eligible real-band inputs. Callers must establish provenance and
/// timestamp integrity before setting `eligible`; derived UI data alone does not establish either.
enum HealthExportMapping {
    static func minutes(_ series: MinuteSeries, namespace: UUID, eligible: Bool) -> [HealthExportSample] {
        guard eligible else { return [] }
        let start = series.day.start(offsetMinutes: series.tzOffsetMinutes)
        var samples: [HealthExportSample] = []
        for index in 0 ..< MinuteSeries.slots {
            let time = start.addingTimeInterval(TimeInterval(index * 60))
            if let steps = series.steps[index], steps > 0 {
                samples.append(.init(namespace: namespace, kind: .steps, start: time,
                                     end: time.addingTimeInterval(60), value: steps))
            }
            if let heartRate = ValidRange.hr(series.heartRate[index]) {
                samples.append(.init(namespace: namespace, kind: .heartRate, start: time,
                                     end: time, value: heartRate))
            }
            if let oxygen = ValidRange.spo2(series.spo2[index]) {
                samples.append(.init(namespace: namespace, kind: .oxygen, start: time, end: time, value: oxygen))
            }
        }
        return samples
    }

    static func sleep(_ segments: [StageSegment], bed: Date, wake: Date,
                      namespace: UUID, eligible: Bool) -> [HealthExportSample] {
        guard eligible, bed < wake else { return [] }
        var result: [HealthExportSample] = []
        for segment in segments {
            guard segment.minutes > 0, segment.start >= bed, segment.end <= wake,
                  segment.stage != .unknown, segment.stage != .notSleep else { continue }
            for minute in 0 ..< segment.minutes {
                let time = segment.start.addingTimeInterval(TimeInterval(minute * 60))
                result.append(.init(namespace: namespace, kind: .sleep, start: time,
                                    end: time.addingTimeInterval(60), value: Int(segment.stage.rawValue)))
            }
        }
        return result
    }
}
