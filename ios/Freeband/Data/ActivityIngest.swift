import Foundation
import SwiftData

/// What one ingest pass did: the days it touched per band (for DailyRollup) and what the
/// calibration report needs.
struct IngestSummary {
    /// Every local day fed by the parsed files, per band.
    var touchedDays: [UUID: Set<DayKey>] = [:]
    var files: [CalibrationReport.FileEntry] = []
    var minuteFiles: [Calibration.MinuteFile] = []
    /// Merged minute days that were rebuilt, per band.
    var minuteDays: [UUID: [MinuteDayDraft]] = [:]
    var summaries: [DaySummaryDraft] = []
    var sleeps: [SleepDraft] = []
    var fetchedAt: [String: Date] = [:]
    /// A file changed while it was being parsed; run again.
    var stale = false

    var isEmpty: Bool { files.isEmpty }

    var earliestTouched: [UUID: DayKey] {
        touchedDays.compactMapValues { $0.min() }
    }

    mutating func absorb(_ other: IngestSummary) {
        for (band, days) in other.touchedDays { touchedDays[band, default: []].formUnion(days) }
        files += other.files
        minuteFiles += other.minuteFiles
        for (band, days) in other.minuteDays {
            var kept = (minuteDays[band] ?? []).filter { d in !days.contains { $0.day == d.day } }
            kept += days
            minuteDays[band] = kept
        }
        summaries += other.summaries
        sleeps += other.sleeps
        fetchedAt.merge(other.fetchedAt) { _, new in new }
        stale = stale || other.stale
    }
}

/// Parses stored activity files into the derived models (plan section 6, "Çözme").
///
/// Runs on the main context: the volumes are small (a sync brings a handful of files) and it
/// keeps @Query views in step without cross-context merging. The parsing itself, the only heavy
/// part, runs detached on plain values.
///
/// Idempotent: for each file, rows with its sourceFileID are deleted and inserted again. Minute
/// days, which merge several files, are rebuilt from every file that feeds them.
@MainActor
final class ActivityIngest {
    /// Bump when ActivityFiles.swift or IngestMapper changes what a file yields; stored files with
    /// an older version are parsed again at launch.
    static let parserVersion = 2

    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: entry points

    /// Files never parsed by the current parser: new, replaced (today's files grow) or parsed by
    /// an older version.
    func pendingBlobs(bandID: UUID? = nil) -> [ActivityBlob] {
        let current = Self.parserVersion
        let all = (try? context.fetch(FetchDescriptor<ActivityBlob>(predicate: #Predicate { $0.parserVersion < current },
                                                                    sortBy: [SortDescriptor(\.ts)]))) ?? []
        let stale = (try? context.fetch(FetchDescriptor<ActivityBlob>(predicate: #Predicate { $0.parsedAt == nil },
                                                                      sortBy: [SortDescriptor(\.ts)]))) ?? []
        var seen = Set<PersistentIdentifier>()
        return (all + stale).filter { blob in
            guard bandID == nil || blob.bandID == bandID, !seen.contains(blob.persistentModelID) else { return false }
            seen.insert(blob.persistentModelID)
            return true
        }
    }

    func ingestPending(bandID: UUID? = nil) async -> IngestSummary {
        var total = IngestSummary()
        for _ in 0 ..< 3 {  // a file replaced mid-parse is picked up by the next round
            let blobs = pendingBlobs(bandID: bandID)
            guard !blobs.isEmpty else { break }
            let summary = await ingest(blobs)
            total.absorb(summary)
            guard summary.stale else { break }
        }
        return total
    }

    /// Moves each stored file that carries another id to that id (`refilePlan`), or drops it when
    /// that id holds its own bytes. Whatever sat under the old id is no longer stored, so the next
    /// sync fetches it from the band's past list. A moved file counts as fetched from today, so it
    /// is fetched once more too, now under the id it carries. Returns how many files changed.
    @discardableResult
    func refileMisfiled() -> Int {
        let blobs = (try? context.fetch(FetchDescriptor<ActivityBlob>())) ?? []
        var changed = 0
        for (bandID, files) in Dictionary(grouping: blobs, by: \.bandID) {
            let plan = refilePlan(files.map { ($0.fileID, $0.data) })
            for blob in files {
                guard let action = plan[blob.fileID] else { continue }
                deleteRows(bandID: bandID, sourceFileID: blob.fileID)
                switch action {
                case .drop:
                    context.delete(blob)
                case .move(let id):
                    blob.fileID = id.hex
                    blob.ts = id.ts
                    blob.type = Int(id.type)
                    blob.subtype = Int(id.subtype)
                    blob.detailType = Int(id.detailType)
                    blob.version = Int(id.version)
                    blob.fetchedFromToday = true
                    blob.parserVersion = 0
                    blob.parsedAt = nil
                    blob.parseStatus = ParseStatus.pending.rawValue
                }
                changed += 1
            }
        }
        if changed > 0 { try? context.save() }
        return changed
    }

