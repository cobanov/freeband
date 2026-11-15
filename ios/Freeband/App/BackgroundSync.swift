import BackgroundTasks
import UIKit

/// Registers at launch, before a scene exists, including Bluetooth restoration launches.
@MainActor
final class BackgroundSync {
    static let shared = BackgroundSync()
    static let settingKey = "backgroundSyncEnabled"
    private var identifier: String { (Bundle.main.bundleIdentifier ?? "com.rfivesix.freeband") + ".background-sync" }
    private var running: Task<Void, Never>?
    private var activeToken: UUID?
    private var activeModel: AppModel?
    private var completion: ((Bool) -> Void)?
    private var expiredBeforeStart = Set<UUID>()

    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            let token = UUID()
            refresh.expirationHandler = { Task { @MainActor in self.expire(token: token, rememberIfPending: true) } }
            Task { @MainActor in
                self.schedule()
                self.begin(token: token) { success in
                    refresh.expirationHandler = nil
                    refresh.setTaskCompleted(success: success)
                }
            }
        }
        if UserDefaults.standard.bool(forKey: Self.settingKey) { schedule() }
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.settingKey)
        if enabled { schedule() } else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            expire()
        }
    }

    func sessionWillChange() { expire() }

    private func schedule() {
        guard UserDefaults.standard.bool(forKey: Self.settingKey) else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: BackgroundSyncPolicy.interval)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { AppSession.shared.model.link.note("background sync: scheduling failed: \(error.localizedDescription)") }
    }

    func bluetoothOpportunity(bandID: UUID? = nil) {
        guard UIApplication.shared.applicationState == .background,
              UserDefaults.standard.bool(forKey: Self.settingKey),
              let selected = AppSession.shared.model.selectedBand(),
              bandID == nil || selected.id == bandID, running == nil else { return }
        var identifier = UIBackgroundTaskIdentifier.invalid
        let token = UUID()
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Band sync") { [weak self] in
            Task { @MainActor in self?.expire(token: token, rememberIfPending: true) }
        }
        guard identifier != .invalid else { return }
        begin(token: token) { _ in UIApplication.shared.endBackgroundTask(identifier) }
    }

    private func begin(token: UUID, completion: @escaping (Bool) -> Void) {
        guard expiredBeforeStart.remove(token) == nil, running == nil else { completion(false); return }
        let model = AppSession.shared.model
        activeToken = token
        activeModel = model
        self.completion = completion
        running = Task {
            let success = await model.runBackgroundSync()
            self.finish(token: token, success: success)
        }
    }

    private func finish(token: UUID, success: Bool) {
        guard activeToken == token else { return }
        running = nil
        activeToken = nil
        activeModel = nil
        let callback = completion
        completion = nil
        callback?(success)
    }

    private func expire() {
        guard let token = activeToken else { return }
        expire(token: token)
    }

    private func expire(token: UUID, rememberIfPending: Bool = false) {
        guard activeToken == token else {
            if rememberIfPending { expiredBeforeStart.insert(token) }
            return
        }
        running?.cancel()
        activeModel?.expireBackgroundSync()
        finish(token: token, success: false)
    }
}
