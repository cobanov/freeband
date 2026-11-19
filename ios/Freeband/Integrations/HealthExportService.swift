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
    private var everEnabled = false
    private var generation = 0
    private var completedGeneration: Int?
    private var completedPermissions: [HealthExportKind: HKAuthorizationStatus] = [:]
    private var task: Task<Void, Never>?
    private var reschedule = false
    private var paused = false
    private(set) var parsedFileCount = 0

    init(context: ModelContext, demo: Bool, writer: any HealthKitWriting = HealthKitWriter()) {
        self.context = context; self.demo = demo; self.writer = writer
        if let settings = try? context.fetch(FetchDescriptor<HealthExportSettings>()).first {
            enabled = settings.enabled; lastSuccess = settings.lastSuccess
            // Legacy settings could also be created by local deletion. In that case look for
            // evidence of earlier activation before carrying its cutoff forward.
            everEnabled = settings.everEnabled ?? (settings.enabled || settings.lastSuccess != nil
                || settings.suppressBefore == nil || ((try? context.fetchCount(FetchDescriptor<HealthExportLedgerRow>())) ?? 0) > 0)
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
            let s = try settings()
            if !everEnabled { s.suppressBefore = nil }
            s.everEnabled = true
            s.enabled = true
            try context.save()
            everEnabled = true
            enabled = true
            schedule()
        } catch { status = String(localized: "Apple Health permission request failed.") }
    }
    func disable() {
        guard enabled else { return }
        invalidate()
        do { let s = try settings(); s.everEnabled = true; s.enabled = false; try context.save(); enabled = false }
        catch { status = String(localized: "Could not save Apple Health settings.") }
    }
    func invalidate() {
        generation += 1
        task?.cancel()
    }

    /// Keep history export off the time budget of a background band sync.
    func pause() { paused = true; reschedule = false; task?.cancel() }
    func resume() { paused = false }

    /// Keep the cutoff and tombstones for users who have used export, including while it is off.
    func suppressHistory() throws {
        guard everEnabled else { return }
        invalidate()
        let s = try settings()
        let rows = try context.fetch(FetchDescriptor<HealthExportLedgerRow>())
        s.suppressBefore = Date()
        s.everEnabled = true
        for row in rows { row.state = HealthExportEntry.State.suppressed.rawValue }
        try context.save()
    }
    func schedule(onlyIfChanged: Bool = false) {
        guard enabled, available, !paused else { return }
        refresh()
        if onlyIfChanged, completedGeneration == generation, completedPermissions == permissions { return }
        if task != nil { reschedule = true; return }
        let current = generation
        completedGeneration = nil
        task = Task { [weak self] in
            guard let self else { return }
            self.busy = true
            defer {
                self.busy = false; self.task = nil
                if self.reschedule { self.reschedule = false; self.schedule(onlyIfChanged: true) }
            }
            await self.run(generation: current)
        }
    }
    private func run(generation current: Int) async {
        do {
            let bands = try context.fetch(FetchDescriptor<Band>())
            let initialPermissions = permissions
            let missingPermissions = HealthExportKind.allCases.filter { initialPermissions[$0] != .sharingAuthorized }
            var withheld = !missingPermissions.isEmpty
            var incompleteSource = false
            var sourceProblems = Set<String>()
            var exportableCount = 0
            var identityConflict = false
            parsedFileCount = 0
            var savedCount = 0
            var deletedCount = 0
            var failedKinds = Set<HealthExportKind>()
            var writtenByKind: [HealthExportKind: Int] = [:]
            for band in bands {
                guard current == generation, enabled, available, !Task.isCancelled else { return }
                let siblings = bands.filter { $0.id != band.id && $0.macSuffix != nil && $0.macSuffix == band.macSuffix }
                if !siblings.isEmpty { withheld = true; identityConflict = true; continue }
                if band.healthExportNamespace == nil { band.healthExportNamespace = UUID(); try context.save() }
                guard let namespace = band.healthExportNamespace else { continue }
                let cutoff = try settings().suppressBefore ?? .distantPast
                let bandID = band.id
                let container = context.container
                let parsing = Task.detached(priority: .utility) {
                    try HealthExportSnapshot(container: container).prepare(bandID: bandID, namespace: namespace, cutoff: cutoff)
                }
                let prepared = try await withTaskCancellationHandler {
                    try await parsing.value
                } onCancel: {
                    parsing.cancel()
                }
                guard current == generation, !Task.isCancelled else { return }
                parsedFileCount += prepared.cacheUpdates.count
                for (id, data) in prepared.cacheUpdates {
                    (context.model(for: id) as? ActivityBlob)?.healthExportSource = data
                }
                if !prepared.cacheUpdates.isEmpty { try context.save() }
                if !prepared.sourceProblems.isEmpty {
                    incompleteSource = true
                    sourceProblems.formUnion(prepared.sourceProblems)
                }
                exportableCount += prepared.sampleCount
                for batch in prepared.batches {
                    guard current == generation, enabled, available, !Task.isCancelled else { return }
                    let kind = batch.kind
                    guard !failedKinds.contains(kind) else { continue }
                    guard writer.status(for: kind) == .sharingAuthorized else { withheld = true; continue }
                    let rows = batch.operations.map { operation -> HealthExportLedgerRow in
                        if let id = operation.rowID, let row = context.model(for: id) as? HealthExportLedgerRow {
                            row.update(operation.entry)
                            return row
                        }
                        let row = HealthExportLedgerRow(operation.entry)
                        context.insert(row)
                        return row
                    }
                    // Record intent before touching HealthKit. Retry interrupted writes with the same versions.
                    try context.save()
                    do {
                        if batch.saves.isEmpty {
                            try await writer.delete(identifiers: batch.operations.map { $0.entry.identifier }, kind: kind)
                        } else {
                            try await writer.save(batch.saves)
                        }
                    } catch {
                        guard current == generation, !Task.isCancelled else { return }
                        failedKinds.insert(kind); withheld = true; continue
                    }
                    guard current == generation, !Task.isCancelled else { return }
                    let state: HealthExportEntry.State = batch.saves.isEmpty ? .deleted : .saved
                    for row in rows { row.state = state.rawValue }
                    try context.save()
                    if batch.saves.isEmpty {
                        deletedCount += rows.count
                    } else {
                        savedCount += rows.count
                        writtenByKind[kind, default: 0] += rows.count
                    }
                }
            }
            if !failedKinds.isEmpty { status = String(localized: "Partial Apple Health sync: \(savedCount) records written. A Health write or removal failed; try again.") }
            else if identityConflict { status = String(localized: "Apple Health sync incomplete: \(savedCount) records written, \(deletedCount) removed. Bands with matching identifiers need attention.") }
            else if incompleteSource {
                let problems = sourceProblems.sorted().joined(separator: ", ")
                status = String(localized: "Partial Apple Health sync: \(savedCount) records written. Check \(problems) in Diagnostics.")
            }
            else if !missingPermissions.isEmpty { status = String(localized: "Partial Apple Health sync: \(savedCount) records written. Some write permissions are missing.") }
            else if withheld { status = String(localized: "Partial Apple Health sync: \(savedCount) records written. Some data needs attention.") }
            else if exportableCount == 0 { status = String(localized: "No exportable band data is available yet. Sync the band and try again.") }
            else {
                let s = try settings(); s.lastSuccess = Date(); try context.save(); lastSuccess = s.lastSuccess
                status = savedCount == 0 && deletedCount == 0 ? String(localized: "Apple Health is up to date; no new records.") : String(localized: "Apple Health sync finished: \(savedCount) records written, \(deletedCount) removed.")
            }
            if failedKinds.isEmpty, !incompleteSource, !identityConflict {
                completedGeneration = current
                completedPermissions = initialPermissions
            }
            if savedCount > 0 {
                let steps = writtenByKind[.steps, default: 0], heart = writtenByKind[.heartRate, default: 0]
                let resting = writtenByKind[.restingHeartRate, default: 0], oxygen = writtenByKind[.oxygen, default: 0]
                let sleep = writtenByKind[.sleep, default: 0]
                status = (status ?? "") + "\n" + String(localized: "Written: steps \(steps), heart rate \(heart), resting heart rate \(resting), oxygen \(oxygen), sleep \(sleep).")
            }
        } catch {
            guard current == generation, !Task.isCancelled else { return }
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

}

private struct HealthExportSnapshot {
    let context: ModelContext

    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    // Saved with the blob so reopening the app only parses new or replaced files. Bump the
    // format if the projection changes. Ingest changes are covered by its parser version.
    private struct CachedSource: Codable {
        let format: Int
        let fileID: String
        let fetchedAt: Date
        let parsedAt: Date
        let parserVersion: Int
        let source: Source?
    }

    private struct Source: Codable {
        let offset: Int
        let minuteAligned: Bool
        let minuteParts: [MinuteDayDraft]
        let summary: DaySummaryDraft?
        let sleeps: [SleepDraft]
        let manual: [ManualReadingDraft]

        init?(_ blob: ActivityBlob) {
            let parsed = ActivityParser.parse(blob.data)
            guard let file = parsed.fileID, file.hex == blob.fileID, IngestMapper.status(of: parsed) == .parsed else { return nil }
            let output = IngestMapper.map(parsed, fileHex: file.hex)
            offset = file.utcOffsetMinutes
            if case let .dailyDetails(details) = parsed.payload {
                minuteAligned = details.records.allSatisfy { $0.ts.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0 }
            } else {
                minuteAligned = true
            }
            minuteParts = output.minuteParts
            summary = output.summary
            sleeps = output.sleeps
            manual = output.manual
        }
    }

    struct Operation: Sendable {
        let rowID: PersistentIdentifier?
        let entry: HealthExportEntry
    }

    struct Batch: Sendable {
        let kind: HealthExportKind
        let operations: [Operation]
        let saves: [HealthExportWrite]
    }

    struct PreparedBand: Sendable {
        let cacheUpdates: [PersistentIdentifier: Data]
        let sourceProblems: Set<String>
        let sampleCount: Int
        let batches: [Batch]
    }

    enum ExportError: Error { case invalidLedger }

    func prepare(bandID id: UUID, namespace: UUID, cutoff: Date) throws -> PreparedBand {
        let files = try context.fetch(FetchDescriptor<ActivityBlob>(predicate: #Predicate { $0.bandID == id && $0.type == 0 }))
        let blobs = files.filter {
            ($0.subtype == 0 && ($0.detailType == 0 || $0.detailType == 1)) ||
                $0.subtype == 3 || $0.subtype == 6 || $0.subtype == 8
        }
        var sources: [String: Source] = [:]
        var cacheUpdates: [PersistentIdentifier: Data] = [:]
        var sourceProblems = Set<String>()
        let decoder = PropertyListDecoder()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        for blob in blobs {
            try Task.checkCancellation()
            if let parsedAt = blob.parsedAt, blob.parserVersion == ActivityIngest.parserVersion,
               blob.parseStatus == ParseStatus.parsed.rawValue {
                let cached = blob.healthExportSource.flatMap { try? decoder.decode(CachedSource.self, from: $0) }
                if let cached, cached.format == 1, cached.fileID == blob.fileID,
                   cached.fetchedAt == blob.fetchedAt, cached.parsedAt == parsedAt, cached.parserVersion == blob.parserVersion {
                    sources[blob.fileID] = cached.source
                } else {
                    let source = Source(blob)
                    sources[blob.fileID] = source
                    let cached = CachedSource(format: 1, fileID: blob.fileID, fetchedAt: blob.fetchedAt,
                                              parsedAt: parsedAt, parserVersion: blob.parserVersion, source: source)
                    cacheUpdates[blob.persistentModelID] = try encoder.encode(cached)
                }
            }
            if sources[blob.fileID] == nil {
                switch (blob.subtype, blob.detailType) {
                case (0, 0): sourceProblems.insert(String(localized: "minute data"))
                case (0, 1): sourceProblems.insert(String(localized: "daily summary"))
                case (3, _), (8, _): sourceProblems.insert(String(localized: "sleep"))
                case (6, _): sourceProblems.insert(String(localized: "manual readings"))
                default: break
                }
            }
        }
        let rows = try context.fetch(FetchDescriptor<HealthExportLedgerRow>(predicate: #Predicate { $0.namespace == namespace }))
        let entries = rows.compactMap(\.entry)
        guard entries.count == rows.count else { throw ExportError.invalidLedger }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.identifier, $0.persistentModelID) })
        let complete = sourceProblems.isEmpty ? try snapshot(bandID: id, namespace: namespace, blobs: blobs, sources: sources) : nil
        if complete == nil, sourceProblems.isEmpty { sourceProblems.insert(String(localized: "ambiguous minute or sleep data")) }
        let samples = try complete ?? fallback(bandID: id, namespace: namespace, blobs: blobs, sources: sources, entries: entries)
        let eligible = samples.filter { $0.start >= cutoff }

        let hasMinutes = blobs.contains { $0.subtype == 0 && $0.detailType == 0 }
        let hasSummary = blobs.contains { $0.subtype == 0 && $0.detailType == 1 }
        let hasSleep = blobs.contains { $0.subtype == 3 || $0.subtype == 8 }
        let hasManual = blobs.contains { $0.subtype == 6 }
        let authoritative: [HealthExportKind] = complete == nil ? [] : HealthExportKind.allCases.filter {
            switch $0 {
            case .steps: return hasMinutes || hasSummary
            case .heartRate, .oxygen: return hasMinutes || hasSleep || hasManual
            case .restingHeartRate: return hasSummary
            case .sleep: return hasSleep
            }
        }
        let scopes = authoritative.map {
            HealthExportScope(namespace: namespace, kind: $0, start: cutoff, end: .distantFuture, authoritative: true)
        }
        try Task.checkCancellation()
        let plan = try HealthExportPlanner.reconcile(samples: eligible, entries: entries, scopes: scopes)
        let planned = Dictionary(uniqueKeysWithValues: plan.entries.map { ($0.identifier, $0) })
        // Delete obsolete overlapping samples before saving any replacements. Each HealthKit
        // call and its two ledger saves are bounded, even when importing months of data.
        var deletes: [HealthExportKind: [Operation]] = [:]
        var saves: [HealthExportKind: [(Operation, HealthExportWrite)]] = [:]
        for change in plan.changes {
            switch change {
            case .delete(let id, let kind):
                guard let entry = planned[id] else { throw ExportError.invalidLedger }
                deletes[kind, default: []].append(Operation(rowID: byID[id], entry: entry))
            case .save(let sample, let version):
                let id = sample.identifier
                guard let entry = planned[id] else { throw ExportError.invalidLedger }
                saves[sample.kind, default: []].append((Operation(rowID: byID[id], entry: entry),
                                                       HealthExportWrite(sample: sample, version: version)))
            }
        }
        let limit = 250
        var batches: [Batch] = []
        for kind in HealthExportKind.allCases {
            let work = deletes[kind] ?? []
            for start in stride(from: 0, to: work.count, by: limit) {
                batches.append(Batch(kind: kind, operations: Array(work[start..<min(start + limit, work.count)]), saves: []))
            }
        }
        for kind in HealthExportKind.allCases {
            let work = saves[kind] ?? []
            for start in stride(from: 0, to: work.count, by: limit) {
                let batch = work[start..<min(start + limit, work.count)]
                batches.append(Batch(kind: kind, operations: batch.map { $0.0 }, saves: batch.map { $0.1 }))
            }
        }
        return PreparedBand(cacheUpdates: cacheUpdates, sourceProblems: sourceProblems, sampleCount: eligible.count, batches: batches)
    }

    /// Refuse the whole band if a relevant source is incomplete or if merged minute offsets
    /// and original absolute record times cannot be proven consistent.
    private func snapshot(bandID id: UUID, namespace: UUID, blobs: [ActivityBlob],
                          sources: [String: Source]) throws -> [HealthExportSample]? {
        var result: [HealthExportSample] = []
        var partsByDay: [DayKey: [MinuteDayDraft]] = [:]
        for output in sources.values {
            for part in output.minuteParts { partsByDay[part.day, default: []].append(part) }
        }
        let days = try context.fetch(FetchDescriptor<MinuteDay>(predicate: #Predicate { $0.bandID == id }))
        guard Set(days.map(\.dayKey)) == Set(partsByDay.keys), Set(days.map(\.dayKey)).count == days.count else { return nil }
        for day in days {
            guard let parts = partsByDay[day.dayKey], let rebuilt = IngestMapper.mergeMinuteParts(parts),
                  rebuilt.series == day.series, Set(rebuilt.sourceFileIDs) == Set(day.sourceFileIDs) else { return nil }
            guard !day.sourceFileIDs.isEmpty else { return nil }
            guard day.sourceFileIDs.allSatisfy({ sources[$0]?.offset == day.tzOffsetMinutes && sources[$0]?.minuteAligned == true }) else { return nil }
            result += HealthExportMapping.minutes(day.series, namespace: namespace, eligible: true)
        }
        // A summary is one cumulative interval, never an additional source of minute steps.
        // Validate the persisted projection against the CRC-checked source before using it.
        let summaries = try context.fetch(FetchDescriptor<DaySummary>(predicate: #Predicate { $0.bandID == id }))
        let expectedSummaryIDs = Set(sources.values.compactMap { $0.summary?.sourceFileID })
        guard Set(summaries.map(\.sourceFileID)) == expectedSummaryIDs,
              Set(summaries.map(\.sourceFileID)).count == summaries.count else { return nil }
        let grouped = Dictionary(grouping: summaries, by: { $0.dayIndex })
        for summariesForDay in grouped.values {
            guard let summary = summariesForDay.max(by: { $0.updatedAt < $1.updatedAt }) else { continue }
            guard let expected = sources[summary.sourceFileID]?.summary,
                  expected == summary.draft,
                  let blob = blobs.first(where: { $0.fileID == summary.sourceFileID }) else { return nil }
            let start = expected.day.start(offsetMinutes: expected.tzOffsetMinutes)
            let end = min(start.addingTimeInterval(86_400), blob.fetchedAt)
            guard end > start else { continue }
            let day = days.first { $0.dayIndex == summary.dayIndex && $0.tzOffsetMinutes == summary.tzOffsetMinutes }
            let completeMinuteDay = day.map { $0.series.steps.allSatisfy { $0 != nil } } == true && end >= start.addingTimeInterval(86_400)
            if let steps = expected.steps, steps > 0, !completeMinuteDay {
                // A summary covers the whole elapsed day, including any minute records.
                result.removeAll { $0.kind == .steps && $0.start >= start && $0.start < start.addingTimeInterval(86_400) }
                result.append(.init(namespace: namespace, kind: .steps, start: start, end: end, value: steps))
            }
            if let hr = ValidRange.hr(expected.hrResting) {
                result.append(.init(namespace: namespace, kind: .restingHeartRate, start: start, end: end, value: hr))
            }
        }
        // Manual spot readings have explicit timestamps. Prefer the detailed minute source
        // when both sources describe the same minute; choose one spot otherwise.
        for kind in [HealthExportKind.heartRate, .oxygen] {
            var occupied = Set(result.filter { $0.kind == kind }.map { Int64(floor($0.start.timeIntervalSince1970 / 60)) })
            let manual = sources.values.flatMap(\.manual).sorted { $0.ts < $1.ts }
            for reading in manual {
                let valid = kind == .heartRate ? (reading.kind == "heart_rate" && ValidRange.hr(reading.value) != nil)
                    : (reading.kind == "spo2" && ValidRange.spo2(reading.value) != nil)
                let slot = Int64(floor(reading.ts.timeIntervalSince1970 / 60))
                guard valid, occupied.insert(slot).inserted else { continue }
                result.append(.init(namespace: namespace, kind: kind, start: reading.ts, end: reading.ts, value: reading.value))
            }
        }
        let expectedSleeps = sources.values.flatMap(\.sleeps).sorted { $0.bedTime < $1.bedTime }
        let storedSleeps = try context.fetch(FetchDescriptor<SleepRecord>(predicate: #Predicate { $0.bandID == id })).sorted { $0.bedTime < $1.bedTime }
        guard expectedSleeps.count == storedSleeps.count else { return nil }
        let primary = IngestMapper.primaryFlags(expectedSleeps)
        for (index, sleep) in storedSleeps.enumerated() {
            let expected = expectedSleeps[index]
            guard sleep.sourceFileID == expected.sourceFileID, sleep.bedTime == expected.bedTime,
                  sleep.wakeTime == expected.wakeTime, sleep.isPrimary == primary[index],
                  StageSegment.unpack(sleep.stageTimeline) == expected.segments else { return nil }
        }
        for sleep in storedSleeps where sleep.isPrimary {
            let stages = StageSegment.unpack(sleep.stageTimeline)
            guard sleep.stageTimeline.count % 7 == 0, sleep.bedTime < sleep.wakeTime,
                  stages.allSatisfy({ $0.minutes > 0 && $0.start >= sleep.bedTime && $0.end <= sleep.wakeTime }) else { return nil }
            result += HealthExportMapping.sleep(stages, bed: sleep.bedTime, wake: sleep.wakeTime, namespace: namespace, eligible: true)
            // The source includes explicit start and interval for these observations. Check the
            // projection against the parsed source before exporting its timed series.
            guard let expected = expectedSleeps.first(where: { $0.sourceFileID == sleep.sourceFileID && $0.bedTime == sleep.bedTime }),
                  sleep.hrStart == expected.hrStart, sleep.hrIntervalSeconds == expected.hrIntervalSeconds,
                  sleep.hrValues.map(Int.init) == expected.hrValues,
                  sleep.spo2Start == expected.spo2Start, sleep.spo2IntervalSeconds == expected.spo2IntervalSeconds,
                  sleep.spo2Values.map(Int.init) == expected.spo2Values else { return nil }
            for (kind, start, interval, values) in [
                (HealthExportKind.heartRate, sleep.hrStart, sleep.hrIntervalSeconds, sleep.hrValues),
                (.oxygen, sleep.spo2Start, sleep.spo2IntervalSeconds, sleep.spo2Values)
            ] {
                guard let start, interval > 0 else { continue }
                var occupied = Set(result.filter { $0.kind == kind }.map { Int64(floor($0.start.timeIntervalSince1970 / 60)) })
                for (index, byte) in values.enumerated() {
                    let time = start.addingTimeInterval(TimeInterval(index * interval))
                    let value = Int(byte)
                    let valid = kind == .heartRate ? ValidRange.hr(value) != nil : ValidRange.spo2(value) != nil
                    let slot = Int64(floor(time.timeIntervalSince1970 / 60))
                    guard valid, time >= sleep.bedTime, time < sleep.wakeTime, occupied.insert(slot).inserted else { continue }
                    result.append(.init(namespace: namespace, kind: kind, start: time, end: time, value: value))
                }
            }
        }
        // Prefer historical records to live observations within the same minute. Otherwise retain
        // every independently timestamped live observation, deduplicating subsecond repeats.
        let live = try context.fetch(FetchDescriptor<Sample>(predicate: #Predicate { $0.bandID == id && $0.kind == "live" })).sorted { $0.ts < $1.ts }
        let historicalSlots = Set(result.filter { $0.kind == .heartRate }.map { Int64(floor($0.start.timeIntervalSince1970 / 60)) })
        var liveIDs = Set<String>()
        for observation in live where ValidRange.hr(observation.heartRate) != nil {
            let slot = Int64(floor(observation.ts.timeIntervalSince1970 / 60))
            guard !historicalSlots.contains(slot) else { continue }
            let sample = HealthExportSample(namespace: namespace, kind: .heartRate, start: observation.ts, end: observation.ts, value: observation.heartRate)
            if liveIDs.insert(sample.identifier).inserted { result.append(sample) }
        }
        let sleepSamples = result.filter { $0.kind == .sleep }.sorted { $0.start < $1.start }
        for index in sleepSamples.indices.dropFirst() where sleepSamples[index].start < sleepSamples[index - 1].end { return nil }
        guard Set(result.map(\.identifier)).count == result.count else { return nil }
        return result
    }

    /// A bad or unavailable historical file must not block independent live observations and a
    /// separately CRC-checked daily summary. No stale deletions are inferred from this fallback.
    private func fallback(bandID id: UUID, namespace: UUID, blobs: [ActivityBlob],
                          sources: [String: Source], entries: [HealthExportEntry]) throws -> [HealthExportSample] {
        let rows = try context.fetch(FetchDescriptor<DaySummary>(predicate: #Predicate { $0.bandID == id }))
        var result: [HealthExportSample] = []
        for group in Dictionary(grouping: rows, by: { $0.dayIndex }).values {
            guard let row = group.max(by: { $0.updatedAt < $1.updatedAt }),
                  let blob = blobs.first(where: { $0.fileID == row.sourceFileID }),
                  let d = sources[blob.fileID]?.summary, d == row.draft else { continue }
            let start = d.day.start(offsetMinutes: d.tzOffsetMinutes)
            let end = min(start.addingTimeInterval(86_400), blob.fetchedAt)
            guard end > start else { continue }
            if let value = d.steps, value > 0 {
                let sample = HealthExportSample(namespace: namespace, kind: .steps, start: start, end: end, value: value)
                let dayEnd = start.addingTimeInterval(86_400)
                let overlaps = entries.contains { entry in
                    guard entry.kind == .steps, entry.identifier != sample.identifier,
                          entry.state != .deleted, entry.state != .suppressed else { return false }
                    let parts = entry.fingerprint.split(separator: ":")
                    guard parts.count >= 2, let endSeconds = Int64(parts[1]) else {
                        return entry.start >= start.addingTimeInterval(-86_400) && entry.start < dayEnd
                    }
                    return entry.start < dayEnd && Date(timeIntervalSince1970: TimeInterval(endSeconds)) > start
                }
                if !overlaps { result.append(sample) }
            }
            if let value = ValidRange.hr(d.hrResting) {
                result.append(.init(namespace: namespace, kind: .restingHeartRate, start: start, end: end, value: value))
            }
        }
        // A broken sleep or summary file need not block separately verified minute files.
        // In fallback mode we do not remove existing entries, so withhold a minute when an
        // existing daily total or another timed reading already covers it.
        let minuteBlobs = blobs.filter { $0.type == 0 && $0.subtype == 0 && $0.detailType == 0 }
        var partsByDay: [DayKey: [MinuteDayDraft]] = [:]
        let minuteSources = minuteBlobs.compactMap { sources[$0.fileID] }
        for source in minuteSources {
            for part in source.minuteParts { partsByDay[part.day, default: []].append(part) }
        }
        if !minuteBlobs.isEmpty, minuteSources.count == minuteBlobs.count {
            let days = try context.fetch(FetchDescriptor<MinuteDay>(predicate: #Predicate { $0.bandID == id }))
            let occupied = Dictionary(grouping: entries.filter { ($0.kind == .heartRate || $0.kind == .oxygen) && $0.state != .deleted && $0.state != .suppressed },
                                      by: { "\($0.kind.rawValue):\(Int64(floor($0.start.timeIntervalSince1970 / 60)))" })
            for day in days {
                guard let parts = partsByDay[day.dayKey], let rebuilt = IngestMapper.mergeMinuteParts(parts),
                      rebuilt.series == day.series, Set(rebuilt.sourceFileIDs) == Set(day.sourceFileIDs),
                      parts.allSatisfy({ $0.series.tzOffsetMinutes == day.tzOffsetMinutes }) else { continue }
                guard day.sourceFileIDs.allSatisfy({ sources[$0]?.minuteAligned == true }) else { continue }
                let start = day.dayKey.start(offsetMinutes: day.tzOffsetMinutes), end = start.addingTimeInterval(86_400)
                let summaryPresent = result.contains { $0.kind == .steps && $0.start == start }
                    || entries.contains { entry in
                        guard entry.kind == .steps, entry.start >= start.addingTimeInterval(-86_400), entry.start < end,
                              entry.state != .deleted, entry.state != .suppressed else { return false }
                        let pieces = entry.fingerprint.split(separator: ":")
                        guard pieces.count >= 2, let first = Int64(pieces[0]), let last = Int64(pieces[1]) else { return true }
                        return last - first != 60 && Date(timeIntervalSince1970: TimeInterval(last)) > start
                    }
                for sample in HealthExportMapping.minutes(day.series, namespace: namespace, eligible: true) {
                    if sample.kind == .steps && summaryPresent { continue }
                    if sample.kind == .heartRate || sample.kind == .oxygen {
                        let slot = Int64(floor(sample.start.timeIntervalSince1970 / 60))
                        let collision = (occupied["\(sample.kind.rawValue):\(slot)"] ?? []).contains { $0.identifier != sample.identifier }
                        if collision { continue }
                    }
                    result.append(sample)
                }
            }
        }
        for kind in [HealthExportKind.heartRate, .oxygen] {
            var occupied = Set(entries.filter { $0.kind == kind && $0.state != .deleted && $0.state != .suppressed }
                .map { Int64(floor($0.start.timeIntervalSince1970 / 60)) } + result.filter { $0.kind == kind }.map { Int64(floor($0.start.timeIntervalSince1970 / 60)) })
            for source in sources.values {
                for reading in source.manual {
                    let valid = kind == .heartRate ? (reading.kind == "heart_rate" && ValidRange.hr(reading.value) != nil)
                        : (reading.kind == "spo2" && ValidRange.spo2(reading.value) != nil)
                    let slot = Int64(floor(reading.ts.timeIntervalSince1970 / 60))
                    guard valid, occupied.insert(slot).inserted else { continue }
                    result.append(.init(namespace: namespace, kind: kind, start: reading.ts, end: reading.ts, value: reading.value))
                }
            }
        }
        let live = try context.fetch(FetchDescriptor<Sample>(predicate: #Predicate { $0.bandID == id && $0.kind == "live" }))
        let occupied = Set(entries.filter { $0.kind == .heartRate && $0.state != .deleted && $0.state != .suppressed }.map { Int64(floor($0.start.timeIntervalSince1970 / 60)) } + result.filter { $0.kind == .heartRate }.map { Int64(floor($0.start.timeIntervalSince1970 / 60)) })
        var liveIDs = Set<String>()
        for observation in live.sorted(by: { $0.ts < $1.ts }) where ValidRange.hr(observation.heartRate) != nil {
            let slot = Int64(floor(observation.ts.timeIntervalSince1970 / 60))
            guard !occupied.contains(slot) else { continue }
            let sample = HealthExportSample(namespace: namespace, kind: .heartRate, start: observation.ts, end: observation.ts, value: observation.heartRate)
            if liveIDs.insert(sample.identifier).inserted { result.append(sample) }
        }
        return result
    }
}
