import Foundation

let now = Date(timeIntervalSince1970: 1_700_000_000)
func reason(_ enabled: Bool = true, _ bluetooth: Bool = true, _ key: Bool = true,
            _ busy: Bool = false, _ last: Date? = nil) -> String? {
    BackgroundSyncPolicy.skipReason(enabled: enabled, bluetoothReady: bluetooth, hasKey: key,
                                    busy: busy, lastSync: last, now: now)
}
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
check(reason() == nil, "first sync should run")
check(reason(false) == "disabled", "setting off")
check(reason(true, false) == "Bluetooth unavailable", "Bluetooth off")
check(reason(true, true, false) == "missing band key", "missing key")
check(reason(true, true, true, true) == "another operation is running", "concurrent session")
check(reason(true, true, true, false, now.addingTimeInterval(-899)) == "not due", "minimum interval")
check(reason(true, true, true, false, now.addingTimeInterval(-900)) == nil, "due at 15 minutes")
check(reason(true, true, true, false, now.addingTimeInterval(60)) == "not due", "future last sync")
print("Background sync policy checks passed")
