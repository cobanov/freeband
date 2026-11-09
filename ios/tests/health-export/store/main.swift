import Foundation
import HealthKit
import SwiftData

// From the repository root, on macOS with Xcode:
// swiftc -parse-as-library -D DEBUG ios/tests/ingest/store/stub.swift ios/Freeband/Band/ActivityFiles.swift \
//   ios/Freeband/Analytics/*.swift ios/Freeband/Data/*.swift ios/Freeband/App/DemoData.swift \
//   ios/Freeband/Integrations/HealthExportPlan.swift ios/Freeband/Integrations/HealthExportMapping.swift \
//   ios/Freeband/Integrations/HealthKitWriter.swift ios/Freeband/Integrations/HealthExportService.swift \
//   ios/tests/health-export/store/main.swift -o /tmp/health-export-store && /tmp/health-export-store

final class FakeWriter: HealthKitWriting {
    var available = true
    var failNext = false
    var failNextDelete = false
    var saves: [(String, Int)] = []
    var deletes: [String] = []
    var allowed: Set<HealthExportKind> = Set(HealthExportKind.allCases)
    func status(for kind: HealthExportKind) -> HKAuthorizationStatus { allowed.contains(kind) ? .sharingAuthorized : .sharingDenied }
    func requestAuthorization() async throws { }
    func save(_ sample: HealthExportSample, version: Int) async throws {
        saves.append((sample.identifier, version))
        if failNext { failNext = false; throw Failure.injected }
    }
    func delete(identifier: String, kind: HealthExportKind) async throws {
        deletes.append(identifier)
        if failNextDelete { failNextDelete = false; throw Failure.injected }
    }
    enum Failure: Error { case injected }
}

