import Foundation
import MapKit
import CoreLocation

/// Measured walking time from a point to a stop.
///
/// The planner estimates a walk as `straightLineMetres × 1.32 ÷ 1.30 m/s`:
/// a guessed detour factor over a guessed pace, applied to a distance that is
/// not the walking distance at all. That number then decides **when the app
/// tells you to leave the house**, which makes it the most consequential
/// figure ROVA produces and the least defensible way to produce it.
///
/// A straight line of 800 m across a block can be 1 100 m of pavement with a
/// crossing and a footbridge. At that size the estimate is wrong by minutes,
/// in the one place where minutes are the entire point.
///
/// So the walk that drives "leave now" is measured: Apple is asked for actual
/// pedestrian directions, which account for real streets, crossings and the
/// fact that you cannot walk through a building.
///
/// When Apple cannot answer — no coverage, no network, a stop in a place with
/// no pedestrian routing — nothing is invented. The estimate stays, and it is
/// **labelled as an estimate** so the difference is visible rather than
/// hidden behind a confident-looking number.
@MainActor
final class WalkTimes: ObservableObject {
    static let shared = WalkTimes()

    struct Walk: Equatable, Sendable {
        let seconds: Int
        let metres: Double
        /// True when Apple returned a real pedestrian route; false when this
        /// is the planner's straight-line estimate.
        let isMeasured: Bool
    }

    @Published private(set) var walks: [String: Walk] = [:]
    private var inFlight: Set<String> = []

    private func key(_ from: CLLocationCoordinate2D, _ stopCode: String) -> String {
        // Round the origin: walking from two points four metres apart is the
        // same walk, and a key that changes with GPS jitter would request the
        // same route forever.
        String(format: "%.4f,%.4f→%@", from.latitude, from.longitude, stopCode)
    }

    /// The measured walk if it is known. Requests it in the background if not.
    func walk(from: CLLocationCoordinate2D, to stop: Stop) -> Walk? {
        let k = key(from, stop.code)
        if let w = walks[k] { return w }
        request(k, from: from, to: stop)
        return nil
    }

    private func request(_ k: String, from: CLLocationCoordinate2D, to stop: Stop) {
        guard !inFlight.contains(k) else { return }
        // A walk of a few metres is not worth a request, and Apple often
        // refuses to route one.
        guard Geo.metres(from, stop.coordinate) > 60 else { return }
        inFlight.insert(k)
        Task { [weak self] in
            let result = await Self.measure(from: from, to: stop.coordinate)
            guard let self else { return }
            inFlight.remove(k)
            if let result { walks[k] = result }
        }
    }

    private nonisolated static func measure(
        from: CLLocationCoordinate2D, to: CLLocationCoordinate2D
    ) async -> Walk? {
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        req.transportType = .walking
        req.requestsAlternateRoutes = false
        guard let route = try? await MKDirections(request: req).calculate(),
              let r = route.routes.first else { return nil }

        // Sanity against the ground. A pedestrian route five times the
        // straight line is Apple routing around something it should not, or
        // routing by road; either way it is worse than the estimate.
        let straight = Geo.metres(from, to)
        guard r.distance < max(400, straight * 4) else { return nil }
        // Apple's expectedTravelTime for walking assumes a pace of its own.
        // It is still a measurement of a real route rather than a guess about
        // the distance, which is where the large error lives.
        guard r.expectedTravelTime > 0, r.expectedTravelTime < 7200 else { return nil }

        return Walk(seconds: Int(r.expectedTravelTime.rounded()),
                    metres: r.distance,
                    isMeasured: true)
    }
}