    /// Drops every derived row (and scores), marks every file unparsed, parses them all again.
    func reparseAll() async -> IngestSummary {
        refileMisfiled()
        Self.deleteDerived(context: context, bandID: nil, includingScores: true)
        let blobs = (try? context.fetch(FetchDescriptor<ActivityBlob>())) ?? []
        for blob in blobs {
            blob.parserVersion = 0
            blob.parsedAt = nil
            blob.parseStatus = ParseStatus.pending.rawValue
        }
        try? context.save()
        return await ingestPending()
    }

    // MARK: ingest

    private struct Job: Sendable {
        let bandID: UUID
        let hex: String
        let fetchedAt: Date
        let data: Data
    }

    private struct Parsed: Sendable {
        let result: ActivityParseResult
        let output: IngestOutput
    }

    func ingest(_ blobs: [ActivityBlob]) async -> IngestSummary {
        guard !blobs.isEmpty else { return IngestSummary() }
        let jobs = blobs.map { Job(bandID: $0.bandID, hex: $0.fileID, fetchedAt: $0.fetchedAt, data: $0.data) }
        let parsed: [Parsed] = await Task.detached(priority: .utility) {
            jobs.map { job in
                let result = ActivityParser.parse(job.data)
                return Parsed(result: result, output: IngestMapper.map(result, fileHex: job.hex))
            }
        }.value

        var summary = IngestSummary()
        var minuteParts: [UUID: [DayKey: [MinuteDayDraft]]] = [:]
        var minuteHexes: [UUID: Set<String>] = [:]
        var sleepBands = Set<UUID>()

        for (job, p) in zip(jobs, parsed) {
            // The blob may have been replaced or removed while parsing ran.
            guard let blob = blob(job.bandID, job.hex) else { continue }
            guard blob.fetchedAt == job.fetchedAt else {
                summary.stale = true
                continue
            }
            let out = p.output
            deleteRows(bandID: job.bandID, sourceFileID: job.hex)
            if let s = out.summary { context.insert(DaySummary(bandID: job.bandID, draft: s)) }
            for s in out.sleeps {
                context.insert(SleepRecord(bandID: job.bandID, draft: s))
                if s.rrBeats > 0 { context.insert(SleepRR(bandID: job.bandID, draft: s)) }
                sleepBands.insert(job.bandID)
            }
            for m in out.manual { context.insert(ManualReading(bandID: job.bandID, draft: m)) }
            if out.kind == .dailyDetails {
                minuteHexes[job.bandID, default: []].insert(job.hex)
                for part in out.minuteParts { minuteParts[job.bandID, default: [:]][part.day, default: []].append(part) }
            }

            blob.parserVersion = Self.parserVersion
            blob.parseStatus = out.status.rawValue
            blob.parsedAt = Date()
            blob.parseNote = out.note

            summary.touchedDays[job.bandID, default: []].formUnion(out.touchedDays)
            summary.files.append(Calibration.fileEntry(p.result, output: out, size: job.data.count, fetchedAt: job.fetchedAt))
            if let id = p.result.fileID, let records = out.minuteRecords {
                summary.minuteFiles.append(Calibration.MinuteFile(fileID: id, records: records, fetchedAt: job.fetchedAt))
            }
            if let s = out.summary { summary.summaries.append(s) }
            summary.sleeps += out.sleeps
            summary.fetchedAt[job.hex] = job.fetchedAt
        }
        // Settle the per-file deletes and inserts before the cross-file passes fetch again.
        try? context.save()

        for (band, hexes) in minuteHexes {
            let rebuilt = rebuildMinuteDays(bandID: band, newParts: minuteParts[band] ?? [:], batch: hexes)
            summary.minuteDays[band] = rebuilt.drafts
            summary.touchedDays[band, default: []].formUnion(rebuilt.days)
        }
        for band in sleepBands { reconcileSleeps(bandID: band) }
        try? context.save()
        return summary
    }

    // MARK: rows

