import Foundation
import HealthKit
import SwiftData

/// Main-actor serialization also protects the ledger from concurrent save/delete operations.
@MainActor
final class HealthExportService: ObservableObject {
    let context: ModelContext
    let writer: any HealthKitWriting
    let demo: Bool
    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var status: String?
    @Published private(set) var permissions: [HealthExportKind: HKAuthorizationStatus] = [:]
    private var generation = 0
    private var task: Task<Void, Never>?
    private var reschedule = false

    init(context: ModelContext, demo: Bool, writer: any HealthKitWriting = HealthKitWriter()) {
        self.context = context; self.demo = demo; self.writer = writer
        if let settings = try? context.fetch(FetchDescriptor<HealthExportSettings>()).first {
            enabled = settings.enabled; lastSuccess = settings.lastSuccess
        }
        refresh()
    }
    var available: Bool { writer.available && !demo && !DemoData.isActive }
    private func settings() throws -> HealthExportSettings {
        if let row = try context.fetch(FetchDescriptor<HealthExportSettings>()).first { return row }
        let row = HealthExportSettings(); context.insert(row); return row
    }
    func refresh() {
        guard available else { permissions = [:]; return }
        permissions = Dictionary(uniqueKeysWithValues: HealthExportKind.allCases.map { ($0, writer.status(for: $0)) })
    }
    func enable() async {
        guard available else { return }
        do {
            try await writer.requestAuthorization()
            refresh()
            let s = try settings(); s.enabled = true; try context.save(); enabled = true
            schedule()
        } catch { status = String(localized: "Apple Health permission request failed.") }
    }
    func disable() {
        invalidate()
        do { let s = try settings(); s.enabled = false; try context.save(); enabled = false }
        catch { status = String(localized: "Could not save Apple Health settings.") }
    }
    func invalidate() { generation += 1 }

