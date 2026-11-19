import Foundation
import SwiftData
@main struct MigrationCheck {
    @MainActor static func main() throws {
        #if OLD
        let schema = Schema([Band.self, Sample.self, Webhook.self, ActivityBlob.self, MinuteDay.self, DaySummary.self, SleepRecord.self, SleepRR.self, ManualReading.self, DailyScore.self])
        #elseif UPSTREAM
        let schema = Schema([Band.self, Sample.self, Webhook.self, ActivityBlob.self, MinuteDay.self, DaySummary.self, SleepRecord.self, SleepRR.self, ManualReading.self, DailyScore.self, Workout.self])
        #else
        let schema = Schema([Band.self, Sample.self, Webhook.self, ActivityBlob.self, MinuteDay.self, DaySummary.self, SleepRecord.self, SleepRR.self, ManualReading.self, DailyScore.self, Workout.self, HealthExportLedgerRow.self, HealthExportSettings.self])
        #endif
        guard let path = ProcessInfo.processInfo.environment["FREEBAND_MIGRATION_STORE"] else { fatalError("missing test store path") }
        let config = ModelConfiguration(schema: schema, url: URL(fileURLWithPath: path))
        let container = try ModelContainer(for: schema, configurations: config)
        let context = container.mainContext
        #if OLD || UPSTREAM
        context.insert(Band(name: "Migration Test", mac: "AA:BB:CC:DD:5E:6F")); try context.save()
        #else
        let bands = try context.fetch(FetchDescriptor<Band>())
        guard bands.count == 1, bands[0].name == "Migration Test", bands[0].healthExportNamespace == nil else { fatalError("existing band was not preserved") }
        bands[0].healthExportNamespace = UUID()
        let settings = HealthExportSettings(); settings.enabled = true; context.insert(settings); try context.save()
        print("SwiftData old-store migration passed")
        #endif
    }
}
