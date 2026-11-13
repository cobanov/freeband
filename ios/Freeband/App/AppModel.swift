import BackgroundTasks
import Combine
import Foundation
import SwiftData
import SwiftUI
import UIKit
import UserNotifications

/// Ties the band session to storage and integrations: every observation is stored as it
/// arrives; every activity file is stored, then parsed into the derived models; when a session
/// ends the touched days are scored again, webhooks get the session's samples and health records
/// (the account server and web access were removed on 2026-11-14: nobody used them).
@MainActor
final class AppModel: ObservableObject {
    let link: BandLink
    let context: ModelContext
    let ingest: ActivityIngest

    /// Local midnight of the current day; changes at midnight and on clock/time-zone changes.
    @Published private(set) var today = Calendar.current.startOfDay(for: Date())
    /// The newest calibration report (plan section 4, phase 0).
    @Published var calibration: CalibrationReport?
    /// Parsing or scoring is running (reparse all, launch).
    @Published private(set) var ingestBusy = false

    /// Fires with the new day's midnight when the day changes while the app runs.
    let dayChanged = PassthroughSubject<Date, Never>()

    private var sessionDrafts: [SampleDraft] = []
    /// What the ingests of the running session parsed, for its report and webhooks.
    private var sessionIngest = IngestSummary()
    /// Earliest day per band whose scores must be recomputed once no session is running.
    var pendingRollup: [UUID: DayKey] = [:]
    private var ingestTask: Task<Void, Never>?
    private var ingestAgain = false
    private var dayObservers: [NSObjectProtocol] = []

    /// The project's site (privacy page, guide).
    static let siteURL = URL(string: "https://freeband.cobanov.dev")!

    /// The one model, for App Intents (Siri, Shortcuts).
    static weak var shared: AppModel?

    /// Demo mode (DemoMode.swift): an in-memory store with demo data. Band sessions can't start
    /// (the demo band has no key) and nothing reaches the hub or webhooks.
    let isDemo: Bool

    // Background sync state (methods in AppModel+Background.swift).
    var lastBackgroundSync = Date.distantPast
    var syncBackgroundTask = UIBackgroundTaskIdentifier.invalid
    var watchers: Set<AnyCancellable> = []
    /// Show sleep on the band (docs/SLEEP-WRITEBACK.md): once per night, after the sync that
    /// brought it, the night's summary goes to the band (Command{8,41}), which is what fills the
    /// band's own sleep screen when Mi Fitness is around. Off by default.
    /// The write-back that is on its way: marked as done only when its session completed, so a
    /// band that was out of reach gets it at the next sync.
    var sleepWriteBack: (bandID: UUID, wake: TimeInterval)?

    init(context: ModelContext, isDemo: Bool = false) {
        self.context = context
        self.isDemo = isDemo
        // Only the real store's link may be relaunched by iOS for a held session; the demo has no band.
        link = BandLink(restoresState: !isDemo)
        findPhoneAlert = isDemo ? nil : FindPhoneAlert()
        ingest = ActivityIngest(context: context)
        link.onSample = { [weak self] id, draft in self?.record(id, draft) }
        link.onFinish = { [weak self] id, outcome in self?.sessionEnded(id, outcome) }
        link.onIdentified = { [weak self] id, keyIndex, name in self?.identified(id, keyIndex, name) }
        link.hasActivityFile = { [weak self] id, hex in self?.hasActivityFile(id, hex) ?? false }
        link.onDeviceInfo = { [weak self] id, info in
            guard let self, let band = self.band(id) else { return }
            band.firmware = info.firmware.isEmpty ? band.firmware : info.firmware
            band.hardwareModel = info.model.isEmpty ? band.hardwareModel : info.model
            try? self.context.save()
        }
        link.onActivityFile = { [weak self] id, file, data, today in self?.storeActivityFile(id, file, data, today: today) }
        link.onFindPhone = { [weak self] id, ring in self?.findPhone(id, ring) }
        link.phoneLocation = { [weak self] in
            // A fix older than six hours says little about where the phone is now.
            guard let self, UserDefaults.standard.bool(forKey: Self.shareLocationKey), let l = self.phoneLocation.last,
                  Date().timeIntervalSince(l.timestamp) < 6 * 3600 else { return nil }
            return (l.timestamp, l.coordinate.latitude, l.coordinate.longitude, l.verticalAccuracy >= 0 ? l.altitude : nil)
        }
        link.canAcknowledge = { [weak self] id, hex in
            UserDefaults.standard.bool(forKey: Self.clearBandKey) && self?.blob(id, hex)?.parseStatus == ParseStatus.parsed.rawValue
        }
        link.onMonitoring = { [weak self] id, setting, body in
            self?.monitoring["\(id.uuidString).\(setting.rawValue)"] = body
        }
        findPhoneAlert?.onStop = { [weak self] in self?.stopFindPhone() }
        calibration = Self.loadCalibration()
        mergeDuplicateBands()
        observeDayChanges()
        AppModel.shared = self
        if !isDemo {
            // At launch, also when iOS relaunches the app in the background for the held session.
            // The log line marks a new process: what came before it in the log is gone.
            link.note("— app started")
            updateHold()
            watchHeldSession()
            Task { await self.launchMaintenance() }
        }
    }

