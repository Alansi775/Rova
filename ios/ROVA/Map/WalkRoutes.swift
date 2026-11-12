import Foundation
import MapKit

/// Real pedestrian geometry from MapKit, so walking legs follow streets
/// instead of straight lines.
@MainActor
final class WalkRouteCache: ObservableObject {
    @Published private(set) var paths: [String: [CLLocationCoordinate2D]] = [:]
    private var inFlight = Set<String>()

    static func key(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> String {
        String(format: "%.5f,%.5f>%.5f,%.5f", a.latitude, a.longitude, b.latitude, b.longitude)
    }

    func path(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> [CLLocationCoordinate2D]? {
        paths[Self.key(a, b)]
    }

    func request(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) {
        let k = Self.key(a, b)
        guard paths[k] == nil, !inFlight.contains(k) else { return }
        guard Geo.metres(a, b) > 40, Geo.metres(a, b) < 4000 else { return }
        inFlight.insert(k)
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: a))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: b))
        req.transportType = .walking
        Task {
            defer { inFlight.remove(k) }
            guard let resp = try? await MKDirections(request: req).calculate(),
                  let route = resp.routes.first else { return }
            let n = route.polyline.pointCount
            var coords = [CLLocationCoordinate2D](repeating: .init(), count: n)
            route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: n))
            paths[k] = coords
        }
    }
}
