import Foundation
import CoreLocation

/// Where you are along the ride, right now.
///
/// Not "the bus is somewhere on line 146", but: you left stop 1, you are
/// between stop 4 and stop 5, you are 60 % of the way across that gap, the
/// next stop is Yenibosna and it is two minutes off. That is what a rider
/// looking at their phone on a moving bus actually wants, and it is the one
/// thing the app could not say.
///
/// Everything here is derived from a real GPS fix snapped onto the published
/// route geometry. Nothing is interpolated from a timetable, and when the fix
/// is too old to place the bus honestly, this is nil rather than a guess that
/// keeps sliding forwards on its own.
struct TripProgress: Equatable, Sendable {
    /// Index, within the trip's stop list, of the stop just behind the bus.
    let afterStopIndex: Int
    /// The stop the bus is heading for. Nil only at the very end of the line.
    let nextStop: TripStop?
    /// The stop just behind, nil when the bus has not reached the first one.
    let previousStop: TripStop?
    /// 0 at the previous stop, 1 at the next one.
    let fraction: Double
    /// The bus's position on the route, snapped to the road.
    let coordinate: CLLocationCoordinate2D
    /// Stops still to go before the one you get off at.
    let stopsRemaining: Int
    /// When the bus is predicted at the next stop.
    let nextStopETA: Date?
    /// Metres along the whole pattern, for slicing the drawn route.
    let metresAlong: Double

    /// How far past the last stop to count as "left it", so a bus idling at a
    /// stop does not flicker between before and after.
    static let departedThresholdMetres: Double = 25

    /// Within this of a stop, the bus is at it. One bus length.
    static let arrivedThresholdMetres: Double = 20

    var isAtAStop: Bool { fraction < 0.02 || fraction > 0.98 }

    static func == (a: TripProgress, b: TripProgress) -> Bool {
        a.afterStopIndex == b.afterStopIndex
            && a.nextStop == b.nextStop
            && a.previousStop == b.previousStop
            && a.fraction == b.fraction
            && a.coordinate.latitude == b.coordinate.latitude
            && a.coordinate.longitude == b.coordinate.longitude
            && a.stopsRemaining == b.stopsRemaining
            && a.nextStopETA == b.nextStopETA
            && a.metresAlong == b.metresAlong
    }
}

/// Builds `TripProgress` from a fix and a route. Pure, so it can be tested
/// without a map, a network or a clock.
enum TripProgressCalculator {

    /// - Parameters:
    ///   - coordinate: the vehicle's position, already validated.
    ///   - shape: the published route geometry for the pattern.
    ///   - stops: the trip's stops, in order, carrying their pattern indices.
    ///   - stopPositions: distance along `shape` of each stop in `stops`.
    static func progress(coordinate: CLLocationCoordinate2D,
                         shape: [CLLocationCoordinate2D],
                         stops: [TripStop],
                         stopPositions: [Double]) -> TripProgress? {
        guard shape.count >= 2, stops.count >= 2,
              stopPositions.count == stops.count,
              let snapped = Geo.snap(coordinate, to: shape) else { return nil }

        let cum = Geo.cumulative(shape)
        guard snapped.segment + 1 < cum.count else { return nil }
        let along = cum[snapped.segment]
            + (cum[snapped.segment + 1] - cum[snapped.segment]) * snapped.t

        // The last stop the bus is genuinely past.
        var after = -1
        for (i, pos) in stopPositions.enumerated()
        where along >= pos + TripProgress.departedThresholdMetres {
            after = i
        }

        let previous = after >= 0 ? stops[after] : nil
        let nextIndex = after + 1
        let next = nextIndex < stops.count ? stops[nextIndex] : nil

        // Fraction of the gap between the two stops that has been covered.
        var fraction = 0.0
        if let next {
            let from = after >= 0 ? stopPositions[after] : 0
            let to = stopPositions[nextIndex]
            let span = to - from
            fraction = span > 1 ? min(1, max(0, (along - from) / span)) : 0
        } else {
            fraction = 1
        }

        // Stops still to be reached before getting off.
        //
        // A stop counts as reached the moment the bus is at it, not when it
        // pulls away: standing at your own stop must read as nothing left, and
        // the simulation caught this sticking at 1 for the whole arrival.
        // Using the same "arrived" moment at every stop keeps the count
        // falling one at a time, with no jump as the bus departs.
        let alightIndex = stops.firstIndex(where: \.isAlight) ?? (stops.count - 1)
        // Measured in metres, not as a fraction of the gap: a fraction is
        // sensitive to floating-point error exactly at the endpoint, which is
        // the one place this has to be right — the rider standing at their own
        // stop. Twenty metres is the length of a bus.
        let arrivedAtNext = (next != nil
            && stopPositions[nextIndex] - along <= TripProgress.arrivedThresholdMetres)
            ? 1 : 0
        let remaining = max(0, alightIndex - max(0, nextIndex) + 1 - arrivedAtNext)

        return TripProgress(
            afterStopIndex: after,
            nextStop: next,
            previousStop: previous,
            fraction: fraction,
            coordinate: snapped.point,
            stopsRemaining: remaining,
            nextStopETA: next?.eta,
            metresAlong: along)
    }
}
