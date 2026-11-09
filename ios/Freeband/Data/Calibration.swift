import Foundation

/// Transport counts only: no health measurements or file identifiers.
struct BandHistoryDiagnostics: Codable, Equatable, Sendable {
    var todayCount: Int?
    var pastCount: Int?
    var todayKinds: [String: Int] = [:]
    var pastKinds: [String: Int] = [:]
    var requested: Int = 0
    var received: Int = 0
    var failed: Int = 0
    var listIncomplete: Bool = false
}

// Phase 0 calibration (plan section 4, "Kalibrasyon"): after a sync, one report with every file
// (kind, version, size, CRC, parse status, warnings) and plausibility checks against the band's
// own numbers. Foundation only; the store side (AppModel) only saves and shares it.

struct CalibrationReport: Codable, Equatable, Sendable {
    struct FileEntry: Codable, Equatable, Sendable {
        var fileID: String
        var kind: String
        var version: Int
        var size: Int
        var crcStored: String?
        var crcComputed: String?
        var crcOK: Bool?
        var status: String
        var note: String
        var warnings: [String]
        /// Minute records (daily details only).
        var records: Int?
        var fetchedAt: Date?
    }

    struct Check: Codable, Equatable, Sendable {
        enum Status: String, Codable, Sendable {
            case pass, warn, fail, skip
        }

        var name: String
        var status: Status
        /// A day ("2026-10-13") or a file id the check is about.
        var subject: String?
        var detail: String
    }

    var schema = "freeband.calibration.v1"
    var generatedAt: Date
    var bandID: String?
    /// complete / partial: reason / failed: reason / reparse.
    var outcome: String?
    var parserVersion: Int
    var algoVersion: Int
    var files: [FileEntry]
    var checks: [Check]
    var history: BandHistoryDiagnostics? = nil

    var counts: [String: Int] {
        var out: [String: Int] = [:]
        for c in checks { out[c.status.rawValue, default: 0] += 1 }
        return out
    }

    func json() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)) ?? Data()
    }

    static func decode(_ data: Data) -> CalibrationReport? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CalibrationReport.self, from: data)
    }
}

enum Calibration {
    /// Minute steps must match the band's daily total within 2% (plan), and at least 10 steps
    /// so a near-empty day is not failed on rounding (choice).
    static let stepTolerance = 0.02
    static let stepToleranceFloor = 10.0

    private static func hex8(_ v: UInt32) -> String {
        let s = String(v, radix: 16)
        return String(repeating: "0", count: max(0, 8 - s.count)) + s
    }

    static func fileEntry(_ result: ActivityParseResult, output: IngestOutput, size: Int, fetchedAt: Date?) -> CalibrationReport.FileEntry {
        CalibrationReport.FileEntry(
            fileID: output.fileID, kind: result.kind.rawValue, version: output.version, size: size,
            crcStored: result.crc.map { hex8($0.stored) }, crcComputed: result.crc.map { hex8($0.computed) },
            crcOK: result.crc?.ok, status: output.status.rawValue, note: output.note, warnings: result.warnings,
            records: output.minuteRecords, fetchedAt: fetchedAt
        )
    }

    // MARK: checks

    /// Sum of the minute steps against the band's daily summary.
    static func stepsCheck(minutes: MinuteDayDraft, summary: DaySummaryDraft) -> CalibrationReport.Check {
        let sum = minutes.series.stepTotal
        guard let total = summary.steps else {
            return .init(name: "steps_vs_summary", status: .skip, subject: minutes.day.string, detail: "summary has no steps")
        }
        let tolerance = max(Double(total) * stepTolerance, stepToleranceFloor)
        let diff = Double(sum - total)
        let pct = total > 0 ? diff / Double(total) * 100 : 0
        return .init(name: "steps_vs_summary", status: abs(diff) <= tolerance ? .pass : .fail, subject: minutes.day.string,
                     detail: "minutes \(sum), summary \(total), diff \(Int(diff)) (\(String(format: "%+.1f", pct))%)")
    }

    /// Every heart rate the files carry should lie in 30-220.
    static func heartRateCheck(minuteDays: [MinuteDayDraft], sleeps: [SleepDraft]) -> CalibrationReport.Check {
        var values = minuteDays.flatMap { $0.series.heartRate.compactMap { $0 } }
        values += sleeps.flatMap(\.hrValues).filter { $0 > 0 }
        guard let lo = values.min(), let hi = values.max() else {
            return .init(name: "heart_rate_range", status: .skip, subject: nil, detail: "no heart rate")
        }
        let outside = values.filter { !ValidRange.heartRate.contains($0) }.count
        let status: CalibrationReport.Check.Status = outside == 0 ? .pass : (Double(outside) / Double(values.count) <= 0.01 ? .warn : .fail)
        return .init(name: "heart_rate_range", status: status, subject: nil,
                     detail: "\(values.count) readings, \(lo)-\(hi) bpm, \(outside) outside 30-220")
    }

