import CoreLocation

/// The phone's last known location, for a band that asks for it (Command{16,3},
/// docs/CAPABILITIES.md section 9.7). Asked for only while the app is in use, kept in memory,
/// and sent nowhere but to the band, and only when the user turned that on.
final class PhoneLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var last: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Asks for permission the first time, then for one fix.
    func refresh() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
        default: break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        last = locations.last ?? last
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
