import Foundation
import CoreLocation

enum Geo {
    static let earthR = 6_371_000.0

    static func metres(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dp = p2 - p1
        let dl = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dp/2)*sin(dp/2) + cos(p1)*cos(p2)*sin(dl/2)*sin(dl/2)
        return 2 * earthR * asin(min(1, sqrt(h)))
    }

    /// Local equirectangular projection in metres around `origin`.
    static func project(_ c: CLLocationCoordinate2D, origin: CLLocationCoordinate2D) -> (x: Double, y: Double) {
        let k = cos(origin.latitude * .pi / 180)
        return ((c.longitude - origin.longitude) * .pi / 180 * earthR * k,
                (c.latitude  - origin.latitude)  * .pi / 180 * earthR)
    }

    struct Projection {
        /// Index of the polyline segment the point fell on.
        let segment: Int
        /// 0…1 position within that segment.
        let t: Double
        /// Perpendicular distance from the polyline, in metres.
        let offset: Double
        /// Distance from the start of the polyline, in metres.
        let along: Double
        let point: CLLocationCoordinate2D
    }

    /// Snap a point onto a polyline. Returns nil for degenerate input.
    static func snap(_ p: CLLocationCoordinate2D,
                     to line: [CLLocationCoordinate2D],
                     searchFrom: Int = 0) -> Projection? {
        guard line.count >= 2 else { return nil }
        let origin = p
        let pp = project(p, origin: origin)
        var best: Projection?
        var cumulative = 0.0
        var cumulativeAtBest = 0.0
        for i in 0..<(line.count - 1) {
            let a = project(line[i], origin: origin)
            let b = project(line[i+1], origin: origin)
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx*dx + dy*dy
            let segLen = sqrt(len2)
            defer { cumulative += segLen }
            guard i >= searchFrom, len2 > 0.01 else { continue }
            var t = ((pp.x - a.x)*dx + (pp.y - a.y)*dy) / len2
            t = min(1, max(0, t))
            let cx = a.x + t*dx, cy = a.y + t*dy
            let off = sqrt((pp.x-cx)*(pp.x-cx) + (pp.y-cy)*(pp.y-cy))
            if best == nil || off < best!.offset {
                let lat = line[i].latitude + (line[i+1].latitude - line[i].latitude) * t
                let lon = line[i].longitude + (line[i+1].longitude - line[i].longitude) * t
                best = Projection(segment: i, t: t, offset: off, along: 0,
                                  point: .init(latitude: lat, longitude: lon))
                cumulativeAtBest = cumulative + segLen * t
            }
        }
        guard let b = best else { return nil }
        return Projection(segment: b.segment, t: b.t, offset: b.offset,
                          along: cumulativeAtBest, point: b.point)
    }

    /// Cumulative distance to every vertex of a polyline.
    static func cumulative(_ line: [CLLocationCoordinate2D]) -> [Double] {
        var out: [Double] = [0]
        out.reserveCapacity(line.count)
        for i in 1..<max(1, line.count) {
            out.append(out[i-1] + metres(line[i-1], line[i]))
        }
        return out
    }

    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let p1 = a.latitude * .pi/180, p2 = b.latitude * .pi/180
        let dl = (b.longitude - a.longitude) * .pi/180
        let y = sin(dl)*cos(p2)
        let x = cos(p1)*sin(p2) - sin(p1)*cos(p2)*cos(dl)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// The coordinate at `along` metres from the start of a polyline, with the
    /// bearing of the segment it falls on. Used to place a vehicle smoothly
    /// between GPS fixes instead of letting it jump.
    static func point(along target: Double,
                      on line: [CLLocationCoordinate2D],
                      cumulative cum: [Double]? = nil)
        -> (coordinate: CLLocationCoordinate2D, bearing: Double)? {
        guard line.count >= 2 else { return nil }
        let cum = cum ?? cumulative(line)
        guard let total = cum.last, total > 0 else { return nil }
        let d = min(max(0, target), total)
        var i = 0
        while i + 2 < line.count && cum[i + 1] < d { i += 1 }
        let span = cum[i + 1] - cum[i]
        let t = span > 0.01 ? (d - cum[i]) / span : 0
        let a = line[i], b = line[i + 1]
        return (.init(latitude: a.latitude + (b.latitude - a.latitude) * t,
                      longitude: a.longitude + (b.longitude - a.longitude) * t),
                bearing(a, b))
    }

    /// The piece of a polyline between two along-route distances, with exact
    /// end points. Used to draw the stretch a bus still has to cover.
    static func slice(_ line: [CLLocationCoordinate2D],
                      cumulative cum: [Double],
                      from: Double, to: Double) -> [CLLocationCoordinate2D] {
        guard line.count >= 2, cum.count == line.count, to > from else { return [] }
        var out: [CLLocationCoordinate2D] = []
        if let start = point(along: from, on: line, cumulative: cum) { out.append(start.coordinate) }
        for i in 0..<line.count where cum[i] > from && cum[i] < to { out.append(line[i]) }
        if let end = point(along: to, on: line, cumulative: cum) { out.append(end.coordinate) }
        return out.count >= 2 ? out : []
    }

    /// The piece of a polyline between the projections of two coordinates.
    /// Used to cut a drawn route at a vehicle and at a stop, whichever
    /// geometry is being drawn.
    static func sliceBetween(_ line: [CLLocationCoordinate2D],
                             from a: CLLocationCoordinate2D,
                             to b: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        guard line.count >= 2, let pa = snap(a, to: line), let pb = snap(b, to: line) else { return [] }
        let cum = cumulative(line)
        return slice(line, cumulative: cum, from: pa.along, to: pb.along)
    }
}
