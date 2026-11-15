import Foundation

/// Shared eligibility rules for scheduled and Bluetooth-triggered opportunities.
enum BackgroundSyncPolicy {
    static let interval: TimeInterval = 15 * 60

    static func skipReason(enabled: Bool, bluetoothReady: Bool, hasKey: Bool, busy: Bool,
                           lastSync: Date?, now: Date) -> String? {
        if !enabled { return "disabled" }
        if !bluetoothReady { return "Bluetooth unavailable" }
        if !hasKey { return "missing band key" }
        if busy { return "another operation is running" }
        if let lastSync, now.timeIntervalSince(lastSync) < interval { return "not due" }
        return nil
    }
}
