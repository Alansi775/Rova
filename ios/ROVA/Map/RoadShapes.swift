import Foundation
import MapKit
import CoreLocation

/// Road-following geometry for a bus pattern.
///
/// İETT publishes no route geometry at all — its GTFS export has no
/// `shapes.txt`, and the network SOAP service returns only stops, lines and
/// garages (verified against the WSDL). So the route could only be drawn as
/// straight lines from stop to stop, which cuts across blocks and water and
/// looks nothing like the road the bus actually drives.
///
/// This fills the gap by asking Apple Maps for driving directions between each
/// pair of consecutive stops and stitching the results together. It is
/// therefore *the road a vehicle would take between those two stops*, not a
/// published İETT alignment — close to the truth and honest about what it is.
/// Nothing here feeds the ETA: all timing still comes from the stop sequence
/// and the schedule.
///
/// Each pattern is resolved once and cached on disk, so it costs nothing after
/// the first time.
@MainActor
final class RoadShapes: ObservableObject {
    static let shared = RoadShapes()

    @Published private(set) var shapes: [String: [CLLocationCoordinate2D]] = [:]
    private var building: Set<String> = []

    private let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("road-shapes", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// The road geometry for a pattern, or nil while it is still being built.
    func shape(_ patternId: String, stops: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D]? {
        if let s = shapes[patternId] { return s }
        if let s = loadFromDisk(patternId) { shapes[patternId] = s; return s }
        build(patternId, stops: stops)
        return nil
    }

    private func build(_ patternId: String, stops: [CLLocationCoordinate2D]) {
        guard stops.count >= 2, !building.contains(patternId) else { return }
        building.insert(patternId)
        Task { [weak self] in
            let built = await Self.route(through: stops)
            guard let self else { return }
            building.remove(patternId)
            guard built.path.count >= 2 else { return }
            // If a quarter of the route could not be resolved to roads, the
            // result is a mix of real roads and lines through buildings, which
            // reads as a broken map. Keep the honest stop sequence instead and
            // try again next launch, rather than caching something half wrong.
            let segments = max(1, stops.count - 1)
            guard Double(built.straightSegments) / Double(segments) <= 0.25 else { return }
            shapes[patternId] = built.path
            saveToDisk(patternId, built.path)
        }
    }

    /// Serial, with a small gap: Apple throttles bursts of directions requests,
    /// and a pattern only ever has to be resolved once.
    private nonisolated static func route(
        through stops: [CLLocationCoordinate2D]
    ) async -> (path: [CLLocationCoordinate2D], straightSegments: Int) {
        var out: [CLLocationCoordinate2D] = []
        var straight = 0
        for i in 0..<(stops.count - 1) {
            var seg = await segment(stops[i], stops[i + 1])
            if seg == nil { straight += 1; seg = [stops[i], stops[i + 1]] }
            if out.isEmpty { out += seg! }
            else { out += seg!.dropFirst() }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return (out, straight)
    }

    private nonisolated static func segment(
        _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D
    ) async -> [CLLocationCoordinate2D]? {
        // Stops a few metres apart are not worth a request.
        guard Geo.metres(a, b) > 40 else { return nil }
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: a))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: b))
        req.transportType = .automobile
        req.requestsAlternateRoutes = false
        // Apple throttles bursts, and a single refusal used to leave a straight
        // line through the buildings for good. One retry, then give up.
        var resp = try? await MKDirections(request: req).calculate()
        if resp == nil {
            try? await Task.sleep(nanoseconds: 900_000_000)
            resp = try? await MKDirections(request: req).calculate()
        }
        guard let route = resp?.routes.first else { return nil }
        // Only an absurd detour is rejected — a route five times the straight
        // line is Apple sending a car the long way round a restricted street.
        // Rejecting more than that was leaving straight segments cutting
        // across blocks, which is exactly what looked wrong on the map.
        guard route.distance < max(900, Geo.metres(a, b) * 5) else { return nil }
        let line = route.polyline
        var coords = [CLLocationCoordinate2D](repeating: .init(), count: line.pointCount)
        line.getCoordinates(&coords, range: NSRange(location: 0, length: line.pointCount))
        return coords
    }

    // MARK: disk cache

    private func file(_ id: String) -> URL {
        dir.appendingPathComponent(id.replacingOccurrences(of: "/", with: "_") + ".json")
    }

    private func loadFromDisk(_ id: String) -> [CLLocationCoordinate2D]? {
        guard let d = try? Data(contentsOf: file(id)),
              let pairs = try? JSONDecoder().decode([[Double]].self, from: d),
              pairs.count >= 2 else { return nil }
        return pairs.compactMap { $0.count == 2 ? .init(latitude: $0[0], longitude: $0[1]) : nil }
    }

    private func saveToDisk(_ id: String, _ path: [CLLocationCoordinate2D]) {
        let pairs = path.map { [$0.latitude, $0.longitude] }
        if let d = try? JSONEncoder().encode(pairs) { try? d.write(to: file(id)) }
    }
}
