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
            let missingPermissions = HealthExportKind.allCases.filter { writer.status(for: $0) != .sharingAuthorized }
            var withheld = !missingPermissions.isEmpty
            var incompleteSource = false
            var sourceProblems = Set<String>()
            var exportableCount = 0
            var identityConflict = false
            var processed = 0
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
                let rows = try context.fetch(FetchDescriptor<HealthExportLedgerRow>()).filter { $0.namespace == namespace }
                let entries = rows.compactMap(\.entry)
                guard entries.count == rows.count else { throw ExportError.invalidLedger }
                let complete = try snapshot(band: band, namespace: namespace)
                if complete == nil { withheld = true; incompleteSource = true }
                let samples = try complete ?? fallback(band: band, namespace: namespace, entries: entries)
                let cutoff = try settings().suppressBefore ?? .distantPast
                let eligible = samples.filter { $0.start >= cutoff }
                exportableCount += eligible.count
                let sources = try context.fetch(FetchDescriptor<ActivityBlob>()).filter { $0.bandID == band.id && $0.type == 0 }
                if complete == nil {
                    for blob in sources where blob.parsedAt == nil || blob.parserVersion != ActivityIngest.parserVersion || blob.parseStatus != ParseStatus.parsed.rawValue {
                        switch (blob.subtype, blob.detailType) {
                        case (0, 0): sourceProblems.insert(String(localized: "minute data"))
                        case (0, 1): sourceProblems.insert(String(localized: "daily summary"))
                        case (3, _), (8, _): sourceProblems.insert(String(localized: "sleep"))
                        case (6, _): sourceProblems.insert(String(localized: "manual readings"))
                        default: break
                        }
                    }
                    if sourceProblems.isEmpty { sourceProblems.insert(String(localized: "ambiguous minute or sleep data")) }
                }
                let hasMinutes = sources.contains { $0.subtype == 0 && $0.detailType == 0 }
                let hasSummary = sources.contains { $0.subtype == 0 && $0.detailType == 1 }
                let hasSleep = sources.contains { $0.subtype == 3 || $0.subtype == 8 }
                let hasManual = sources.contains { $0.subtype == 6 }
                let authoritative: [HealthExportKind] = complete == nil ? [] : HealthExportKind.allCases.filter {
                    switch $0 {
                    case .steps: return hasMinutes || hasSummary
                    case .heartRate: return hasMinutes || hasSleep || hasManual
                    case .oxygen: return hasMinutes || hasSleep || hasManual
                    case .restingHeartRate: return hasSummary
                    case .sleep: return hasSleep
                    }
                }
                let scopes = authoritative.map { HealthExportScope(namespace: namespace, kind: $0,
                                                                                start: cutoff, end: .distantFuture,
                                                                                authoritative: true) }
                let plan = try HealthExportPlanner.reconcile(samples: eligible, entries: entries, scopes: scopes)
                let planned = Dictionary(uniqueKeysWithValues: plan.entries.map { ($0.identifier, $0) })
                var rowByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.identifier, $0) })
                // Each operation is persisted before the HealthKit call. Never enqueue thousands at once.
                // Remove obsolete overlapping records before writing replacements.
                let ordered = plan.changes.filter { if case .delete = $0 { return true }; return false }
                    + plan.changes.filter { if case .save = $0 { return true }; return false }
                for change in ordered {
                    guard current == generation, enabled, available, !Task.isCancelled else { return }
                    if processed == 100 {
                        processed = 0
                        await Task.yield()
                        guard current == generation, enabled, available, !Task.isCancelled else { return }
                    }
                    let id: String; let kind: HealthExportKind
                    switch change { case .save(let sample, _): id = sample.identifier; kind = sample.kind
                                    case .delete(let identifier, let k): id = identifier; kind = k }
                    guard !failedKinds.contains(kind) else { continue }
                    guard writer.status(for: kind) == .sharingAuthorized, let entry = planned[id] else { withheld = true; continue }
                    let row: HealthExportLedgerRow
                    if let existing = rowByID[id] { row = existing; row.update(entry) }
                    else { row = HealthExportLedgerRow(entry); context.insert(row); rowByID[id] = row }
                    try context.save()
                    do {
                        switch change {
                        case .save(let sample, let version): try await writer.save(sample, version: version)
                        case .delete(let identifier, let kind): try await writer.delete(identifier: identifier, kind: kind)
                        }
                    } catch {
                        // In particular, do not save a daily/minute replacement if its deletion
                        // failed; continue with independent types and retain this pending entry.
                        failedKinds.insert(kind); withheld = true; continue
                    }
                    guard current == generation, enabled, available else { return }
                    switch change {
                    case .save: row.state = HealthExportEntry.State.saved.rawValue; savedCount += 1; writtenByKind[kind, default: 0] += 1
                    case .delete: row.state = HealthExportEntry.State.deleted.rawValue; deletedCount += 1
                    }
                    try context.save()
                    processed += 1
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
            if savedCount > 0 {
                let steps = writtenByKind[.steps, default: 0], heart = writtenByKind[.heartRate, default: 0]
                let resting = writtenByKind[.restingHeartRate, default: 0], oxygen = writtenByKind[.oxygen, default: 0]
                let sleep = writtenByKind[.sleep, default: 0]
                status = (status ?? "") + "\n" + String(localized: "Written: steps \(steps), heart rate \(heart), resting heart rate \(resting), oxygen \(oxygen), sleep \(sleep).")
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
            (($0.subtype == 0 && ($0.detailType == 0 || $0.detailType == 1)) || $0.subtype == 3 || $0.subtype == 6 || $0.subtype == 8) }

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
        // A summary is one cumulative interval, never an additional source of minute steps.
        // Validate the persisted projection against the CRC-checked source before using it.
        let summaries = try context.fetch(FetchDescriptor<DaySummary>()).filter { $0.bandID == id }
        let expectedSummaryIDs = Set(parsed.values.compactMap { IngestMapper.map($0).summary?.sourceFileID })
        guard Set(summaries.map(\.sourceFileID)) == expectedSummaryIDs,
              Set(summaries.map(\.sourceFileID)).count == summaries.count else { return nil }
        let grouped = Dictionary(grouping: summaries, by: { $0.dayIndex })
        for summariesForDay in grouped.values {
            guard let summary = summariesForDay.max(by: { $0.updatedAt < $1.updatedAt }) else { continue }
            guard let p = parsed[summary.sourceFileID],
                  let expected = IngestMapper.map(p, fileHex: summary.sourceFileID).summary,
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
            let manual = parsed.values.flatMap { IngestMapper.map($0).manual }.sorted { $0.ts < $1.ts }
            for reading in manual {
                let valid = kind == .heartRate ? (reading.kind == "heart_rate" && ValidRange.hr(reading.value) != nil)
                    : (reading.kind == "spo2" && ValidRange.spo2(reading.value) != nil)
                let slot = Int64(floor(reading.ts.timeIntervalSince1970 / 60))
                guard valid, occupied.insert(slot).inserted else { continue }
                result.append(.init(namespace: namespace, kind: kind, start: reading.ts, end: reading.ts, value: reading.value))
            }
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
        let live = try context.fetch(FetchDescriptor<Sample>()).filter { $0.bandID == id && $0.kind == "live" }.sorted { $0.ts < $1.ts }
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
    private func fallback(band: Band, namespace: UUID, entries: [HealthExportEntry]) throws -> [HealthExportSample] {
        let id = band.id
        let blobs = try context.fetch(FetchDescriptor<ActivityBlob>()).filter { $0.bandID == id }
        let rows = try context.fetch(FetchDescriptor<DaySummary>()).filter { $0.bandID == id }
        var result: [HealthExportSample] = []
        for group in Dictionary(grouping: rows, by: { $0.dayIndex }).values {
            guard let row = group.max(by: { $0.updatedAt < $1.updatedAt }),
                  let blob = blobs.first(where: { $0.fileID == row.sourceFileID }),
                  blob.parsedAt != nil, blob.parserVersion == ActivityIngest.parserVersion,
                  blob.parseStatus == ParseStatus.parsed.rawValue else { continue }
            let p = ActivityParser.parse(blob.data)
            guard p.fileID?.hex == blob.fileID, IngestMapper.status(of: p) == .parsed,
                  let d = IngestMapper.map(p).summary, d == row.draft else { continue }
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
        var minuteParses: [String: ActivityParseResult] = [:]
        var validMinuteSources = !minuteBlobs.isEmpty
        for blob in minuteBlobs {
            let parsed = ActivityParser.parse(blob.data)
            guard blob.parsedAt != nil, blob.parserVersion == ActivityIngest.parserVersion,
                  blob.parseStatus == ParseStatus.parsed.rawValue, parsed.fileID?.hex == blob.fileID,
                  IngestMapper.status(of: parsed) == .parsed else { validMinuteSources = false; continue }
            minuteParses[blob.fileID] = parsed
            for part in IngestMapper.map(parsed).minuteParts { partsByDay[part.day, default: []].append(part) }
        }
        if validMinuteSources {
            let days = try context.fetch(FetchDescriptor<MinuteDay>()).filter { $0.bandID == id }
            let occupied = Dictionary(grouping: entries.filter { ($0.kind == .heartRate || $0.kind == .oxygen) && $0.state != .deleted && $0.state != .suppressed },
                                      by: { "\($0.kind.rawValue):\(Int64(floor($0.start.timeIntervalSince1970 / 60)))" })
            for day in days {
                guard let parts = partsByDay[day.dayKey], let rebuilt = IngestMapper.mergeMinuteParts(parts),
                      rebuilt.series == day.series, Set(rebuilt.sourceFileIDs) == Set(day.sourceFileIDs),
                      parts.allSatisfy({ $0.series.tzOffsetMinutes == day.tzOffsetMinutes }) else { continue }
                let aligned = day.sourceFileIDs.allSatisfy { hex in
                    guard let parsed = minuteParses[hex], let file = parsed.fileID, case let .dailyDetails(details) = parsed.payload else { return false }
                    return details.records.filter { DayKey(date: $0.ts, offsetMinutes: file.utcOffsetMinutes) == day.dayKey }.allSatisfy { record in
                        guard let minute = day.dayKey.minute(of: record.ts, offsetMinutes: file.utcOffsetMinutes) else { return false }
                        return record.ts == day.dayKey.start(offsetMinutes: file.utcOffsetMinutes).addingTimeInterval(TimeInterval(minute * 60))
                    }
                }
                guard aligned else { continue }
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
            for blob in blobs where blob.type == 0 && blob.subtype == 6 && blob.parsedAt != nil &&
                blob.parserVersion == ActivityIngest.parserVersion && blob.parseStatus == ParseStatus.parsed.rawValue {
                let parsed = ActivityParser.parse(blob.data)
                guard parsed.fileID?.hex == blob.fileID, IngestMapper.status(of: parsed) == .parsed else { continue }
                for reading in IngestMapper.map(parsed).manual {
                    let valid = kind == .heartRate ? (reading.kind == "heart_rate" && ValidRange.hr(reading.value) != nil)
                        : (reading.kind == "spo2" && ValidRange.spo2(reading.value) != nil)
                    let slot = Int64(floor(reading.ts.timeIntervalSince1970 / 60))
                    guard valid, occupied.insert(slot).inserted else { continue }
                    result.append(.init(namespace: namespace, kind: kind, start: reading.ts, end: reading.ts, value: reading.value))
                }
            }
        }
        let live = try context.fetch(FetchDescriptor<Sample>()).filter { $0.bandID == id && $0.kind == "live" }
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
