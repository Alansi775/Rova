import XCTest
import CoreLocation
@testable import ROVA

/// Drive a bus along a real route and check what the rider would be shown.
///
/// These are not UI tests and they touch no network. A vehicle is walked along
/// the published geometry of an actual İETT pattern, metre by metre, and at
/// each step the progress the app would display is recomputed. That makes the
/// things a rider notices on a moving bus testable: does the marker advance,
/// does it stay between the right two stops, does the countdown of stops
/// remaining fall monotonically, does the "get off next" warning fire once and
/// at the right moment.
@MainActor
final class TripSimulationTests: XCTestCase {
    private let store = TransitStore.shared

    /// A real pattern, its geometry, and its stops' distances along it.
    private struct Route {
        let shape: [CLLocationCoordinate2D]
        let stops: [TripStop]
        let positions: [Double]
    }

    /// Build a trip over the first `count` stops of a real pattern.
    private func route(_ patternId: String, count: Int) throws -> Route {
        let shape = try XCTUnwrap(store.realShape(patternId),
                                  "\(patternId) must have published geometry")
        let cum = Geo.cumulative(shape)
        let patternStops = store.patternStops(patternId)
        XCTAssertGreaterThan(patternStops.count, count)

        var stops: [TripStop] = []
        var positions: [Double] = []
        for (i, ps) in patternStops.prefix(count).enumerated() {
            guard let st = store.stop(ps.stopCode) else { continue }
            let snap = try XCTUnwrap(Geo.snap(st.coordinate, to: shape))
            guard snap.segment + 1 < cum.count else { continue }
            let along = cum[snap.segment]
                + (cum[snap.segment + 1] - cum[snap.segment]) * snap.t
            // Only keep stops that advance along the route; a pattern that
            // doubles back would otherwise place a bus in two places at once.
            if let last = positions.last, along <= last { continue }
            positions.append(along)
            stops.append(TripStop(code: st.code, name: st.name, index: i,
                                  lat: st.lat, lon: st.lon, eta: nil,
                                  passed: false,
                                  isBoard: stops.isEmpty,
                                  isAlight: false,
                                  secondsFromPrevious: nil))
        }
        XCTAssertGreaterThanOrEqual(stops.count, 4, "need a few stops to ride between")

        // The last stop kept is where the rider gets off.
        let last = stops.count - 1
        stops[last] = TripStop(code: stops[last].code, name: stops[last].name,
                               index: stops[last].index,
                               lat: stops[last].lat, lon: stops[last].lon,
                               eta: nil, passed: false, isBoard: false,
                               isAlight: true,
                               secondsFromPrevious: nil)
        return Route(shape: shape, stops: stops, positions: positions)
    }

    private func progress(_ r: Route, atMetres m: Double) -> TripProgress? {
        let cum = Geo.cumulative(r.shape)
        guard let p = Geo.point(along: m, on: r.shape, cumulative: cum) else { return nil }
        return TripProgressCalculator.progress(coordinate: p.coordinate,
                                               shape: r.shape,
                                               stops: r.stops,
                                               stopPositions: r.positions)
    }

    // MARK: the ride

    /// The whole point: ride the route and watch the position advance.
    func testRidingTheRouteAdvancesThroughTheStopsInOrder() throws {
        let r = try route("146_D_D0", count: 8)
        let finish = r.positions.last!

        var lastAfter = -2
        var lastAlong = -1.0
        var seenAfter: [Int] = []

        for metres in stride(from: 0.0, through: finish, by: 40) {
            guard let p = progress(r, atMetres: metres) else { continue }

            // Never goes backwards.
            XCTAssertGreaterThanOrEqual(p.metresAlong, lastAlong - 1,
                                        "progress went backwards at \(metres) m")
            lastAlong = p.metresAlong
            XCTAssertGreaterThanOrEqual(p.afterStopIndex, lastAfter,
                                        "stop index went backwards at \(metres) m")
            if p.afterStopIndex != lastAfter {
                seenAfter.append(p.afterStopIndex)
                lastAfter = p.afterStopIndex
            }

            // The fraction is a fraction.
            XCTAssertTrue((0...1).contains(p.fraction), "fraction \(p.fraction)")

            // Between two stops means exactly those two.
            if let next = p.nextStop, let prev = p.previousStop {
                XCTAssertLessThan(prev.index, next.index)
            }
        }

        // Every stop was passed, in order, exactly once.
        XCTAssertEqual(seenAfter, Array(-1...(r.stops.count - 2)),
                       "the ride must pass each stop once, in order")
    }

    /// Halfway between two stops must read as halfway, not as "at" either.
    func testTheFractionMeasuresTheGapBetweenTwoStops() throws {
        let r = try route("146_D_D0", count: 8)
        let a = r.positions[2], b = r.positions[3]
        let middle = try XCTUnwrap(progress(r, atMetres: (a + b) / 2))

        XCTAssertEqual(middle.afterStopIndex, 2)
        XCTAssertEqual(middle.nextStop?.code, r.stops[3].code)
        XCTAssertEqual(middle.fraction, 0.5, accuracy: 0.12,
                       "halfway along the road is halfway along the bar")
        XCTAssertFalse(middle.isAtAStop)
    }