    /// Called before local deletion. A global cutoff is conservative: another band's older,
    /// not-yet-exported history is withheld too, preventing re-import after a band is re-added.
    func suppressHistory() throws {
        invalidate()
        let s = try settings(); s.suppressBefore = Date()
        for row in try context.fetch(FetchDescriptor<HealthExportLedgerRow>()) { row.state = HealthExportEntry.State.suppressed.rawValue }
        try context.save()
    }
    func schedule() {
        refresh()
        guard enabled, available else { return }
        if task != nil { reschedule = true; return }
        let current = generation
        task = Task { [weak self] in
            guard let self else { return }
            self.busy = true
            defer {
                self.busy = false; self.task = nil
                if self.reschedule { self.reschedule = false; self.schedule() }
            }
            await self.run(generation: current)
        }
    }
    private enum ExportError: Error { case invalidLedger, unsafeSource }
    private func run(generation current: Int) async {
        do {
            let bands = try context.fetch(FetchDescriptor<Band>())
            var withheld = HealthExportKind.allCases.contains { writer.status(for: $0) != .sharingAuthorized }
            var identityConflict = false
            var processed = 0
            for band in bands {
                guard current == generation, enabled, available, !Task.isCancelled else { return }
                let siblings = bands.filter { $0.id != band.id && $0.macSuffix != nil && $0.macSuffix == band.macSuffix }
                if !siblings.isEmpty { withheld = true; identityConflict = true; continue }
                if band.healthExportNamespace == nil { band.healthExportNamespace = UUID(); try context.save() }
                guard let namespace = band.healthExportNamespace else { continue }
                guard let samples = try snapshot(band: band, namespace: namespace) else { withheld = true; continue }
                let rows = try context.fetch(FetchDescriptor<HealthExportLedgerRow>()).filter { $0.namespace == namespace }
                let entries = rows.compactMap(\.entry)
                guard entries.count == rows.count else { throw ExportError.invalidLedger }
                let cutoff = try settings().suppressBefore ?? .distantPast
                let eligible = samples.filter { $0.start >= cutoff }
                let scopes = HealthExportKind.allCases.map { HealthExportScope(namespace: namespace, kind: $0,
                                                                                start: cutoff, end: .distantFuture,
                                                                                authoritative: true) }
                let plan = try HealthExportPlanner.reconcile(samples: eligible, entries: entries, scopes: scopes)
                let planned = Dictionary(uniqueKeysWithValues: plan.entries.map { ($0.identifier, $0) })
                var rowByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.identifier, $0) })
                // Each operation is persisted before the HealthKit call. Never enqueue thousands at once.
                for change in plan.changes {
                    guard current == generation, enabled, available, !Task.isCancelled else { return }
                    if processed == 100 {
                        processed = 0
                        await Task.yield()
                        guard current == generation, enabled, available, !Task.isCancelled else { return }
                    }
                    let id: String; let kind: HealthExportKind
                    switch change { case .save(let sample, _): id = sample.identifier; kind = sample.kind
                                    case .delete(let identifier, let k): id = identifier; kind = k }
                    guard writer.status(for: kind) == .sharingAuthorized, let entry = planned[id] else { withheld = true; continue }
                    let row: HealthExportLedgerRow
                    if let existing = rowByID[id] { row = existing; row.update(entry) }
                    else { row = HealthExportLedgerRow(entry); context.insert(row); rowByID[id] = row }
                    try context.save()
                    switch change {
                    case .save(let sample, let version): try await writer.save(sample, version: version)
                    case .delete(let identifier, let kind): try await writer.delete(identifier: identifier, kind: kind)
                    }
                    guard current == generation, enabled, available else { return }
                    switch change {
                    case .save: row.state = HealthExportEntry.State.saved.rawValue
                    case .delete: row.state = HealthExportEntry.State.deleted.rawValue
                    }
                    try context.save()
                    processed += 1
                }
            }
            if identityConflict { status = String(localized: "Bands with matching identifiers need attention; Apple Health sync is paused for them.") }
            else if withheld { status = String(localized: "Some data is waiting for permission or a complete, unambiguous band sync.") }
            else {
                let s = try settings(); s.lastSuccess = Date(); try context.save(); lastSuccess = s.lastSuccess
                status = String(localized: "Apple Health sync finished.")
            }
        } catch {
            if let error = error as? HKError, error.code == .errorHealthDataRestricted {
                status = String(localized: "Apple Health access is restricted on this device.")
            } else if let error = error as? HKError, error.code == .errorAuthorizationDenied {
                status = String(localized: "Apple Health write access was denied. Change it in the Health app.")
            } else {
                status = String(localized: "Apple Health sync could not finish. Try again when Health data is available.")
            }
        }
        refresh()
    }

    /// Refuse the whole band if a relevant source is incomplete or if merged minute offsets
    /// and original absolute record times cannot be proven consistent.
    private func snapshot(band: Band, namespace: UUID) throws -> [HealthExportSample]? {
        let id = band.id
        let blobs = try context.fetch(FetchDescriptor<ActivityBlob>()).filter { $0.bandID == id && $0.type == 0 &&
            (($0.subtype == 0 && $0.detailType == 0) || $0.subtype == 3 || $0.subtype == 8) }
        guard !blobs.isEmpty else { return nil }
        var parsed: [String: ActivityParseResult] = [:]
        for blob in blobs {
            guard blob.parsedAt != nil, blob.parserVersion == ActivityIngest.parserVersion,
                  blob.parseStatus == ParseStatus.parsed.rawValue else { return nil }
            let p = ActivityParser.parse(blob.data)
            guard p.fileID?.hex == blob.fileID, IngestMapper.status(of: p) == .parsed else { return nil }
            parsed[blob.fileID] = p
        }
        var result: [HealthExportSample] = []
        var partsByDay: [DayKey: [MinuteDayDraft]] = [:]
        for (hex, p) in parsed where p.kind == .dailyDetails {
            for part in IngestMapper.map(p, fileHex: hex).minuteParts { partsByDay[part.day, default: []].append(part) }
        }
        let days = try context.fetch(FetchDescriptor<MinuteDay>()).filter { $0.bandID == id }
        guard Set(days.map(\.dayKey)) == Set(partsByDay.keys), Set(days.map(\.dayKey)).count == days.count else { return nil }
        for day in days {
            guard let parts = partsByDay[day.dayKey], let rebuilt = IngestMapper.mergeMinuteParts(parts),
                  rebuilt.series == day.series, Set(rebuilt.sourceFileIDs) == Set(day.sourceFileIDs) else { return nil }
            guard !day.sourceFileIDs.isEmpty else { return nil }
            for hex in day.sourceFileIDs {
                guard let p = parsed[hex], let file = p.fileID, file.utcOffsetMinutes == day.tzOffsetMinutes,
                      case let .dailyDetails(details) = p.payload else { return nil }
                for record in details.records where DayKey(date: record.ts, offsetMinutes: file.utcOffsetMinutes) == day.dayKey {
                    guard let minute = day.dayKey.minute(of: record.ts, offsetMinutes: file.utcOffsetMinutes),
                          record.ts == day.dayKey.start(offsetMinutes: file.utcOffsetMinutes).addingTimeInterval(TimeInterval(minute * 60)) else { return nil }
                }
            }
            result += HealthExportMapping.minutes(day.series, namespace: namespace, eligible: true)
        }
        let expectedSleeps = parsed.values.flatMap { IngestMapper.map($0).sleeps }.sorted { $0.bedTime < $1.bedTime }
        let storedSleeps = try context.fetch(FetchDescriptor<SleepRecord>()).filter { $0.bandID == id }.sorted { $0.bedTime < $1.bedTime }
        guard expectedSleeps.count == storedSleeps.count else { return nil }
        let primary = IngestMapper.primaryFlags(expectedSleeps)
        for (index, sleep) in storedSleeps.enumerated() {
            let expected = expectedSleeps[index]
            guard sleep.sourceFileID == expected.sourceFileID, sleep.bedTime == expected.bedTime,
                  sleep.wakeTime == expected.wakeTime, sleep.isPrimary == primary[index],
                  StageSegment.unpack(sleep.stageTimeline) == expected.segments else { return nil }
        }
        for sleep in storedSleeps where sleep.isPrimary {
            guard parsed[sleep.sourceFileID] != nil else { return nil }
            let stages = StageSegment.unpack(sleep.stageTimeline)
            guard sleep.stageTimeline.count % 7 == 0, sleep.bedTime < sleep.wakeTime,
                  stages.allSatisfy({ $0.minutes > 0 && $0.start >= sleep.bedTime && $0.end <= sleep.wakeTime }) else { return nil }
            result += HealthExportMapping.sleep(stages, bed: sleep.bedTime, wake: sleep.wakeTime, namespace: namespace, eligible: true)
        }
        let sleepSamples = result.filter { $0.kind == .sleep }.sorted { $0.start < $1.start }
        for index in sleepSamples.indices.dropFirst() where sleepSamples[index].start < sleepSamples[index - 1].end { return nil }
        guard Set(result.map(\.identifier)).count == result.count else { return nil }
        return result
    }
}