    // MARK: band sessions

    func target(for band: Band) -> BandTarget? {
        let keys = Vault.bandKeys(band.id)
        guard !keys.isEmpty else { return nil }
        return BandTarget(id: band.id, name: band.name, mac: band.mac, macSuffix: band.macSuffix,
                          keys: keys.map { BandKey(hex: $0).data })
    }

    func start(_ band: Band, _ purpose: BandLink.Purpose) {
        guard let target = target(for: band) else { return }
        sessionDrafts = []
        sessionIngest = IngestSummary()
        link.start(target, purpose: purpose)
    }

    func stop() { link.stop() }

    private var notificationID: UInt32 = UInt32(Date().timeIntervalSince1970) % 100_000

    /// Shows a notification on the band.
    func notify(_ band: Band, title: String, body: String) {
        notificationID &+= 1
        start(band, .send([MiAuth.notificationCommand(id: notificationID, appName: "Freeband", title: title, body: body)]))
    }

    /// Starts or stops the band vibrating so it can be found; nothing for a band that ignores it.
    func findBand(_ band: Band, start vibrating: Bool) {
        guard band.supportsFind else { return }
        start(band, .send([MiAuth.findBandCommand(start: vibrating)]))
    }

    // MARK: health monitoring settings (docs/CAPABILITIES.md §9)

    /// Each setting as the band last returned it, keyed "<band id>.<GET subtype>". A change is
    /// built from these bytes, and the screen shows what the band answers afterwards.
    @Published var monitoring = (UserDefaults.standard.dictionary(forKey: "monitoring") as? [String: Data]) ?? [:] {
        didSet { if !isDemo { UserDefaults.standard.set(monitoring, forKey: "monitoring") } }
    }

    func monitoring(_ band: Band, _ setting: MiMonitoring.Setting) -> Data? {
        monitoring["\(band.id.uuidString).\(setting.rawValue)"]
    }

    func readMonitoring(_ band: Band) {
        start(band, .send(MiMonitoring.Setting.allCases.map(MiMonitoring.get)))
    }

    /// Writes the setting, then reads it back.
    func writeMonitoring(_ band: Band, _ setting: MiMonitoring.Setting, _ body: Data?) {
        guard let body else { return }
        start(band, .send([MiMonitoring.set(setting, body), MiMonitoring.get(setting)]))
    }

    /// Diagnostics › Probe the band: asks the read-only Health commands AstroBox names and
    /// Gadgetbridge doesn't use (6 remaining sport data, 7 user profile, 29 sport status, 42 goals, 44 basic
    /// data, 61 sleep regularity, 63 sleep disorder, 86 training status). The replies go to the
    /// log whole. (Whether an acknowledged file comes back when asked for by id was probed once
    /// and answered: it does not, docs/ACTIVITY.md section 2.6.)
    /// Diagnostics › Ask the band how it pairs (docs/BIND.md): one question, no pairing.
    func probeBindSelectedBand() {
        if let band = selectedBand() { start(band, .bindProbe) }
    }

