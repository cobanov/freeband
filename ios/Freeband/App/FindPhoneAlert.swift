import Foundation
import UserNotifications

/// The Find Phone notification (docs/STAY-CONNECTED.md section 4): shown while the phone rings,
/// with a Stop action. Tapping it, Stop, or clearing it stops the ringing. It is also the fallback
/// when the audio session can't start; unlike the tone, it follows the silent switch and Focus.
final class FindPhoneAlert: NSObject, UNUserNotificationCenterDelegate {
    static let category = "find-phone"
    static let stopAction = "stop"
    static let requestID = "find-phone"

    /// On the main queue, when the user stops the ringing from the notification.
    var onStop: (() -> Void)?

    /// Becomes the notification delegate, so it has to exist from launch: a tap on Stop can launch
    /// the app in the background.
    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        let stop = UNNotificationAction(identifier: Self.stopAction, title: String(localized: "Stop ringing"), options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [stop], intentIdentifiers: [],
                                   options: [.customDismissAction]),
        ])
        center.delegate = self
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(bandName: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Find Phone")
        content.body = String(localized: "\(bandName) is looking for this phone. Tap to stop ringing.")
        content.sound = .default
        content.categoryIdentifier = Self.category
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.requestID, content: content, trigger: nil))
    }

    func clear() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.requestID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.requestID])
    }

    /// In the app, the full-screen Stop shows instead of a banner.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.content.categoryIdentifier == Self.category ? [] : [.banner, .sound])
    }

    /// The notification tapped, its Stop action, or the notification cleared.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        guard response.notification.request.content.categoryIdentifier == Self.category else {
            completionHandler()
            return
        }
        DispatchQueue.main.async {
            self.onStop?()
            completionHandler()
        }
    }
}
