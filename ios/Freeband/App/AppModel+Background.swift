import BackgroundTasks
import Combine
import Foundation
import SwiftData
import SwiftUI
import UIKit
import UserNotifications

/// Syncing without the user: background refresh, the held session's events, finishing a sync
/// after the app left the screen, and what follows a night (the morning summary, the sleep
/// summary for the band). The state lives in AppModel.
@MainActor
extension AppModel {
    // MARK: background sync

    static let backgroundRefreshID = "dev.cobanov.freeband.sync"
    /// A sync nobody asked for runs when the last complete one is older than this,
    static let backgroundSyncAfter: TimeInterval = 60 * 60
    /// and at most this often, so a band that can't be synced isn't asked on every event.
    static let backgroundSyncRetry: TimeInterval = 15 * 60

    /// Once, while the app launches (FreebandApp.init): iOS runs this now and then while the app
    /// is in the background, more often for an app that is opened often.
    static func registerBackgroundRefresh() {
        let now = Date()
        assert(backgroundSyncDue(lastSync: nil, lastAttempt: .distantPast, now: now))
        assert(!backgroundSyncDue(lastSync: now.addingTimeInterval(-backgroundSyncAfter + 1), lastAttempt: .distantPast, now: now))
        assert(!backgroundSyncDue(lastSync: nil, lastAttempt: now.addingTimeInterval(-backgroundSyncRetry + 1), now: now))
        assert(backgroundSyncDue(lastSync: now.addingTimeInterval(-backgroundSyncAfter), lastAttempt: now.addingTimeInterval(-backgroundSyncRetry), now: now))
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundRefreshID, using: .main) { task in
            MainActor.assumeIsolated {
                guard let model = AppModel.shared else { return task.setTaskCompleted(success: false) }
                model.scheduleBackgroundRefresh()
                var finished = false
                task.expirationHandler = { Task { @MainActor in
                    guard !finished else { return }
                    finished = true
                    if model.backgroundSessionActive {
                        model.healthExport.pause()
                        if model.backgroundOwnsLink { model.stop() }
                    }
                    task.setTaskCompleted(success: false)
                } }
                Task {
                    await model.backgroundSync("background refresh")
                    guard !finished else { return }
                    finished = true
                    task.setTaskCompleted(success: true)
                }
            }
        }
    }

    func scheduleBackgroundRefresh() {
        guard !isDemo else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundRefreshID)
        request.earliestBeginDate = Date().addingTimeInterval(Self.backgroundSyncAfter)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// With Stay connected on, Bluetooth events wake the app: the held session opening (the band
    /// came back in range) and the band reporting a change (put on, woke up, on the charger).
    /// Each is a chance to sync before the user opens the app.
    func watchHeldSession() {
        link.$holdState.removeDuplicates().filter { $0 == .connected }
            .sink { [weak self] _ in Task { await self?.backgroundSync("held session opened") } }
            .store(in: &watchers)
        link.$deviceState.dropFirst().removeDuplicates()
            .sink { [weak self] _ in Task { await self?.backgroundSync("band state changed") } }
            .store(in: &watchers)
    }

    /// Syncs the selected band if its last complete sync is old. Returns when the session ended.
    func backgroundSync(_ reason: String, now: Date = Date()) async {
        guard !isDemo, !backgroundSessionActive, UserDefaults.standard.bool(forKey: "onboarded"),
              let band = selectedBand(), !link.phase.isBusy else { return }
        healthExport.resume()
        guard Self.backgroundSyncDue(lastSync: band.lastSyncAt, lastAttempt: lastBackgroundSync, now: now) else { return }
        lastBackgroundSync = now
        link.note("background sync: \(reason)")
        backgroundSessionActive = true
        backgroundOwnsLink = true
        defer { backgroundSessionActive = false; backgroundOwnsLink = false }
        start(band, .sync)
        await finishInBackground()
    }

    /// The morning summary: once a day, the first time a sync that ran in the background brings
    /// today's scores, a notification says how the day starts. Nothing while the app is in front
    /// (the scores are on screen) and nothing unless notifications are allowed (Stay connected
    /// asks for them).
    func notifyMorningSummary(_ bandID: UUID) {
        guard !isDemo, UIApplication.shared.applicationState != .active else { return }
        let today = DayKey.current(Date()).index
        guard UserDefaults.standard.integer(forKey: "morningSummaryDay") != today else { return }
        let scores = try? context.fetch(FetchDescriptor<DailyScore>(predicate: #Predicate { $0.bandID == bandID && $0.dayIndex == today }))
        guard let score = scores?.first, score.recoveryScore != nil || score.sleepScore != nil else { return }
        UserDefaults.standard.set(today, forKey: "morningSummaryDay")
        let content = UNMutableNotificationContent()
        content.title = score.recoveryScore.map { DayVerdict(recovery: Double($0)).word }
            ?? score.sleepScore.map { ScoreBand.sleep(Double($0)).word } ?? ""
        content.body = [score.recoveryScore.map { "\(ScoreKind.recovery.name) \($0)" }, score.sleepScore.map { "\(ScoreKind.sleep.name) \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "morning-summary", content: content, trigger: nil))
    }


    func writeBackSleep(_ bandID: UUID) {
        guard !isDemo, UserDefaults.standard.bool(forKey: Self.sleepToBandKey), let band = band(bandID) else { return }
        let today = DayKey.current(Date()).index
        let nights = (try? context.fetch(FetchDescriptor<SleepRecord>(
            predicate: #Predicate { $0.bandID == bandID && $0.dayIndex == today && !$0.isNap }))) ?? []
        guard let night = nights.max(by: { $0.wakeTime.timeIntervalSince($0.bedTime) < $1.wakeTime.timeIntervalSince($1.bedTime) }),
              UserDefaults.standard.double(forKey: "sleepToBandWake.\(bandID.uuidString)") != night.wakeTime.timeIntervalSince1970 else { return }
        let scores = try? context.fetch(FetchDescriptor<DailyScore>(predicate: #Predicate { $0.bandID == bandID && $0.dayIndex == today }))
        let metrics = scores?.first?.result?.sleep.metrics
        guard let asleep = metrics.map({ Int($0.totalSleepMinutes.rounded()) }) ?? night.totalSleepMinutes, asleep > 0 else { return }
        let section = SleepResultSection(bedTime: night.bedTime, wakeTime: night.wakeTime, tzQuarterHours: night.tzOffsetMinutes / 15,
                                         minutesAsleep: asleep, averageHeartRate: metrics?.hrAverage.map { Int($0.rounded()) },
                                         averageSpO2: metrics?.spo2Average.map { Int($0.rounded()) }, extra: nil)
        // After the session that just ended has let go of the band.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.link.phase.isBusy else { return }
            self.link.note("sleep summary → band: \(asleep) min asleep")
            self.sleepWriteBack = (bandID, night.wakeTime.timeIntervalSince1970)
            self.start(band, .send([MiAuth.sleepResultCommand([section])]))
        }
    }

    static func backgroundSyncDue(lastSync: Date?, lastAttempt: Date, now: Date) -> Bool {
        if let lastSync, now.timeIntervalSince(lastSync) < backgroundSyncAfter { return false }
        return now.timeIntervalSince(lastAttempt) >= backgroundSyncRetry
    }

    /// Keeps the app running until the session ends. When iOS's time runs out first, the session
    /// stops: the files that arrived are kept and the rest come with the next sync.
    func finishInBackground() async {
        endSyncBackgroundTask()
        var awaitingSession = true
        syncBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Sync") { [weak self] in
            self?.healthExport.pause()
            if awaitingSession { self?.stop() }
            self?.endSyncBackgroundTask()
        }
        try? await Task.sleep(for: .milliseconds(300))
        while link.phase.isBusy { try? await Task.sleep(for: .milliseconds(300)) }
        awaitingSession = false
        backgroundOwnsLink = false
        if let processing = syncProcessingTask { await processing.value }
        await healthExport.waitUntilIdle()
        // A held session opens again 2 s after another session ends, on a timer.
        try? await Task.sleep(for: .seconds(3))
        endSyncBackgroundTask()
    }

    func endSyncBackgroundTask() {
        guard syncBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(syncBackgroundTask)
        syncBackgroundTask = .invalid
    }
}
