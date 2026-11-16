import BackgroundTasks
import Combine
import Foundation
import SwiftData
import SwiftUI
import UIKit
import UserNotifications

/// The calibration report after a sync, and webhooks.
@MainActor
extension AppModel {
    // MARK: calibration

    func makeReport(_ summary: IngestSummary, bandID: UUID?, outcome: String?) -> CalibrationReport {
        var minuteDays = summary.minuteDays.values.flatMap { $0 }
        // Summaries whose day was not rebuilt in this pass: compare with the stored minute day.
        let known = Set(minuteDays.map(\.day))
        let bandIDs = Set(summary.touchedDays.keys)
        for s in summary.summaries where !known.contains(s.day) {
            let index = s.day.index
            for band in bandIDs {
                if let row = try? context.fetch(FetchDescriptor<MinuteDay>(
                    predicate: #Predicate { $0.bandID == band && $0.dayIndex == index })).first {
                    minuteDays.append(row.draft)
                }
            }
        }
        return Calibration.build(files: summary.files, minuteFiles: summary.minuteFiles, minuteDays: minuteDays,
                                 summaries: summary.summaries, sleeps: summary.sleeps, fetchedAt: summary.fetchedAt,
                                 bandID: bandID?.uuidString, outcome: outcome, parserVersion: ActivityIngest.parserVersion,
                                 algoVersion: ScoreEngine.algoVersion)
    }

    private static var calibrationURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("calibration-latest.json")
    }

    static func loadCalibration() -> CalibrationReport? {
        guard let url = calibrationURL, let data = try? Data(contentsOf: url) else { return nil }
        return CalibrationReport.decode(data)
    }

    func setCalibration(_ report: CalibrationReport?) {
        calibration = report
        guard let url = Self.calibrationURL else { return }
        if let report {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? report.json().write(to: url, options: [.atomic, .completeFileProtection])
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The latest report as a JSON file to share.
    func exportCalibration() throws -> URL? {
        guard let calibration else { return nil }
        let stamp = Payload.iso.string(from: calibration.generatedAt).replacingOccurrences(of: ":", with: "")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("freeband-calibration-\(stamp).json")
        try calibration.json().write(to: url, options: .completeFileProtection)
        return url
    }

    // MARK: webhooks

    /// Minute, sleep and score records of what this session parsed (plan section 6).
    func healthRecords(bandID: UUID, _ summary: IngestSummary) -> [[String: Any]] {
        var records: [[String: Any]] = []
        for draft in (summary.minuteDays[bandID] ?? []).sorted(by: { $0.day < $1.day }) {
            records += Payload.minuteRecords(draft.series)
        }
        let sleepIDs = Set(summary.sleeps.map(\.sourceFileID))
        if !sleepIDs.isEmpty {
            let rows = (try? context.fetch(FetchDescriptor<SleepRecord>(
                predicate: #Predicate { $0.bandID == bandID && $0.isPrimary }, sortBy: [SortDescriptor(\.bedTime)]))) ?? []
            records += rows.filter { sleepIDs.contains($0.sourceFileID) }.compactMap { Payload.sleepRecord($0.draft()) }
        }
        let days = summary.touchedDays[bandID] ?? []
        if let lo = days.min()?.index {
            let offset = TimeZone.current.secondsFromGMT() / 60
            let rows = (try? context.fetch(FetchDescriptor<DailyScore>(
                predicate: #Predicate { $0.bandID == bandID && $0.dayIndex >= lo }, sortBy: [SortDescriptor(\.dayIndex)]))) ?? []
            records += rows.map { Payload.scoreRecord($0, tzOffsetMinutes: offset) }
        }
        return records
    }

    func deliverWebhooks(event: String, device: Payload.Device, drafts: [SampleDraft], records: [[String: Any]]) async {
        guard !isDemo else { return }
        let hooks = ((try? context.fetch(FetchDescriptor<Webhook>())) ?? []).filter(\.enabled)
        guard !hooks.isEmpty else { return }
        let bodies = Payload.bodies(event: event, device: device, samples: drafts, records: records)
        for hook in hooks {
            guard let url = URL(string: hook.url) else { continue }
            for body in bodies {
                hook.lastStatus = await WebhookSender.deliver(body, event: event, to: url, secret: hook.secret)
            }
            hook.lastAt = Date()
        }
        try? context.save()
    }

    func ping(_ hook: Webhook) async {
        guard let url = URL(string: hook.url) else { return }
        let bands = (try? context.fetch(FetchDescriptor<Band>())) ?? []
        let device = bands.first.map { Payload.Device($0) } ?? Payload.Device(id: UUID(), name: "Freeband", model: "band10")
        let body = Payload.body(event: "ping", device: device, samples: [])
        hook.lastStatus = await WebhookSender.deliver(body, event: "ping", to: url, secret: hook.secret)
        hook.lastAt = Date()
        try? context.save()
    }
}
