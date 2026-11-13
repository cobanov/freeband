// Contract check between the app and the hub (docs/API.md): seeds the full demo data, builds the
// webhook/hub bodies exactly as AppModel does and writes them to hub/test/fixtures, where
// hub/test/contract.test.ts runs them through the hub's validator.
//
//   cd ios/tests/contract && F=../../Freeband && xcrun swiftc -sdk $(xcrun --show-sdk-path --sdk macosx) -D DEBUG \
//     ../ingest/store/stub.swift $F/Band/ActivityFiles.swift $F/Analytics/*.swift $F/Data/*.swift \
//     $F/App/DemoData.swift $F/Integrations/Payload.swift main.swift -o /tmp/contract && /tmp/contract ../../../hub/test/fixtures
import Foundation
import SwiftData

@MainActor func run() {
    let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
    let container = try! ModelContainer(for: Band.self, Sample.self, Webhook.self, ActivityBlob.self, MinuteDay.self,
                                        DaySummary.self, SleepRecord.self, SleepRR.self, ManualReading.self, DailyScore.self, Workout.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let context = ModelContext(container)
    // A fixed clock keeps the fixture stable from run to run.
    let now = ISO8601DateFormatter().date(from: "2026-10-14T09:30:00Z")!
    DemoData.seed(context, .full, now: now)

    let band = try! context.fetch(FetchDescriptor<Band>()).first!
    let offset = TimeZone.current.secondsFromGMT(for: now) / 60
    var records: [[String: Any]] = []
    for day in try! context.fetch(FetchDescriptor<MinuteDay>(sortBy: [SortDescriptor(\.dayIndex)])).suffix(2) {
        records += Payload.minuteRecords(day.draft.series)
    }
    let sleeps = try! context.fetch(FetchDescriptor<SleepRecord>(sortBy: [SortDescriptor(\.bedTime)]))
    records += sleeps.compactMap { Payload.sleepRecord($0.draft()) }
    let scores = try! context.fetch(FetchDescriptor<DailyScore>(sortBy: [SortDescriptor(\.dayIndex)]))
    records += scores.map { Payload.scoreRecord($0, tzOffsetMinutes: offset) }

    let bodies = Payload.bodies(event: "sync.completed", device: Payload.Device(band), samples: [], records: records, now: now)
    try! FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for (i, body) in bodies.enumerated() {
        try! body.write(to: out.appendingPathComponent("app-health-\(i).json"))
    }
    let kinds = Dictionary(grouping: records, by: { $0["type"] as! String }).mapValues(\.count)
    print("bodies \(bodies.count), records \(kinds.sorted { $0.key < $1.key })")
}

MainActor.assumeIsolated { run() }