    func probeSelectedBand() {
        if let band = selectedBand() { probe(band) }
    }

    func probe(_ band: Band) {
        let gets: [UInt64] = [6, 7, 29, 42, 44, 61, 63, 86]
        Task {
            link.note("probe: asking 8/" + gets.map(String.init).joined(separator: ", 8/"))
            start(band, .send(gets.map(MiAuth.healthGet)))
            try? await Task.sleep(for: .milliseconds(300))
            while link.phase.isBusy { try? await Task.sleep(for: .milliseconds(300)) }
            link.note("probe: done")
        }
    }

    // MARK: Stay connected and Find Phone (docs/STAY-CONNECTED.md)

    static let stayConnectedKey = "stayConnected"
    /// Clear the band after sync: files stored and parsed here are acknowledged at the next sync.
    static let clearBandKey = "clearBandAfterSync"
    /// Share location with the band: answer its location request at each sync.
    static let shareLocationKey = "shareLocation"
    /// Show sleep on the band: write the night's summary back, as Mi Fitness does.
    static let sleepToBandKey = "sleepToBand"
    private let phoneLocation = PhoneLocation()

    /// The switch; turning it on asks iOS for the location permission and a first fix.
    func setShareLocation(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.shareLocationKey)
        if on { phoneLocation.refresh() }
    }

    /// When the app comes to the front: a fresh fix for the next time the band asks.
    func refreshSharedLocation() {
        if !isDemo, UserDefaults.standard.bool(forKey: Self.shareLocationKey) { phoneLocation.refresh() }
    }
    /// Ringing stops by itself after this long.
    static let ringLimit: TimeInterval = 120

    /// The band that made the phone ring (Find Phone), by its short name; nil when quiet.
    @Published private(set) var ringingFor: String?
    var phoneRinging: Bool { ringingFor != nil }
    private let ringer = PhoneRinger()
    private let findPhoneAlert: FindPhoneAlert?
    private var ringSerial = 0

    /// Holds a session with the selected band while Stay connected is on; lets go otherwise.
    func updateHold() {
        guard !isDemo, UserDefaults.standard.bool(forKey: Self.stayConnectedKey) else {
            link.hold(nil)
            return
        }
        guard let band = selectedBand() else {
            link.note("stay connected: no band")
            link.hold(nil)
            return
        }
        guard let target = target(for: band) else {
            link.note("stay connected: no key for \(band.shortName)")
            link.hold(nil)
            return
        }
        link.hold(target)
    }

    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    /// The app is going to the background. A session the user started ends (Live would keep the
    /// band measuring). With Stay connected on, the app asks iOS for a few seconds more, so the
    /// held session can open again before the app is suspended: its retry is a timer, and timers
    /// don't run in a suspended app. Once it is open, Bluetooth events wake the app
    /// (docs/STAY-CONNECTED.md section 3).
    func enterBackground() {
        scheduleBackgroundRefresh()
        // A sync, a check or a command finishes in the background; only Live is cut short.
        if link.phase.isBusy, link.phase != .live {
            Task { await self.finishInBackground() }
        } else {
            stop()
        }
        guard !isDemo, UserDefaults.standard.bool(forKey: Self.stayConnectedKey) else { return }
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Stay connected") { [weak self] in
            self?.endBackgroundTask()
        }
        updateHold()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.backgroundGrace) { [weak self] in self?.endBackgroundTask() }
    }

    /// Enough for a session to wind down (0.4 s), the wait before the hold (2 s), and a login.
    static let backgroundGrace: TimeInterval = 20

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// The Stay connected switch. Turning it on asks for notifications, which Find Phone shows.
    func setStayConnected(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.stayConnectedKey)
        if on { findPhoneAlert?.requestPermission() }
        updateHold()
    }

    /// The band on the Band tab: the one picked there, else the first added.
    func selectedBand() -> Band? {
        let bands = (try? context.fetch(FetchDescriptor<Band>(sortBy: [SortDescriptor(\.addedAt)]))) ?? []
        let selected = UserDefaults.standard.string(forKey: "selectedBand") ?? ""
        return bands.first { $0.id.uuidString == selected } ?? bands.first
    }

    /// The band asked the phone to ring, or to stop.
    private func findPhone(_ id: UUID, _ ring: Bool) {
        guard ring else {
            endRinging(tellBand: false)
            return
        }
        guard !phoneRinging else { return }
        let name = band(id)?.shortName ?? String(localized: "Your band")
        ringingFor = name
        link.note(ringer.start() ? "ringing" : "ringing: the audio session refused, notification only")
        findPhoneAlert?.post(bandName: name)
        ringSerial += 1
        let serial = ringSerial
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.ringLimit) { [weak self] in
            guard let self, self.ringSerial == serial, self.phoneRinging else { return }
            self.link.note("ringing: stopped after \(Int(Self.ringLimit)) s")
            self.endRinging(tellBand: true)
        }
    }

    /// Stop from the app or the notification: the phone goes quiet and tells the band.
    func stopFindPhone() {
        endRinging(tellBand: true)
    }

    private func endRinging(tellBand: Bool) {
        guard phoneRinging else { return }
        ringingFor = nil
        ringSerial += 1
        ringer.stop()
        findPhoneAlert?.clear()
        if tellBand { link.stopFindPhone() }
    }

    /// Plan section 4 ("daily open"): when the app comes to the front, sync if the last sync is
    /// more than 15 minutes old, Bluetooth is on, no session is running and onboarding is done.
    func autoSyncIfNeeded(_ band: Band?, onboarded: Bool, now: Date = Date()) {
        guard onboarded, let band, link.bluetooth == .poweredOn, !link.phase.isBusy else { return }
        if let last = band.lastSyncAt, now.timeIntervalSince(last) < Self.autoSyncAfter { return }
        start(band, .sync)
    }

    static let autoSyncAfter: TimeInterval = 15 * 60

    /// For pull to refresh: starts a sync and returns when the session has ended.
    func syncAndWait(_ band: Band) async {
        guard !link.phase.isBusy else { return }
        start(band, .sync)
        try? await Task.sleep(for: .milliseconds(300))
        while link.phase.isBusy { try? await Task.sleep(for: .milliseconds(300)) }
    }

    private func record(_ id: UUID, _ draft: SampleDraft) {
        sessionDrafts.append(draft)
        context.insert(Sample(bandID: id, draft: draft))
        if draft.kind == "battery", let band = band(id) { band.lastBattery = draft.level }
        try? context.save()
    }

    /// `lastSyncAt` moves only on a complete session. Files that arrived are parsed whatever the
    /// outcome; webhooks get `sync.completed` or `sync.partial`, nothing on failure.
    private func sessionEnded(_ id: UUID, _ outcome: BandLink.Outcome) {
        if let sent = sleepWriteBack, sent.bandID == id {
            sleepWriteBack = nil
            if outcome == .complete { UserDefaults.standard.set(sent.wake, forKey: "sleepToBandWake.\(id.uuidString)") }
            return  // a single command, not a sync: nothing to parse, score or report
        }
        let drafts = sessionDrafts
        sessionDrafts = []
        guard let band = band(id) else { return }
        // Only a sync is a sync: a notification, Find or a settings read ends "complete" too.
        if outcome == .complete, link.purpose == .sync {
            band.lastSyncAt = Date()
            try? context.save()
        }
        let device = Payload.Device(band)
        Task {
            await waitForIngest()
            let parsed = sessionIngest
            sessionIngest = IngestSummary()
            runPendingRollups()
            notifyMorningSummary(id)
            writeBackSleep(id)
            if !parsed.isEmpty {
                setCalibration(makeReport(parsed, bandID: id, outcome: outcome.label))
            }
            if case .failed = outcome { return }
            let records = healthRecords(bandID: id, parsed)
            guard !drafts.isEmpty || !records.isEmpty else { return }
            await deliverWebhooks(event: outcome == .complete ? "sync.completed" : "sync.partial", device: device,
                                  drafts: drafts, records: records)
        }
    }

    /// The working key moves to the front; the band's Bluetooth name ("Xiaomi Smart Band 10 Pro
    /// D9B9") settles its name and model.
    private func identified(_ id: UUID, _ keyIndex: Int, _ name: String?) {
        var keys = Vault.bandKeys(id)
        if keyIndex > 0, keyIndex < keys.count {
            keys.insert(keys.remove(at: keyIndex), at: 0)
            Vault.setBandKeys(keys, for: id)
        }
        if let name, name.localizedCaseInsensitiveContains("band"), let band = band(id), band.name != name {
            band.name = name
            band.model = Band.modelCode(for: name)
            try? context.save()
        }
    }

    /// One band per MAC: folds bands added twice (Mi Fitness keeps several entries per band)
    /// into the oldest one, moving their samples, files, derived data and keys.
    func mergeDuplicateBands() {
        let bands = ((try? context.fetch(FetchDescriptor<Band>())) ?? []).sorted { $0.addedAt < $1.addedAt }
        var keeper: [String: Band] = [:]
        var changed = false
        for band in bands {
            guard let suffix = band.macSuffix else { continue }
            guard let first = keeper[suffix] else {
                keeper[suffix] = band
                continue
            }
            let from = band.id
            reassign(from: from, to: first.id)
            Vault.setBandKeys(Vault.bandKeys(first.id) + Vault.bandKeys(from), for: first.id)
            Vault.removeBandKey(from)
            if band.name.localizedCaseInsensitiveContains("pro"), !first.name.localizedCaseInsensitiveContains("pro") {
                first.name = band.name
                first.model = band.model
            }
            first.lastSyncAt = [first.lastSyncAt, band.lastSyncAt].compactMap { $0 }.max()
            if first.lastBattery == nil { first.lastBattery = band.lastBattery }
            if UserDefaults.standard.string(forKey: "selectedBand") == from.uuidString {
                UserDefaults.standard.set(first.id.uuidString, forKey: "selectedBand")
            }
            context.delete(band)
            changed = true
        }
        if changed { try? context.save() }
    }

    /// Moves every row of one band to another (bug fix 1). Raw files are deduplicated by file id
    /// (the newest copy stays); derived rows of both would overlap, so the keeper's derived rows
    /// and scores are dropped and its files marked for parsing again (the launch ingest rebuilds them).
    private func reassign(from: UUID, to: UUID) {
        for s in (try? context.fetch(FetchDescriptor<Sample>(predicate: #Predicate { $0.bandID == from }))) ?? [] { s.bandID = to }
        let moved = (try? context.fetch(FetchDescriptor<ActivityBlob>(predicate: #Predicate { $0.bandID == from }))) ?? []
        for b in moved { b.bandID = to }
        for r in (try? context.fetch(FetchDescriptor<MinuteDay>(predicate: #Predicate { $0.bandID == from }))) ?? [] { r.bandID = to }
        for r in (try? context.fetch(FetchDescriptor<DaySummary>(predicate: #Predicate { $0.bandID == from }))) ?? [] { r.bandID = to }
        for r in (try? context.fetch(FetchDescriptor<SleepRecord>(predicate: #Predicate { $0.bandID == from }))) ?? [] { r.bandID = to }
        for r in (try? context.fetch(FetchDescriptor<SleepRR>(predicate: #Predicate { $0.bandID == from }))) ?? [] { r.bandID = to }
        for r in (try? context.fetch(FetchDescriptor<ManualReading>(predicate: #Predicate { $0.bandID == from }))) ?? [] { r.bandID = to }
        for r in (try? context.fetch(FetchDescriptor<DailyScore>(predicate: #Predicate { $0.bandID == from }))) ?? [] { r.bandID = to }
        // Workouts are rebuilt for the keeper from the moved files; the old band's rows would be orphans.
        try? context.delete(model: Workout.self, where: #Predicate { $0.bandID == from })
        try? context.save()
        guard !moved.isEmpty else { return }

        let blobs = ((try? context.fetch(FetchDescriptor<ActivityBlob>(predicate: #Predicate { $0.bandID == to }))) ?? [])
            .sorted { $0.fetchedAt > $1.fetchedAt }
        var seen = Set<String>()
        for blob in blobs {
            if seen.insert(blob.fileID).inserted {
                blob.parserVersion = 0
                blob.parsedAt = nil
                blob.parseStatus = ParseStatus.pending.rawValue
            } else {
                context.delete(blob)
            }
        }
        ActivityIngest.deleteDerived(context: context, bandID: to, includingScores: true)
        pendingRollup[to] = DayKey.current().adding(days: -(DailyRollup.maxDays - 1))
        try? context.save()
    }

    // MARK: activity files

    private func blob(_ bandID: UUID, _ hex: String) -> ActivityBlob? {
        try? context.fetch(FetchDescriptor<ActivityBlob>(predicate: #Predicate { $0.bandID == bandID && $0.fileID == hex })).first
    }

    /// Asked for files in the band's past list only: a stored file is not fetched again unless
    /// it was last fetched from the "today" list. Such a file kept growing after that fetch (the
    /// rest of its day), so it is fetched once more now that its day is over; the copy fetched
    /// from the past list is final.
    private func hasActivityFile(_ bandID: UUID, _ hex: String) -> Bool {
        guard let blob = blob(bandID, hex) else { return false }
        return !blob.fetchedFromToday
    }

    /// Stores (or replaces: today's files grow during the day) a raw file, then parses it.
    private func storeActivityFile(_ bandID: UUID, _ file: ActivityFileID, _ data: Data, today: Bool) {
        if let existing = blob(bandID, file.hex) {
            existing.data = data
            existing.fetchedAt = Date()
            existing.parsedAt = nil
            existing.parserVersion = 0
            existing.parseStatus = ParseStatus.pending.rawValue
            existing.fetchedFromToday = today
        } else {
            let blob = ActivityBlob(bandID: bandID, id: file, data: data)
            blob.fetchedFromToday = today
            context.insert(blob)
        }
        try? context.save()
        scheduleIngest()
    }

    /// Parses pending files, one pass at a time; a request during a pass runs another after it.
    /// Scores wait until no session is running (runPendingRollups).
    func scheduleIngest() {
        if ingestTask != nil {
            ingestAgain = true
            return
        }
        ingestTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.ingestAgain = false
                let summary = await self.ingest.ingestPending()
                self.absorb(summary)
            } while self.ingestAgain
            self.ingestTask = nil
            self.runPendingRollups()
        }
    }

    private func absorb(_ summary: IngestSummary) {
        guard !summary.isEmpty else { return }
        sessionIngest.absorb(summary)
        for (band, day) in summary.earliestTouched {
            pendingRollup[band] = min(pendingRollup[band] ?? day, day)
        }
    }

    private func waitForIngest() async {
        while let task = ingestTask { await task.value }
    }

    /// Recomputes scores from the earliest touched day of each band; deferred while a session runs.
    func runPendingRollups() {
        guard !link.phase.isBusy, !pendingRollup.isEmpty else { return }
        let profile = Profile.load()
        let work = pendingRollup
        pendingRollup = [:]
        for (band, day) in work where self.band(band) != nil {
            DailyRollup.recompute(context: context, bandID: band, from: day, profile: profile)
        }
    }

    /// At launch: files below the current parser version, scores below the current algorithm.
    private func launchMaintenance() async {
        ingestBusy = true
        defer { ingestBusy = false }
        // Files 0.5.2 stored under another file's id (freeband#2): refiled, then all parsed again,
        // since minute days and sleeps merge rows from several files.
        if ingest.refileMisfiled() > 0 {
            absorb(await ingest.reparseAll())
            rescoreAll()
        }
        scheduleIngest()
        await waitForIngest()
        let quiet = !link.phase.isBusy
        let summary = sessionIngest
        if quiet { sessionIngest = IngestSummary() }
        if DailyRollup.isStale(context: context) { rescoreAll() }
        runPendingRollups()
        if quiet, !summary.isEmpty { setCalibration(makeReport(summary, bandID: nil, outcome: "launch reparse")) }
    }

    /// Every band, the last 90 days (algorithm or profile changed).
    func rescoreAll() {
        let from = DayKey.current().adding(days: -(DailyRollup.maxDays - 1))
        for band in (try? context.fetch(FetchDescriptor<Band>())) ?? [] { pendingRollup[band.id] = from }
        runPendingRollups()
    }

    /// Diagnostics: drops every derived row and score, parses every stored file again, rescores.
    func reparseAll() async {
        guard !ingestBusy else { return }
        ingestBusy = true
        defer { ingestBusy = false }
        await waitForIngest()
        // Holds the ingest slot so files stored meanwhile wait for the next pass.
        let job = Task { await self.ingest.reparseAll() }
        ingestTask = Task { _ = await job.value }
        let summary = await job.value
        ingestTask = nil
        rescoreAll()
        setCalibration(makeReport(summary, bandID: nil, outcome: "reparse all"))
        if ingestAgain {
            ingestAgain = false
            scheduleIngest()
        }
    }

    func band(_ id: UUID) -> Band? {
        try? context.fetch(FetchDescriptor<Band>(predicate: #Predicate { $0.id == id })).first
    }

    // MARK: day helpers for the UI

    /// Steps per hour of `day` (bug fix 2): from the minute file where there is one, otherwise
    /// the rise between live readings spread evenly over the time between them.
    func hourlySteps(bandID: UUID, day: Date = Date(), live: [(ts: Date, steps: Int)]) -> [Int] {
        let start = Calendar.current.startOfDay(for: day)
        let offset = TimeZone.current.secondsFromGMT(for: start) / 60
        let key = DayKey(date: start, offsetMinutes: offset)
        let index = key.index
        let row = try? context.fetch(FetchDescriptor<MinuteDay>(predicate: #Predicate { $0.bandID == bandID && $0.dayIndex == index })).first
        var minutes: [Int?]?
        if let series = row?.series {
            // The minute file is in the band's offset; move it onto the phone's day.
            let shift = Int(series.start.timeIntervalSince(start) / 60)
            if shift == 0 {
                minutes = series.steps
            } else {
                var moved = [Int?](repeating: nil, count: MinuteSeries.slots)
                for (i, v) in series.steps.enumerated() where i + shift >= 0 && i + shift < MinuteSeries.slots { moved[i + shift] = v }
                minutes = moved
            }
        }
        return HourlySteps.compute(minuteSteps: minutes, dayStart: start, readings: live)
    }

    /// The day's steps: max of the band's files and the latest live reading.
    func daySteps(bandID: UUID, day: Date = Date()) -> Int? {
        DailyRollup.steps(context: context, bandID: bandID, day: DayKey.current(day))
    }

    // MARK: day change (bug fix 3)

    private func observeDayChanges() {
        let names: [Notification.Name] = [
            .NSCalendarDayChanged, UIApplication.significantTimeChangeNotification,
            .NSSystemTimeZoneDidChange, UIApplication.willEnterForegroundNotification,
        ]
        for name in names {
            dayObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshDay() }
            })
        }
    }

    /// Publishes a new `today` when the calendar day differs from the one shown.
    func refreshDay() {
        let start = Calendar.current.startOfDay(for: Date())
        guard start != today else { return }
        today = start
        dayChanged.send(start)
    }

}
