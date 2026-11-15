import Foundation
import SwiftData

// Store-side ingest tests on macOS with an in-memory SwiftData container: ActivityIngest
// (idempotent delete + insert, minute-day rebuild, sleep merge), DailyRollup and the demo
// generator, i.e. the same code the app runs, without the app.
//
//   cd ios/tests/ingest/store
//   F=../../../Freeband
//   swiftc -D DEBUG stub.swift $F/Band/ActivityFiles.swift $F/Analytics/*.swift $F/Data/*.swift \
//          $F/App/DemoData.swift main.swift -o /tmp/ingest_store_tests
//   /tmp/ingest_store_tests [FIXTURE_DIR]

var passed = 0
var failed = 0
var group = ""

func section(_ name: String) {
    group = name
    print("-- \(name)")
}

func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok {
        passed += 1
    } else {
        failed += 1
        print("FAIL \(group) :: \(name) \(detail())")
    }
}

func equal<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    check(name, got == want, "got \(got) want \(want)")
}

func hexData(_ hex: String) -> Data {
    var out: [UInt8] = []
    var high: UInt8?
    for c in hex.utf8 {
        let v: UInt8
        switch c {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): v = c - UInt8(ascii: "0")
        case UInt8(ascii: "a") ... UInt8(ascii: "f"): v = c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A") ... UInt8(ascii: "F"): v = c - UInt8(ascii: "A") + 10
        default: continue
        }
        if let h = high {
            out.append(h << 4 | v)
            high = nil
        } else {
            high = v
        }
    }
    return Data(out)
}

let fixtureDir: URL = {
    if CommandLine.arguments.count > 1 { return URL(fileURLWithPath: CommandLine.arguments[1]) }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../activity/fixtures").standardized
}()