    /// A minute file should hold one record per minute from its start to when it was fetched
    /// (or to the end of its local day, whichever comes first).
    static func recordCountCheck(fileID: ActivityFileID, records: Int, fetchedAt: Date) -> CalibrationReport.Check {
        let tz = fileID.utcOffsetMinutes
        let day = DayKey(date: fileID.ts, offsetMinutes: tz)
        let dayEnd = day.adding(days: 1).start(offsetMinutes: tz)
        let until = min(fetchedAt, dayEnd)
        let expected = max(Int((until.timeIntervalSince(fileID.ts) / 60).rounded(.down)), 0)
        let diff = records - expected
        let tolerance = max(5, expected / 100)
        let status: CalibrationReport.Check.Status
        if abs(diff) <= tolerance {
            status = .pass
        } else if abs(diff) <= max(15, expected / 10) {
            status = .warn
        } else {
            status = .fail
        }
        return .init(name: "records_vs_elapsed", status: status, subject: fileID.hex,
                     detail: "\(records) records, \(expected) minutes from file start to \(until == dayEnd ? "day end" : "fetch"), diff \(diff)")
    }

    /// Bed and wake times that make sense for a sleep fetched at `fetchedAt`.
    static func sleepCheck(_ s: SleepDraft, fetchedAt: Date?) -> CalibrationReport.Check {
        var problems: [String] = []
        let hours = s.durationMinutes / 60
        if s.wakeTime <= s.bedTime { problems.append("wake before bed") }
        if hours < 1.0 / 3.0 || hours > 16 { problems.append(String(format: "%.1f h long", hours)) }
        if let fetchedAt {
            if s.wakeTime > fetchedAt.addingTimeInterval(600) { problems.append("wake after the fetch") }
            if s.bedTime < fetchedAt.addingTimeInterval(-7 * 86_400) { problems.append("bed over a week before the fetch") }
        }
        let staged = [s.deepMinutes, s.lightMinutes, s.remMinutes, s.awakeMinutes].compactMap { $0 }.reduce(0, +)
        var stageNote = ""
        if staged > 0, s.durationMinutes > 0 {
            let ratio = Double(staged) / s.durationMinutes
            stageNote = String(format: ", stages %d min (%.0f%% of in bed)", staged, ratio * 100)
            if ratio < 0.8 || ratio > 1.15 { problems.append("stage minutes \(staged) vs \(Int(s.durationMinutes)) in bed") }
        }
        let local = Int64(s.bedTime.timeIntervalSince1970) + Int64(s.tzOffsetMinutes) * 60
        let secondOfDay = ((local % 86_400) + 86_400) % 86_400
        let bedClock = String(format: "%02d:%02d", secondOfDay / 3600, secondOfDay % 3600 / 60)
        let detail = "\(s.kind.rawValue) v\(s.fileVersion), bed \(bedClock) local, \(String(format: "%.1f", hours)) h\(s.isNap ? ", nap" : "")\(stageNote)"
            + (problems.isEmpty ? "" : "; " + problems.joined(separator: "; "))
        return .init(name: "sleep_plausible", status: problems.isEmpty ? .pass : .fail, subject: s.sourceFileID, detail: detail)
    }

    /// Whether the sleep details files carry RR intervals (the HRV path depends on it).
    static func rrCheck(_ sleeps: [SleepDraft]) -> CalibrationReport.Check {
        let details = sleeps.filter { $0.kind == .details }
        guard !details.isEmpty else {
            return .init(name: "rr_present", status: .skip, subject: nil, detail: "no sleep details file")
        }
        let with = details.filter { $0.rrBeats > 0 }
        let beats = details.reduce(0) { $0 + $1.rrBeats }
        let packets = details.reduce(0) { $0 + $1.rr.count }
        return .init(name: "rr_present", status: with.isEmpty ? .warn : .pass, subject: nil,
                     detail: "\(with.count)/\(details.count) sleep files with RR, \(packets) packets, \(beats) intervals")
    }

    // MARK: report

    struct MinuteFile: Sendable {
        var fileID: ActivityFileID
        var records: Int
        var fetchedAt: Date
    }

    static func build(files: [CalibrationReport.FileEntry], minuteFiles: [MinuteFile], minuteDays: [MinuteDayDraft],
                      summaries: [DaySummaryDraft], sleeps: [SleepDraft], fetchedAt: [String: Date] = [:],
                      bandID: String?, outcome: String?, parserVersion: Int, algoVersion: Int,
                      now: Date = Date()) -> CalibrationReport {
        var checks: [CalibrationReport.Check] = []
        let byDay = Dictionary(minuteDays.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        for summary in summaries.sorted(by: { $0.day < $1.day }) {
            if let minutes = byDay[summary.day] {
                checks.append(stepsCheck(minutes: minutes, summary: summary))
            } else {
                checks.append(.init(name: "steps_vs_summary", status: .skip, subject: summary.day.string, detail: "no minute file for the day"))
            }
        }
        checks.append(heartRateCheck(minuteDays: minuteDays, sleeps: sleeps))
        for f in minuteFiles.sorted(by: { $0.fileID < $1.fileID }) {
            checks.append(recordCountCheck(fileID: f.fileID, records: f.records, fetchedAt: f.fetchedAt))
        }
        for s in sleeps.sorted(by: { $0.bedTime < $1.bedTime }) {
            checks.append(sleepCheck(s, fetchedAt: fetchedAt[s.sourceFileID]))
        }
        checks.append(rrCheck(sleeps))
        return CalibrationReport(generatedAt: now, bandID: bandID, outcome: outcome, parserVersion: parserVersion,
                                 algoVersion: algoVersion, files: files, checks: checks)
    }
}