@main struct Test {
    @MainActor static func settle(_ service: HealthExportService) async {
        try? await Task.sleep(for: .milliseconds(50))
        while service.busy { try? await Task.sleep(for: .milliseconds(10)) }
    }
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    @MainActor static func main() async throws {
        let schema = Schema([Band.self, Sample.self, Webhook.self, ActivityBlob.self, MinuteDay.self,
                             DaySummary.self, SleepRecord.self, SleepRR.self, ManualReading.self, DailyScore.self,
                             HealthExportLedgerRow.self, HealthExportSettings.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../activity/fixtures/synthetic.json").standardized
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        let cases = root["cases"] as! [[String: Any]]
        let fixture = cases.first { ($0["name"] as? String)?.contains("daily details v4, every group") == true }!
        let hex = fixture["hex"] as! String
        var bytes: [UInt8] = stride(from: 0, to: hex.count, by: 2).map { offset in
            let i = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[i..<hex.index(i, offsetBy: 2)], radix: 16)!
        }
        if fixture["has_crc"] as? Bool == false {
            let crc = ActivityCRC32.checksum(bytes)
            bytes += [UInt8(truncatingIfNeeded: crc), UInt8(truncatingIfNeeded: crc >> 8),
                      UInt8(truncatingIfNeeded: crc >> 16), UInt8(truncatingIfNeeded: crc >> 24)]
        }
        let band = Band(name: "Band 10 Pro", mac: "00:11:22:33:44:55")
        let id = ActivityFileID(Data(bytes.prefix(7)))!
        context.insert(band)
        let blob = ActivityBlob(bandID: band.id, id: id, data: Data(bytes))
        context.insert(blob); try context.save()
        _ = await ActivityIngest(context: context).ingestPending()
        check(blob.parseStatus == ParseStatus.parsed.rawValue, "fixture must be authoritative")
        let fake = FakeWriter(); fake.failNext = true
        let service = HealthExportService(context: context, demo: false, writer: fake)
        await service.enable(); await settle(service)
        let first = fake.saves.first
        check(first != nil, "an eligible sample is attempted")
        let pending = try context.fetch(FetchDescriptor<HealthExportLedgerRow>())
        check(pending.contains { $0.identifier == first!.0 && $0.state == "savePending" }, "failed save remains pending")
        check(pending.contains { $0.state == "saved" }, "independent types continue after a write failure")
        service.schedule(); await settle(service)
        check(fake.saves.filter { $0.0 == first!.0 && $0.1 == first!.1 }.count >= 2, "retry uses same identifier and version")
        check(band.healthExportNamespace != nil, "namespace persisted on band")
        let other = HealthExportService(context: context, demo: false, writer: fake)
        check(other.enabled, "enabled state survives service recreation")
        // Find a one-byte correction that removes a previously present step value while retaining
        // a fully parsed file, then exercise the same ingest path as a growing band file.
        guard case let .dailyDetails(original) = ActivityParser.parse(Data(bytes)).payload else { fatalError("fixture") }
        var corrected: [UInt8]?
        for i in 8 ..< bytes.count - 4 where corrected == nil {
            for replacement in [UInt8(0), UInt8(0xff)] where replacement != bytes[i] {
                var candidate = bytes; candidate[i] = replacement
                let crc = ActivityCRC32.checksum(Array(candidate.dropLast(4)))
                for byte in 0 ..< 4 { candidate[candidate.count - 4 + byte] = UInt8(truncatingIfNeeded: crc >> (8 * byte)) }
                let parsed = ActivityParser.parse(Data(candidate))
                guard IngestMapper.status(of: parsed) == .parsed,
                      case let .dailyDetails(next) = parsed.payload, next.records.count == original.records.count else { continue }
                if zip(original.records, next.records).contains(where: { ($0.0.steps ?? 0) > 0 && ($0.1.steps ?? 0) == 0 }) {
                    corrected = candidate; break
                }
            }
        }
        check(corrected != nil, "a valid source correction is available")
        blob.data = Data(corrected!); blob.parsedAt = nil; blob.parserVersion = 0; try context.save()
        _ = await ActivityIngest(context: context).ingestPending()
        fake.failNextDelete = true
        other.schedule(); await settle(other)
        let deletionAttempt = fake.deletes.last
        check(deletionAttempt != nil, "a removed source sample is targeted")
        let pendingDeletion = try context.fetch(FetchDescriptor<HealthExportLedgerRow>())
        check(pendingDeletion.contains { $0.identifier == deletionAttempt && $0.state == "deletePending" }, "failed deletion remains pending")
        other.schedule(); await settle(other)
        check(fake.deletes.last == deletionAttempt && fake.deletes.filter { $0 == deletionAttempt }.count >= 2,
              "interrupted deletion retries the same identifier")
        // Two source files with different offsets feeding one local day cannot be reconstructed
        // from MinuteDay's one-offset representation, so neither writes nor deletes are safe.
        var shifted = corrected!
        shifted[4] = shifted[4] &+ 1
        let shiftedCRC = ActivityCRC32.checksum(Array(shifted.dropLast(4)))
        for byte in 0 ..< 4 { shifted[shifted.count - 4 + byte] = UInt8(truncatingIfNeeded: shiftedCRC >> (8 * byte)) }
        let shiftedID = ActivityFileID(Data(shifted.prefix(7)))!
        context.insert(ActivityBlob(bandID: band.id, id: shiftedID, data: Data(shifted)))
        try context.save(); _ = await ActivityIngest(context: context).ingestPending()
        fake.saves.removeAll(); fake.deletes.removeAll()
        other.schedule(); await settle(other)
        check(fake.saves.isEmpty && fake.deletes.isEmpty, "mixed-offset local day is withheld")
        fake.allowed.remove(.heartRate); other.refresh()
        check(other.permissions[.heartRate] == .sharingDenied && other.permissions[.steps] == .sharingAuthorized,
              "write permissions remain per type")
        fake.saves.removeAll(); fake.deletes.removeAll()
        blob.parseStatus = ParseStatus.partial.rawValue; try context.save()
        other.schedule(); await settle(other)
        check(fake.saves.isEmpty && fake.deletes.isEmpty, "partial source cannot change Health")
        try other.suppressHistory()
        let suppressed = try context.fetch(FetchDescriptor<HealthExportLedgerRow>())
        check(suppressed.allSatisfy { $0.state == "suppressed" }, "local deletion retains tombstones")
        other.disable(); fake.saves.removeAll(); other.schedule(); await settle(other)
        check(fake.saves.isEmpty && !other.enabled, "disabled service does not export")
        let demo = HealthExportService(context: context, demo: true, writer: fake)
        check(!demo.available, "demo export unavailable at boundary")
        // A summary-only band and live observation must export without a minute file.
        let freshContainer = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let fresh = freshContainer.mainContext
        let summaryBand = Band(name: "Synthetic band", mac: "00:11:22:33:44:66")
        fresh.insert(summaryBand)
        let summaryFixture = cases.first { ($0["name"] as? String)?.contains("daily summary v5 ending") == true }!
        let summaryHex = summaryFixture["hex"] as! String
        var summaryBytes: [UInt8] = stride(from: 0, to: summaryHex.count, by: 2).map { offset in
            let i = summaryHex.index(summaryHex.startIndex, offsetBy: offset)
            return UInt8(summaryHex[i..<summaryHex.index(i, offsetBy: 2)], radix: 16)!
        }
        if summaryFixture["has_crc"] as? Bool == false {
            let crc = ActivityCRC32.checksum(summaryBytes)
            summaryBytes += [UInt8(truncatingIfNeeded: crc), UInt8(truncatingIfNeeded: crc >> 8),
                             UInt8(truncatingIfNeeded: crc >> 16), UInt8(truncatingIfNeeded: crc >> 24)]
        }
        let summaryID = ActivityFileID(Data(summaryBytes.prefix(7)))!
        fresh.insert(ActivityBlob(bandID: summaryBand.id, id: summaryID, data: Data(summaryBytes)))
        let liveBase = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 60) * 60 + 10)
        fresh.insert(Sample(bandID: summaryBand.id, draft: SampleDraft(kind: "live", ts: liveBase, heartRate: 80)))
        fresh.insert(Sample(bandID: summaryBand.id, draft: SampleDraft(kind: "live", ts: liveBase.addingTimeInterval(5), heartRate: 81)))
        try fresh.save()
        _ = await ActivityIngest(context: fresh).ingestPending()
        let summaryWriter = FakeWriter()
        let summaryService = HealthExportService(context: fresh, demo: false, writer: summaryWriter)
        await summaryService.enable(); await settle(summaryService)
        let exported = try fresh.fetch(FetchDescriptor<HealthExportLedgerRow>())
        check(exported.contains { $0.kind == "steps" && $0.state == "saved" }, "summary steps exported")
        check(exported.contains { $0.kind == "restingHeartRate" && $0.state == "saved" }, "band resting HR exported")
        check(exported.contains { $0.kind == "heartRate" && $0.state == "saved" }, "live HR exported")
        check(exported.filter { $0.kind == "heartRate" && $0.state == "saved" }.count == 2, "distinct live observations within a minute are retained")
        let count = summaryWriter.saves.count
        summaryService.schedule(); await settle(summaryService)
        check(summaryWriter.saves.count == count, "repeat sync is idempotent")
        check(summaryService.status?.contains("up to date") == true, "unchanged sync is reported accurately")
        // A corrupt historical file must not prevent a separately verified live observation.
        let badID = ActivityFileID(timestamp: summaryID.timestamp, tzQuarterHours: summaryID.tzQuarterHours,
                                   version: 4, type: 0, subtype: 0, detailType: 0)
        let bad = ActivityBlob(bandID: summaryBand.id, id: badID, data: Data([0]))
        bad.parseStatus = ParseStatus.error.rawValue; bad.parsedAt = Date(); bad.parserVersion = ActivityIngest.parserVersion
        fresh.insert(bad)
        fresh.insert(Sample(bandID: summaryBand.id, draft: SampleDraft(kind: "live", ts: Date().addingTimeInterval(-120), heartRate: 81)))
        try fresh.save()
        summaryWriter.saves.removeAll(); summaryWriter.deletes.removeAll()
        summaryService.schedule(); await settle(summaryService)
        check(summaryWriter.saves.contains { $0.0.contains(".heartRate.") }, "live data exports despite unrelated bad file")
        check(summaryWriter.deletes.isEmpty, "partial input never causes stale deletions")
        check(summaryService.status?.contains("Partial") == true, "partial input is reported")
        fresh.delete(bad); try fresh.save()
        let summaryEntry = exported.first { $0.kind == "steps" }!
        let summarySyncID = summaryEntry.identifier
        // Construct a complete synthetic minute file for the summary's local day. The first
        // minute has zero steps, so the old all-day sample must be removed before minute saves.
        let day = DayKey(date: summaryID.ts, offsetMinutes: summaryID.utcOffsetMinutes)
        let firstTime = UInt32(day.start(offsetMinutes: summaryID.utcOffsetMinutes).timeIntervalSince1970)
        let minuteID = ActivityFileID(timestamp: firstTime, tzQuarterHours: summaryID.tzQuarterHours,
                                      version: 4, type: 0, subtype: 0, detailType: 0)
        var minuteBytes = minuteID.bytes + [0] + Array(bytes[8..<14])
        var zeroRow = Array(bytes[14..<30]); zeroRow[0] = 0; zeroRow[1] = 0
        minuteBytes += zeroRow
        for _ in 1..<1440 { minuteBytes += Array(bytes[14..<30]) }
        let minuteCRC = ActivityCRC32.checksum(minuteBytes)
        minuteBytes += [UInt8(truncatingIfNeeded: minuteCRC), UInt8(truncatingIfNeeded: minuteCRC >> 8),
                        UInt8(truncatingIfNeeded: minuteCRC >> 16), UInt8(truncatingIfNeeded: minuteCRC >> 24)]
        fresh.insert(ActivityBlob(bandID: summaryBand.id, id: minuteID, data: Data(minuteBytes)))
        try fresh.save(); _ = await ActivityIngest(context: fresh).ingestPending()
        summaryWriter.saves.removeAll(); summaryWriter.deletes.removeAll(); summaryWriter.failNextDelete = true
        summaryService.schedule(); await settle(summaryService)
        check(summaryWriter.deletes.contains(summarySyncID), "summary is removed before minute replacement")
        check(!summaryWriter.saves.contains { $0.0.contains(".steps.") }, "failed summary removal blocks overlapping step writes")
        summaryService.schedule(); await settle(summaryService)
        let replaced = try fresh.fetch(FetchDescriptor<HealthExportLedgerRow>())
        check(replaced.contains { $0.identifier == summarySyncID && $0.state == "deleted" }, "summary deletion is acknowledged")
        check(replaced.contains { $0.kind == "steps" && $0.identifier != summarySyncID && $0.state == "saved" }, "minute records replace summary")
        let emptyContainer = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let emptyService = HealthExportService(context: emptyContainer.mainContext, demo: false, writer: FakeWriter())
        await emptyService.enable(); await settle(emptyService)
        check(emptyService.status?.contains("No exportable") == true, "empty source is not reported as a successful export")
        // Optional private real-file check: input is never copied, logged, or written to disk.
        if let path = ProcessInfo.processInfo.environment["FREEBAND_PRIVATE_SUMMARY"] {
            let privateContainer = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            let privateContext = privateContainer.mainContext
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let fileID = ActivityFileID(data.prefix(7)) else { fatalError("private summary header") }
            let privateBand = Band(name: "Private test band", mac: nil)
            privateContext.insert(privateBand)
            privateContext.insert(ActivityBlob(bandID: privateBand.id, id: fileID, data: data))
            try privateContext.save(); _ = await ActivityIngest(context: privateContext).ingestPending()
            let privateWriter = FakeWriter()
            let privateService = HealthExportService(context: privateContext, demo: false, writer: privateWriter)
            await privateService.enable(); await settle(privateService)
            let privateRows = try privateContext.fetch(FetchDescriptor<HealthExportLedgerRow>())
            check(privateRows.contains { $0.kind == "steps" && $0.state == "saved" }, "private summary produces a step entry")
            check(privateRows.contains { $0.kind == "restingHeartRate" && $0.state == "saved" }, "private summary produces a resting-HR entry")
            print("Private summary mapping check passed (values omitted)")
        }
        print("Health export store checks passed")
    }
}