    private func blob(_ bandID: UUID, _ hex: String) -> ActivityBlob? {
        try? context.fetch(FetchDescriptor<ActivityBlob>(predicate: #Predicate { $0.bandID == bandID && $0.fileID == hex })).first
    }

    /// Rows that come from exactly one file.
    private func deleteRows(bandID: UUID, sourceFileID hex: String) {
        try? context.delete(model: DaySummary.self, where: #Predicate { $0.bandID == bandID && $0.sourceFileID == hex })
        try? context.delete(model: SleepRecord.self, where: #Predicate { $0.bandID == bandID && $0.sourceFileID == hex })
        try? context.delete(model: SleepRR.self, where: #Predicate { $0.bandID == bandID && $0.sourceFileID == hex })
        try? context.delete(model: ManualReading.self, where: #Predicate { $0.bandID == bandID && $0.sourceFileID == hex })
    }

    /// Rebuilds every minute day a file of this batch feeds (now or before): the new parts plus
    /// the parts of the day's other source files, parsed again from the store.
    private func rebuildMinuteDays(bandID: UUID, newParts: [DayKey: [MinuteDayDraft]], batch: Set<String>)
        -> (drafts: [MinuteDayDraft], days: Set<DayKey>) {
        let rows = (try? context.fetch(FetchDescriptor<MinuteDay>(predicate: #Predicate { $0.bandID == bandID }))) ?? []
        var byDay: [Int: [MinuteDay]] = [:]
        for row in rows { byDay[row.dayIndex, default: []].append(row) }

        var days = Set(newParts.keys)
        for row in rows where row.sourceFileIDs.contains(where: batch.contains) { days.insert(row.dayKey) }

        var cache: [String: [MinuteDayDraft]] = [:]
        func parts(of hex: String) -> [MinuteDayDraft] {
            if let hit = cache[hex] { return hit }
            guard let blob = blob(bandID, hex) else {
                cache[hex] = []
                return []
            }
            let found = IngestMapper.map(ActivityParser.parse(blob.data), fileHex: hex).minuteParts
            cache[hex] = found
            return found
        }

        var drafts: [MinuteDayDraft] = []
        for day in days.sorted() {
            let existing = byDay[day.index] ?? []
            var all = newParts[day] ?? []
            let others = Set(existing.flatMap(\.sourceFileIDs)).subtracting(batch)
            for hex in others.sorted() { all += parts(of: hex).filter { $0.day == day } }
            let merged = IngestMapper.mergeMinuteParts(all)
            for (i, row) in existing.enumerated() {
                if i == 0, let merged {
                    row.update(from: merged)
                } else {
                    context.delete(row)
                }
            }
            if existing.isEmpty, let merged { context.insert(MinuteDay(bandID: bandID, draft: merged)) }
            if let merged { drafts.append(merged) }
        }
        return (drafts, days)
    }

    /// Marks, for every set of records that describe the same sleep, the one analytics uses.
    private func reconcileSleeps(bandID: UUID) {
        let records = (try? context.fetch(FetchDescriptor<SleepRecord>(predicate: #Predicate { $0.bandID == bandID },
                                                                       sortBy: [SortDescriptor(\.bedTime)]))) ?? []
        let flags = IngestMapper.primaryFlags(records.map { $0.draft() })
        for (record, flag) in zip(records, flags) where record.isPrimary != flag { record.isPrimary = flag }
    }

    // MARK: wiping

    /// Deletes the derived rows of one band (or all bands), keeping the raw files.
    static func deleteDerived(context: ModelContext, bandID: UUID?, includingScores: Bool) {
        if let id = bandID {
            try? context.delete(model: MinuteDay.self, where: #Predicate { $0.bandID == id })
            try? context.delete(model: DaySummary.self, where: #Predicate { $0.bandID == id })
            try? context.delete(model: SleepRecord.self, where: #Predicate { $0.bandID == id })
            try? context.delete(model: SleepRR.self, where: #Predicate { $0.bandID == id })
            try? context.delete(model: ManualReading.self, where: #Predicate { $0.bandID == id })
            if includingScores { try? context.delete(model: DailyScore.self, where: #Predicate { $0.bandID == id }) }
        } else {
            try? context.delete(model: MinuteDay.self)
            try? context.delete(model: DaySummary.self)
            try? context.delete(model: SleepRecord.self)
            try? context.delete(model: SleepRR.self)
            try? context.delete(model: ManualReading.self)
            if includingScores { try? context.delete(model: DailyScore.self) }
        }
    }
}
