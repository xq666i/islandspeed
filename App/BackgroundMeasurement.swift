import CoreLocation
import Foundation

// Receives location events only for the explicitly started monitoring session.
// Coordinates are never stored, logged or transmitted by this app.
@MainActor final class LocationSession: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onChange: (() -> Void)?
    private(set) var active = false
    private(set) var lastEvent: Date?
    private(set) var error: String?
    var authorization: CLAuthorizationStatus { manager.authorizationStatus }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
    }

    func requestPermission() {
        switch authorization {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
    }

    func start() {
        guard !active, authorization == .authorizedAlways else { return }
        lastEvent = nil; error = nil
        active = true
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        onChange?()
    }

    func stop() {
        active = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        onChange?()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.active && self.authorization != .authorizedAlways { self.stop() }
            self.onChange?()
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            guard let self, self.active else { return }
            self.lastEvent = Date(); self.error = nil; self.onChange?()
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, self.active else { return }
            self.error = message; self.onChange?()
        }
    }
}
