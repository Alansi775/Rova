import Foundation
import CoreLocation

@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var current: CLLocation?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 25
        authorization = manager.authorizationStatus
    }

    func request() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            start()
        }
    }

    func start() {
        guard authorization == .authorizedWhenInUse || authorization == .authorizedAlways else { return }
        manager.startUpdatingLocation()
    }

    func stop() { manager.stopUpdatingLocation() }

    /// Keep running while a trip is under way, even with the app in the
    /// background.
    ///
    /// Without this, iOS suspends the app within seconds of the rider opening
    /// anything else — and scrolling Instagram on the bus is the normal case,
    /// not the exception. A suspended app computes no progress, so the Lock
    /// Screen stops moving, the spoken announcement never happens, and the
    /// "get off next" warning never fires. The rider misses the stop while
    /// holding a phone that is apparently tracking the journey.
    ///
    /// `pausesLocationUpdatesAutomatically` is turned off for the same
    /// reason: iOS pauses updates when it decides movement has stopped, and a
    /// bus in traffic looks exactly like that.
    ///
    /// It is switched on only for the duration of a trip. Background location
    /// is the most expensive thing this app can ask of a battery, and asking
    /// for it while nobody is riding anywhere would not be defensible.
    func beginBackgroundTracking() {
        guard authorization == .authorizedWhenInUse || authorization == .authorizedAlways
        else { return }
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        manager.startUpdatingLocation()
    }

    /// Back to the cheaper settings once the ride is over.
    func endBackgroundTracking() {
        manager.allowsBackgroundLocationUpdates = false
        manager.pausesLocationUpdatesAutomatically = true
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 25
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let status = m.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            self.start()
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let l = locs.last else { return }
        Task { @MainActor in self.current = l }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}