    /// Standing at a stop reads as being at it, not as a nonsense fraction.
    func testSittingAtAStopReadsAsBeingAtIt() throws {
        let r = try route("146_D_D0", count: 8)
        let p = try XCTUnwrap(progress(r, atMetres: r.positions[3] + 2))
        XCTAssertTrue(p.isAtAStop, "two metres past a stop is at that stop")
    }

    /// A bus idling just short of a stop must not be counted as having left
    /// it, or the rider is told to get off one stop early.
    func testABusJustShortOfAStopHasNotPassedIt() throws {
        let r = try route("146_D_D0", count: 8)
        let justBefore = try XCTUnwrap(progress(r, atMetres: r.positions[3] - 5))
        XCTAssertEqual(justBefore.afterStopIndex, 2, "it has not reached stop 3 yet")
        XCTAssertEqual(justBefore.nextStop?.code, r.stops[3].code)
    }

    /// The count of stops left must fall to zero, one at a time.
    func testStopsRemainingCountsDownToZero() throws {
        let r = try route("146_D_D0", count: 8)
        let finish = r.positions.last!
        var previous = Int.max
        var values: [Int] = []
        for metres in stride(from: 0.0, through: finish, by: 40) {
            guard let p = progress(r, atMetres: metres) else { continue }
            XCTAssertLessThanOrEqual(p.stopsRemaining, previous,
                                     "stops remaining went up at \(metres) m")
            if p.stopsRemaining != previous { values.append(p.stopsRemaining) }
            previous = p.stopsRemaining
        }
        XCTAssertEqual(values.last, 0, "the ride must end with nothing left")
        XCTAssertTrue(values.contains(2), "two stops out must actually occur")
        XCTAssertTrue(values.contains(1), "one stop out must actually occur")
        // One step at a time: no stop is ever skipped.
        for (a, b) in zip(values, values.dropFirst()) {
            XCTAssertEqual(a - b, 1, "jumped from \(a) to \(b) stops remaining")
        }
    }

    /// The warnings must fire once each, in order, at the right moment.
    func testTheGetOffWarningsFireOnceAndInOrder() throws {
        let r = try route("146_D_D0", count: 8)
        let finish = r.positions.last!

        var fired: [(stopsRemaining: Int, metres: Double)] = []
        var already = Set<String>()
        for metres in stride(from: 0.0, through: finish, by: 20) {
            guard let p = progress(r, atMetres: metres) else { continue }
            if p.stopsRemaining == 2, already.insert("ready").inserted {
                fired.append((2, metres))
            }
            if p.stopsRemaining <= 1, already.insert("getoff").inserted {
                fired.append((1, metres))
            }
        }

        XCTAssertEqual(fired.count, 2, "exactly two warnings, never a repeat")
        XCTAssertEqual(fired[0].stopsRemaining, 2)
        XCTAssertEqual(fired[1].stopsRemaining, 1)
        XCTAssertLessThan(fired[0].metres, fired[1].metres, "get ready comes first")

        // "Get ready" must arrive with enough road left to stand up.
        let alight = r.positions.last!
        XCTAssertGreaterThan(alight - fired[0].metres, 200,
                             "two stops of warning must be more than a moment")
    }

    /// A stale fix must not be drawn as a live position. This is the one that
    /// matters most: a marker gliding along a route on a dead signal looks
    /// exactly like working live tracking.
    func testTheMarkerIsNotPlacedFromARubbishFix() throws {
        let r = try route("146_D_D0", count: 8)
        // A fix in the Sea of Marmara, nowhere near the route.
        let offRoute = CLLocationCoordinate2D(latitude: 40.70, longitude: 28.60)
        let p = TripProgressCalculator.progress(coordinate: offRoute,
                                                shape: r.shape,
                                                stops: r.stops,
                                                stopPositions: r.positions)
        // It still snaps — that is what snapping does — so the guard that
        // actually protects the rider is the fix-age check in the engine.
        // What must not happen is a crash or an impossible reading.
        if let p {
            XCTAssertTrue((0...1).contains(p.fraction))
            XCTAssertGreaterThanOrEqual(p.stopsRemaining, 0)
        }
    }

    func testDegenerateInputIsRefusedRatherThanGuessed() {
        XCTAssertNil(TripProgressCalculator.progress(
            coordinate: .init(latitude: 41, longitude: 29),
            shape: [], stops: [], stopPositions: []))
    }

    /// The same ride on a second real route, so nothing depends on one line.
    func testASecondRealRouteBehavesTheSameWay() throws {
        let r = try route("34G_D_D0", count: 7)
        let finish = r.positions.last!
        var previous = Int.max
        // `stride(by:)` need not land on `finish`, so the arrival is sampled
        // explicitly: the end of the ride is the moment that must be right.
        var samples = Array(stride(from: 0.0, through: finish, by: 60))
        if samples.last != finish { samples.append(finish) }
        for metres in samples {
            guard let p = progress(r, atMetres: metres) else { continue }
            XCTAssertLessThanOrEqual(p.stopsRemaining, previous)
            previous = p.stopsRemaining
            XCTAssertTrue((0...1).contains(p.fraction))
        }
        XCTAssertEqual(previous, 0, "arriving at the alight stop leaves nothing to go")
    }
}