/// Fixture files by name; files stored without a CRC get one, as the assembler would deliver them.
func fixture(_ nameContains: String) -> Data? {
    for f in ["synthetic.json", "gb_daily_summary.json", "gb_manual_samples_v1.json"] {
        guard let data = try? Data(contentsOf: fixtureDir.appendingPathComponent(f)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cases = json["cases"] as? [[String: Any]] else { continue }
        for c in cases where (c["name"] as? String ?? "").contains(nameContains) {
            var bytes = [UInt8](hexData(c["hex"] as? String ?? ""))
            if c["has_crc"] as? Bool == false {
                let crc = ActivityCRC32.checksum(bytes)
                bytes += [UInt8(crc & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 24)]
            }
            return Data(bytes)
        }
    }
    return nil
}

func container() -> ModelContainer {
    // swiftlint:disable:next force_try
    try! ModelContainer(for: Band.self, Sample.self, Webhook.self, ActivityBlob.self, MinuteDay.self, DaySummary.self,
                        SleepRecord.self, SleepRR.self, ManualReading.self, DailyScore.self,
                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
}

@MainActor
func count<T: PersistentModel>(_ type: T.Type, _ context: ModelContext) -> Int {
    (try? context.fetchCount(FetchDescriptor<T>())) ?? -1
}

@MainActor
func store(_ context: ModelContext, band: UUID, _ data: Data) {
    guard let id = ActivityFileID(data.prefix(7)) else { return }
    if let existing = try? context.fetch(FetchDescriptor<ActivityBlob>()).first(where: { $0.bandID == band && $0.fileID == id.hex }) {
        existing.data = data
        existing.fetchedAt = Date()
        existing.parsedAt = nil
        existing.parserVersion = 0
    } else {
        context.insert(ActivityBlob(bandID: band, id: id, data: data))
    }
    try? context.save()
}

@MainActor
func run() async {
    // MARK: ingest of fixture files

    section("ingest")
    let c = container()
    let ctx = c.mainContext
    let band = UUID()
    // ("sleep stages v2 with no data" has the same file id as the five-phase one: it is used below
    // as a replacement of that file.)
    let names = ["daily details v4", "sleep details v5", "sleep details v2", "sleep stages v2, five",
                 "manual samples v2", "v5 all bits set", "v1 SpO2 97", "daily details v3"]
    for n in names {
        guard let data = fixture(n) else {
            check("fixture \(n)", false)
            continue
        }
        store(ctx, band: band, data)
    }
    // A workout summary is stored too and must stay raw.
    let workout = hexData("12b1eb69080b8d00fbffefef91ffc0003f12b1eb6930b8eb69180700007f1100008900950100005801000013030000271300005800a300a800a7b35e66668640000000002800e9010000c70400003d0000000e00000010000000ba00170700006666e63f0003000000000000000000a00f0000000000000000000000009411000068000300000000000000000000000000000c0000000000000000000000000000000000000000000000000000000000f2b84b9a")
    store(ctx, band: band, workout)

    let ingest = ActivityIngest(context: ctx)
    equal("pending before", ingest.pendingBlobs().count, names.count + 1)
    let first = await ingest.ingestPending()
    equal("files in the summary", first.files.count, names.count + 1)
    equal("nothing pending after", ingest.pendingBlobs().count, 0)
    let blobs = (try? ctx.fetch(FetchDescriptor<ActivityBlob>())) ?? []
    check("every file at the current parser", blobs.allSatisfy { $0.parserVersion == ActivityIngest.parserVersion && $0.parsedAt != nil })
    equal("workout status", blobs.first { $0.fileID == ActivityFileID(workout.prefix(7))?.hex }?.parseStatus, "unsupported")
    // v4 (2025-10-14) and v3 (2025-10-15) minute files: two days.
    equal("minute days", count(MinuteDay.self, ctx), 2)
    // v5 details, v2 details, stages: three sleeps; the no-data stages file makes none.
    equal("sleep records", count(SleepRecord.self, ctx), 3)
    equal("rr rows", count(SleepRR.self, ctx), 1)
    equal("manual readings", count(ManualReading.self, ctx), 5)
    equal("day summaries", count(DaySummary.self, ctx), 1)
    let counts = [count(MinuteDay.self, ctx), count(SleepRecord.self, ctx), count(SleepRR.self, ctx),
                  count(ManualReading.self, ctx), count(DaySummary.self, ctx)]

    // MARK: idempotence

    section("idempotent")
    for blob in blobs {
        blob.parserVersion = 0
        blob.parsedAt = nil
    }
    try? ctx.save()
    _ = await ingest.ingestPending()
    equal("same rows after a second ingest", [count(MinuteDay.self, ctx), count(SleepRecord.self, ctx), count(SleepRR.self, ctx),
                                              count(ManualReading.self, ctx), count(DaySummary.self, ctx)], counts)
    let summary2 = await ingest.reparseAll()
    equal("reparse all: same rows", [count(MinuteDay.self, ctx), count(SleepRecord.self, ctx), count(SleepRR.self, ctx),
                                      count(ManualReading.self, ctx), count(DaySummary.self, ctx)], counts)
    equal("reparse all: every file", summary2.files.count, names.count + 1)

    // MARK: a growing file

    section("growing file")
    // Today's file grows: the same id with one more minute record appended (v4 records are
    // header-defined; repeat the last record's bytes).
    if let v4 = fixture("daily details v4"), let id = ActivityFileID(v4.prefix(7)) {
        let original = [UInt8](v4.dropLast(4))
        let parsed = ActivityParser.parse(v4)
        guard case let .dailyDetails(d) = parsed.payload else { fatalError() }
        let bodyStart = 8 + d.header.count
        let recordLength = (original.count - bodyStart) / d.records.count
        let grownBody = original + Array(original[(original.count - recordLength)...])
        let crc = ActivityCRC32.checksum(grownBody)
        let grown = Data(grownBody + [UInt8(crc & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 24)])
        let grownRecords: Int = {
            if case let .dailyDetails(g) = ActivityParser.parse(grown).payload { return g.records.count }
            return -1
        }()
        store(ctx, band: band, grown)
        _ = await ingest.ingestPending()
        let rows = ((try? ctx.fetch(FetchDescriptor<MinuteDay>())) ?? []).filter { $0.sourceFileIDs.contains(id.hex) }
        equal("still one row for the day", rows.count, 1)
        equal("row has the new minute", rows.first?.recordCount, grownRecords)
        check("grew by one", grownRecords == d.records.count + 1, "\(grownRecords) vs \(d.records.count)")
    }

    // The band rewrites the stages file with "no data" under the same id: its night goes away.
    if let noData = fixture("sleep stages v2 with no data") {
        let before = count(SleepRecord.self, ctx)
        store(ctx, band: band, noData)
        _ = await ingest.ingestPending()
        equal("replaced file drops its sleep", count(SleepRecord.self, ctx), before - 1)
        equal("same number of files", count(ActivityBlob.self, ctx), names.count + 1)
        if let five = fixture("sleep stages v2, five") {
            store(ctx, band: band, five)
            _ = await ingest.ingestPending()
            equal("and back", count(SleepRecord.self, ctx), before)
        }
    }

    // MARK: sleep merge in the store

    section("sleep merge")
    let records = ((try? ctx.fetch(FetchDescriptor<SleepRecord>())) ?? []).sorted { $0.bedTime < $1.bedTime }
    check("non-overlapping sleeps all primary", records.allSatisfy(\.isPrimary))
    // A sleep stages copy of the v5 night (same bed time) arrives later: details still wins.
    if let v5 = records.first(where: { $0.kind == "details" && $0.hasRR }) {
        var stagesDraft = v5.draft()
        stagesDraft.kind = .stages
        stagesDraft.sourceFileID = "ffffffff0c0200"
        stagesDraft.wakeTime = v5.wakeTime.addingTimeInterval(1800)
        ctx.insert(SleepRecord(bandID: band, draft: stagesDraft))
        try? ctx.save()
        let all = (try? ctx.fetch(FetchDescriptor<SleepRecord>(sortBy: [SortDescriptor(\.bedTime)]))) ?? []
        for (r, flag) in zip(all, IngestMapper.primaryFlags(all.map { $0.draft() })) { r.isPrimary = flag }
        try? ctx.save()
        let primary = (try? ctx.fetch(FetchDescriptor<SleepRecord>(predicate: #Predicate { $0.isPrimary }))) ?? []
        equal("details beats a later stages file", primary.contains { $0.sourceFileID == "ffffffff0c0200" }, false)
        check("details stays primary", primary.contains { $0.sourceFileID == v5.sourceFileID })
    }

    // MARK: rollup

    section("rollup")
    // The fixture days are in October 2025; score them as of that time.
    let then = DayKey(string: "2025-10-15")!.start(offsetMinutes: 180).addingTimeInterval(12 * 3600)
    let results = DailyRollup.recompute(context: ctx, bandID: band, from: DayKey(string: "2025-10-13")!, now: then, profile: .unknown)
    let scores = (try? ctx.fetch(FetchDescriptor<DailyScore>(sortBy: [SortDescriptor(\.dayIndex)]))) ?? []
    // 13th: the v2 details sleep (21:26-23:16, after 20:00 so not a nap); 14th: minutes and the
    // stages night; 15th: minutes and the v5 night.
    equal("one score per day with data", scores.map(\.day), ["2025-10-13", "2025-10-14", "2025-10-15"])
    equal("results match rows", results.count, scores.count)
    check("night of the 15th scored", scores.last?.sleepScore != nil)
    check("contributors decode", scores.allSatisfy { $0.result != nil })
    check("algorithm version stored", scores.allSatisfy { $0.algoVersion == ScoreEngine.algoVersion })
    check("not stale", !DailyRollup.isStale(context: ctx))
    DailyRollup.recompute(context: ctx, bandID: band, from: DayKey(string: "2025-10-13")!, now: then, profile: .unknown)
    equal("rollup twice: no duplicates", count(DailyScore.self, ctx), 3)
    equal("steps helper", DailyRollup.steps(context: ctx, bandID: band, day: DayKey(string: "2025-10-14")!, now: then) != nil, true)

    // MARK: wiping

    section("wipe")
    ActivityIngest.deleteDerived(context: ctx, bandID: UUID(), includingScores: true)
    try? ctx.save()
    equal("other band untouched", count(MinuteDay.self, ctx), 2)
    ActivityIngest.deleteDerived(context: ctx, bandID: band, includingScores: true)
    try? ctx.save()
    equal("derived gone", [count(MinuteDay.self, ctx), count(SleepRecord.self, ctx), count(SleepRR.self, ctx),
                           count(ManualReading.self, ctx), count(DaySummary.self, ctx), count(DailyScore.self, ctx)], [0, 0, 0, 0, 0, 0])
    equal("raw files kept", count(ActivityBlob.self, ctx), names.count + 1)

    // MARK: demo data through the real pipeline

    section("demo full")
    let demo = container()
    let dctx = demo.mainContext
    let started = Date()
    DemoData.seed(dctx, .full)
    print("   demo seed + rollup: \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
    let demoScores = (try? dctx.fetch(FetchDescriptor<DailyScore>(sortBy: [SortDescriptor(\.dayIndex)]))) ?? []
    equal("30 scored days", demoScores.count, 30)
    equal("one band", count(Band.self, dctx), 1)
    check("minute days", count(MinuteDay.self, dctx) == 30)
    check("RR for 20 nights", count(SleepRR.self, dctx) >= 19)
    let decoded = demoScores.compactMap(\.result)
    equal("all decode", decoded.count, 30)
    check("first nights: no RR", decoded.prefix(10).allSatisfy { !$0.hasRR })
    check("later nights: RR", decoded.dropFirst(11).dropLast().allSatisfy { $0.hasRR })
    check("recovery without HRV early", decoded[5].recovery.score != nil && !decoded[5].recovery.usesHRV)
    check("recovery with HRV late", decoded.suffix(5).contains { $0.recovery.usesHRV })
    check("HRV values plausible", decoded.compactMap { $0.hrv?.rmssd }.allSatisfy { (15 ... 90).contains($0) })
    check("sleep scores", decoded.dropFirst().allSatisfy { $0.sleep.score != nil } || decoded.last?.sleep.score == nil)
    check("strain everywhere", decoded.allSatisfy { $0.strain != nil })
    let strains = decoded.compactMap { $0.strain?.strain }
    check("strain varies", (strains.max() ?? 0) - (strains.min() ?? 0) > 3, "\(strains)")
    let recoveries = decoded.compactMap(\.recovery.score)
    check("recovery varies", (recoveries.max() ?? 0) - (recoveries.min() ?? 0) > 10, "\(recoveries)")
    let sleepScores = decoded.compactMap(\.sleep.score)
    print("   sleep \(sleepScores)")
    print("   recovery \(recoveries)")
    print("   strain \(strains.map { (($0 * 10).rounded()) / 10 })")
    print("   hrv \(decoded.map { $0.hrv.map { Int($0.rmssd) } ?? 0 })")
    print("   confidence \(decoded.map { String($0.recovery.confidence.level.rawValue.prefix(1)) }.joined())")
    check("live samples today", count(Sample.self, dctx) > 1)

    section("demo calibrating and empty")
    let cal = container()
    DemoData.seed(cal.mainContext, .calibrating)
    let calScores = (try? cal.mainContext.fetch(FetchDescriptor<DailyScore>())) ?? []
    equal("2 days", calScores.count, 2)
    check("still calibrating: no recovery", calScores.allSatisfy { $0.recoveryScore == nil })
    let empty = container()
    DemoData.seed(empty.mainContext, .empty)
    equal("empty: band only", [count(Band.self, empty.mainContext), count(DailyScore.self, empty.mainContext), count(Sample.self, empty.mainContext)], [1, 0, 0])
    equal("variant parsing", [DemoData.variant(["app", "-freeband-demo"]), DemoData.variant(["app", "-freeband-demo", "empty"]),
                              DemoData.variant(["app", "-freeband-demo", "calibrating"]), DemoData.variant(["app"])],
          [.full, .empty, .calibrating, nil])

    section("band names")
    // Mi Fitness names and Bluetooth names, in the form the bands and watches give them. The
    // suffixes and addresses are made up (AGENTS.md).
    let bandNames: [(String, Band.Family, String)] = [
        ("Xiaomi Smart Band 10", .band10, "band10"),
        ("Xiaomi Smart Band 10 Pro D9B9", .band10Pro, "band10pro"),
        ("Redmi Watch 5 Active D3DD", .redmiWatch5Active, "band10"),
        ("Xiaomi Watch S1 Active", .watchS1Active, "band10"),
        ("XiaomiWatchS1Active 5E6F", .watchS1Active, "band10"),
        ("Xiaomi Smart Band 8", .band8, "band10"),
        ("Xiaomi Smart Band 8 A1B2", .band8, "band10"),
        ("Xiaomi Smart Band 8 Pro 1C2D", .band10Pro, "band10pro"),  // Bluetooth Classic only: not a Band 8 here
        ("Xiaomi Smart Band 8 Active 3E4F", .band10, "band10"),
    ]
    for (name, family, code) in bandNames {
        equal(name, Band.family(name: name), family)
        equal("\(name) model code", Band.modelCode(for: name), code)
    }
    equal("short names", [Band(name: "XiaomiWatchS1Active 5E6F", mac: nil).shortName, Band(name: "Xiaomi Smart Band 8", mac: nil).shortName],
          ["Watch S1 Active", "Band 8"])
    equal("display name", Band.displayName(name: "Xiaomi Watch S1 Active", mac: "AA:BB:CC:DD:5E:6F"), "Watch S1 Active (5E6F)")
    // The Watch S1 Active accepts Find and doesn't vibrate (firmware 1.4.174).
    equal("no Find", Band.Family.allCases.filter { !$0.supportsFind }, [.watchS1Active])
    equal("no Find by name", [Band(name: "XiaomiWatchS1Active 5E6F", mac: nil).supportsFind, Band(name: "Xiaomi Smart Band 10 Pro", mac: nil).supportsFind],
          [false, true])
}

Task { @MainActor in
    await run()
    print("\(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}
dispatchMain()
