import XCTest
import CoreLocation
@testable import ROVA

// MARK: - Bundled network

final class TransitStoreTests: XCTestCase {
    let store = TransitStore.shared

    func testBundleLoads() {
        XCTAssertTrue(store.isReady, "the transit bundle must ship with the app")
        XCTAssertGreaterThan(store.stops.count, 14_000)
        XCTAssertGreaterThan(store.lines.count, 700)
        XCTAssertGreaterThan(store.patterns.count, 2_000)
    }

    func testVerifiedOriginHasANearbyStop() {
        let near = store.stopsNear(DefaultJourney.origin.coordinate, radius: 300)
        XCTAssertFalse(near.isEmpty, "Şafak Residence must have İETT stops within 300 m")
        let closest = near[0]
        XCTAssertLessThan(closest.1, 200)
        // The resolved address is on Adile Naşit Bulvarı, and so is the stop.
        XCTAssertTrue(closest.0.name.uppercased().contains("ADİLE NAŞİT"),
                      "unexpected nearest stop: \(closest.0.name)")
    }

    func testVerifiedDestinationIsTheMetrobusStop() {
        let near = store.stopsNear(DefaultJourney.destination.coordinate, radius: 120)
        XCTAssertTrue(near.contains { $0.0.name.uppercased().contains("AVCILAR METROBÜS") },
                      "Avcılar Metrobüs stop must be within 120 m of the saved destination")
    }

    func testPatternStopsAreOrderedAndMonotonic() {
        let pattern = store.patterns.values.first { $0.line == "146" && $0.direction == "G" }
        let stops = store.patternStops(pattern!.id)
        XCTAssertGreaterThan(stops.count, 10)
        for i in 1..<stops.count {
            XCTAssertEqual(stops[i].seq, stops[i-1].seq + 1)
            XCTAssertGreaterThanOrEqual(stops[i].offsetSec, stops[i-1].offsetSec,
                                        "scheduled offsets must never go backwards")
        }
    }

    func testNearbySearchIsOrderedByDistance() {
        let near = store.stopsNear(DefaultJourney.origin.coordinate, radius: 1500)
        let distances = near.map(\.1)
        XCTAssertEqual(distances, distances.sorted())
    }

    func testTodayHasActiveServices() {
        XCTAssertFalse(store.activeServices(on: Date()).isEmpty,
                       "the bundled calendar must cover today")
    }
}

// MARK: - Geometry

final class GeoTests: XCTestCase {
    func testKnownDistance() {
        let d = Geo.metres(DefaultJourney.origin.coordinate, DefaultJourney.destination.coordinate)
        XCTAssertEqual(d, 4800, accuracy: 300)
    }

    func testSnapFindsTheNearestSegment() {
        let line = [CLLocationCoordinate2D(latitude: 41.0, longitude: 28.70),
                    CLLocationCoordinate2D(latitude: 41.0, longitude: 28.80),
                    CLLocationCoordinate2D(latitude: 41.1, longitude: 28.80)]
        let p = Geo.snap(.init(latitude: 41.0005, longitude: 28.75), to: line)!
        XCTAssertEqual(p.segment, 0)
        XCTAssertEqual(p.t, 0.5, accuracy: 0.1)
        XCTAssertLessThan(p.offset, 80)
    }

    func testSnapRejectsDegenerateInput() {
        XCTAssertNil(Geo.snap(.init(latitude: 41, longitude: 28), to: []))
    }

    func testCumulativeIsMonotonic() {
        let line = (0..<5).map { CLLocationCoordinate2D(latitude: 41, longitude: 28.7 + Double($0) * 0.01) }
        let cum = Geo.cumulative(line)
        XCTAssertEqual(cum.first, 0)
        for i in 1..<cum.count { XCTAssertGreaterThan(cum[i], cum[i-1]) }
    }
}

// MARK: - Planner

final class PlannerTests: XCTestCase {
    func testPlansTheRealJourney() {
        let planner = JourneyPlanner(store: TransitStore.shared)
        let options = planner.plan(from: DefaultJourney.origin.coordinate,
                                   to: DefaultJourney.destination.coordinate)
        XCTAssertFalse(options.isEmpty, "Şafak Residence → Avcılar Metrobüs must be solvable")

        let best = options[0]
        XCTAssertFalse(best.busLegs.isEmpty)
        XCTAssertLessThan(best.walkMetres, 1600)
        XCTAssertGreaterThan(best.rideSeconds, 180)
        XCTAssertLessThan(best.rideSeconds, 60 * 60)

        // The planner must actually board at a stop near home.
        let board = best.firstBoardStop!
        XCTAssertLessThan(Geo.metres(board.coordinate, DefaultJourney.origin.coordinate), 1100)

        // And alight near the destination.
        let alight = best.busLegs.last!.alightStop!
        XCTAssertLessThan(Geo.metres(alight.coordinate, DefaultJourney.destination.coordinate), 1100)
    }

    func testOptionsAreDistinctAndRanked() {
        let planner = JourneyPlanner(store: TransitStore.shared)
        let options = planner.plan(from: DefaultJourney.origin.coordinate,
                                   to: DefaultJourney.destination.coordinate)
        let keys = options.map { $0.lineCodes.joined(separator: ">") + ($0.firstBoardStop?.code ?? "") }
        XCTAssertEqual(Set(keys).count, keys.count, "duplicate itineraries must be collapsed")
        XCTAssertTrue(options.contains { $0.transfers == 0 }, "a direct bus exists on this corridor")
    }

    func testUnreachablePairReturnsNothingRatherThanNonsense() {
        let planner = JourneyPlanner(store: TransitStore.shared)
        // Middle of the Black Sea.
        let options = planner.plan(from: .init(latitude: 42.6, longitude: 29.8),
                                   to: DefaultJourney.destination.coordinate)
        XCTAssertTrue(options.isEmpty)
    }

    func testLegGeometryFollowsStops() {
        let planner = JourneyPlanner(store: TransitStore.shared)
        let best = planner.plan(from: DefaultJourney.origin.coordinate,
                                to: DefaultJourney.destination.coordinate).first!
        let leg = best.busLegs.first!
        XCTAssertGreaterThan(leg.shape.count, 2)
        XCTAssertEqual(leg.shape.count, leg.intermediateStops + 1)
    }
}

// MARK: - Live client parsing

final class LiveParsingTests: XCTestCase {
    /// Captured verbatim from the İETT service on 2026-11-12 at 04:30 Istanbul.
    static let captured = """
    [{"kapino":"B-1887","boylam":"28.66874","enlem":"41.06737","hatkodu":"146",\
    "guzergahkodu":"146_G_D6038","hatad":"BOĞAZKÖY / BAHÇEŞEHİR - BAKIRKÖY",\
    "yon":"BOĞAZKÖY SON DURAK","son_konum_zamani":"2026-11-12 04:30:54",\
    "yakinDurakKodu":"128071"}]
    """

    func testParsesRealPayload() {
        let v = IETTLiveClient.parse(json: Self.captured, requestedLine: "146")
        XCTAssertEqual(v.count, 1)
        XCTAssertEqual(v[0].doorNo, "B-1887")
        XCTAssertEqual(v[0].lineCode, "146")
        XCTAssertEqual(v[0].patternId, "146_G_D6038")
        XCTAssertEqual(v[0].lat, 41.06737, accuracy: 0.00001)
        XCTAssertEqual(v[0].nearStopCode, "128071")
    }

    func testParsedPatternExistsInTheBundle() {
        let v = IETTLiveClient.parse(json: Self.captured, requestedLine: "146")[0]
        XCTAssertNotNil(TransitStore.shared.patterns[v.patternId],
                        "live guzergahkodu must map onto a bundled pattern")
    }

    func testEmptyListIsNotAnError() {
        XCTAssertTrue(IETTLiveClient.parse(json: "[]", requestedLine: "142").isEmpty)
    }

    func testRejectsPlaceholderCoordinates() {
        let json = #"[{"kapino":"X","enlem":"0","boylam":"0","son_konum_zamani":"2026-11-12 04:30:54"}]"#
        XCTAssertTrue(IETTLiveClient.parse(json: json, requestedLine: "146").isEmpty)
    }

    func testIstanbulTimestampIsUTCPlus3() {
        let d = IETTLiveClient.parseDate("2026-11-12 04:30:54")!
        XCTAssertEqual(d.timeIntervalSince1970, 1794447054, accuracy: 1)  // 2026-11-12T01:30:54Z
    }

    func testBudgetStopsAtTheLimit() {
        let budget = RequestBudget(limitPerHour: 3)
        XCTAssertTrue(budget.consume())
        XCTAssertTrue(budget.consume())
        XCTAssertTrue(budget.consume())
        XCTAssertFalse(budget.consume(), "must not exceed the İETT hourly limit")
        XCTAssertEqual(budget.remaining, 0)
    }
}

// MARK: - ETA engine

final class ETATests: XCTestCase {
    let store = TransitStore.shared
    lazy var engine = ETAEngine(store: store)

    /// A real İETT pattern from the bundle, used as the test corridor.
    private func corridor() -> (Pattern, [PatternStop], [CLLocationCoordinate2D]) {
        let pattern = store.patterns.values
            .filter { $0.line == "146" && $0.stopCount > 15 }
            .sorted { $0.id < $1.id }[0]
        let stops = store.patternStops(pattern.id)
        let shape = store.patternShape(pattern.id)
        return (pattern, stops, shape)
    }

    private func vehicle(at index: Int, shape: [CLLocationCoordinate2D],
                         ageSeconds: TimeInterval = 0, pattern: String,
                         latOffset: Double = 0) -> Vehicle {
        Vehicle(doorNo: "B-TEST", lat: shape[index].latitude + latOffset,
                lon: shape[index].longitude, lineCode: "146", patternId: pattern,
                lineName: "TEST", direction: "G",
                lastFix: Date().addingTimeInterval(-ageSeconds), nearStopCode: nil)
    }

    /// The "0–47 min" range, and the false "leave now" it produced.
    ///
    /// `leaveInSeconds` is measured against the early end of the range, so a
    /// lower bound of zero tells someone to leave immediately for a bus that
    /// is kilometres away. The early end must be bounded by the road.
    func testEarlyEndOfRangeIsBoundedByDistance() throws {
        let (p, stops, shape) = corridor()
        guard stops.count > 14, shape.count > 2 else {
            throw XCTSkip("pattern too short")
        }
        let v = vehicle(at: 0, shape: shape, pattern: p.id)
        guard let eta = engine.estimate(vehicle: v, pattern: p,
                                        stopIndex: 13, history: nil),
              let remaining = eta.remainingMetres, remaining > 500 else {
            throw XCTSkip("no distant estimate available in this corridor")
        }

        // Soonest physically possible: remaining distance at the fastest a
        // city bus could conceivably average.
        let floorMinutes = remaining / engine.maxConceivableSpeed / 60
        XCTAssertGreaterThanOrEqual(
            eta.rangeMinutes.lowerBound, floorMinutes - 0.01,
            "a bus \(Int(remaining)) m away cannot arrive in \(eta.rangeMinutes.lowerBound) min")
        XCTAssertGreaterThan(eta.rangeMinutes.lowerBound, 0,
                             "a distant bus must never show an early bound of zero")
    }

    /// The headline must always lie inside its own range.
    ///
    /// A screenshot showed "8 min" above "21–293 min": a figure outside its
    /// own interval. That is worse than either number alone, because it tells
    /// the reader the app is not internally consistent.
    func testPredictionAlwaysLiesInsideItsOwnRange() {
        let (p, stops, shape) = corridor()
        guard stops.count > 16 else { return }
        for ageSeconds in [0.0, 60, 200, 400, 800] {
            for target in [2, 6, 11, 15] {
                let v = vehicle(at: 0, shape: shape, ageSeconds: ageSeconds, pattern: p.id)
                guard let e = engine.estimate(vehicle: v, pattern: p,
                                              stopIndex: target, history: nil) else { continue }
                XCTAssertGreaterThanOrEqual(
                    e.predictedMinutes, e.rangeMinutes.lowerBound - 0.001,
                    "age \(ageSeconds)s, stop \(target): "
                    + "\(e.predictedMinutes) is below its range \(e.rangeMinutes)")
                XCTAssertLessThanOrEqual(
                    e.predictedMinutes, e.rangeMinutes.upperBound + 0.001,
                    "age \(ageSeconds)s, stop \(target): "
                    + "\(e.predictedMinutes) is above its range \(e.rangeMinutes)")
            }
        }
    }

    /// İETT keeps publishing the last position of buses that finished hours
    /// ago. One of those must never be described as approaching.
    func testFixFromHoursAgoProducesNoEstimate() {
        let (p, stops, shape) = corridor()
        guard stops.count > 6 else { return }
        // 466 minutes: the age shown on screen beside an "8 min" arrival.
        let dead = vehicle(at: 0, shape: shape, ageSeconds: 466 * 60, pattern: p.id)
        XCTAssertNil(engine.estimate(vehicle: dead, pattern: p, stopIndex: 5, history: nil),
                     "a fix 466 minutes old is not evidence about where a bus is now")

        // And the boundary is where it says it is.
        let justInside = vehicle(at: 0, shape: shape,
                                 ageSeconds: engine.maxUsableFixAge - 30, pattern: p.id)
        XCTAssertNotNil(engine.estimate(vehicle: justInside, pattern: p,
                                        stopIndex: 5, history: nil),
                        "a fix inside the limit must still be usable")
    }

    func testEstimateUsesScheduledRunningTime() {
        let (p, stops, shape) = corridor()
        let v = vehicle(at: 2, shape: shape, pattern: p.id)
        let eta = engine.estimate(vehicle: v, pattern: p, stopIndex: 8, history: nil)
        XCTAssertNotNil(eta)
        let scheduled = Double(stops[8].offsetSec - stops[2].offsetSec) / 60
        XCTAssertEqual(eta!.predictedMinutes, scheduled, accuracy: max(1.5, scheduled * 0.2))
        XCTAssertEqual(eta!.stopsAway, 6)
    }

    func testStaleFixReducesEstimateAndConfidence() {
        let (p, _, shape) = corridor()
        let fresh = engine.estimate(vehicle: vehicle(at: 2, shape: shape, pattern: p.id),
                                    pattern: p, stopIndex: 8, history: nil)!
        let stale = engine.estimate(vehicle: vehicle(at: 2, shape: shape, ageSeconds: 400, pattern: p.id),
                                    pattern: p, stopIndex: 8, history: nil)!
        XCTAssertLessThan(stale.predictedMinutes, fresh.predictedMinutes)
        XCTAssertLessThanOrEqual(stale.confidence, fresh.confidence)
        XCTAssertNotNil(stale.lowConfidenceReason)
        XCTAssertTrue(stale.lowConfidenceReason!.contains("GPS fix is"),
                      "staleness must be the stated reason, got: \(stale.lowConfidenceReason!)")
        if case .delayedData = stale.state {} else { XCTFail("expected delayedData at 400 s") }
    }

    func testVeryOldFixIsLowConfidence() {
        let (p, _, shape) = corridor()
        let eta = engine.estimate(vehicle: vehicle(at: 2, shape: shape, ageSeconds: 700, pattern: p.id),
                                  pattern: p, stopIndex: 8, history: nil)!
        XCTAssertEqual(eta.confidence, .low)
        if case .delayedData = eta.state {} else { XCTFail("expected delayedData, got \(eta.state)") }
    }

    func testRangeWidensWithStaleness() {
        let (p, _, shape) = corridor()
        let span = { (e: ETA) in e.rangeMinutes.upperBound - e.rangeMinutes.lowerBound }
        let fresh = engine.estimate(vehicle: vehicle(at: 2, shape: shape, pattern: p.id),
                                    pattern: p, stopIndex: 8, history: nil)!
        let stale = engine.estimate(vehicle: vehicle(at: 2, shape: shape, ageSeconds: 200, pattern: p.id),
                                    pattern: p, stopIndex: 8, history: nil)!
        XCTAssertGreaterThan(span(stale), span(fresh))
    }

    func testBusPastTheStopProducesNoEstimate() {
        let (p, _, shape) = corridor()
        let v = vehicle(at: 12, shape: shape, pattern: p.id)
        XCTAssertNil(engine.estimate(vehicle: v, pattern: p, stopIndex: 4, history: nil))
    }

    func testOffRouteVehicleIsRejected() {
        let (p, _, shape) = corridor()
        let v = vehicle(at: 2, shape: shape, pattern: p.id, latOffset: 0.02)   // ≈ 2.2 km away
        XCTAssertNil(engine.estimate(vehicle: v, pattern: p, stopIndex: 8, history: nil))
    }

    func testDataStateThresholds() {
        XCTAssertTrue(DataState.forFix(age: 30).isLive)
        if case .recentlyUpdated = DataState.forFix(age: 200) {} else { XCTFail() }
        if case .delayedData = DataState.forFix(age: 400) {} else { XCTFail() }
        XCTAssertFalse(DataState.forFix(age: 400).isLive)
    }

    func testStateLabelsNeverClaimLiveWhenStale() {
        XCTAssertEqual(DataState.forFix(age: 400).label, "Delayed data")
        XCTAssertEqual(DataState.scheduledOnly.label, "Scheduled only")
        XCTAssertFalse(DataState.scheduledOnly.isLive)
    }

    func testHistoryMeasuresProgressAgainstTimetable() {
        let (p, stops, shape) = corridor()
        var history = VehicleHistory()
        let now = Date()
        // Scheduled gap between the two stops …
        let scheduled = Double(stops[3].offsetSec - stops[1].offsetSec)
        guard scheduled > 60 else { return }
        // … covered in twice that time.
        history.record(Vehicle(doorNo: "B", lat: shape[1].latitude, lon: shape[1].longitude,
                               lineCode: "146", patternId: p.id, lineName: "", direction: "",
                               lastFix: now.addingTimeInterval(-scheduled * 2), nearStopCode: nil))
        history.record(Vehicle(doorNo: "B", lat: shape[3].latitude, lon: shape[3].longitude,
                               lineCode: "146", patternId: p.id, lineName: "", direction: "",
                               lastFix: now, nearStopCode: nil))
        let ratio = history.progressRatio(shape: shape, patternStops: stops)
        XCTAssertNotNil(ratio)
        XCTAssertEqual(ratio!, 2.0, accuracy: 0.6)
    }

    func testCandidateRankingPrefersTheNearerBus() {
        let (p, _, shape) = corridor()
        let stops = store.patternStops(p.id)
        let board = store.stop(stops[10].stopCode)!
        let near = vehicle(at: 8, shape: shape, pattern: p.id)
        let far = Vehicle(doorNo: "B-FAR", lat: shape[2].latitude, lon: shape[2].longitude,
                          lineCode: "146", patternId: p.id, lineName: "", direction: "",
                          lastFix: Date(), nearStopCode: nil)
        let ranked = engine.candidates(vehicles: [far, near], lineCode: "146",
                                       boardStop: board, preferredPattern: p.id, histories: [:])
        XCTAssertEqual(ranked.first?.vehicle.doorNo, "B-TEST")
    }
}

// MARK: - Formatting

final class ModeTests: XCTestCase {

    /// Every 34* line in the bundled network is a Metrobüs corridor, and the
    /// mode rule is checked against the real data rather than a hand-written
    /// list that could drift away from it.
    func testEveryThirtyFourLineIsMetrobus() {
        let store = TransitStore.shared
        let codes = store.patterns.values.map(\.line).filter { $0.hasPrefix("34") }
        XCTAssertFalse(codes.isEmpty, "the bundle must contain Metrobüs lines")
        for c in Set(codes) {
            XCTAssertEqual(TransitMode.of(line: c), .metrobus,
                           "\(c) should be recognised as Metrobüs")
        }
    }

    func testOrdinaryLinesAreNotMetrobus() {
        for c in ["146", "142", "76O", "HS2", "144A", "340"] {
            XCTAssertEqual(TransitMode.of(line: c), .bus,
                           "\(c) must not be treated as Metrobüs")
        }
    }

    /// The trap that made the app look like it was lying: a stop named after
    /// the Metrobüs that no Metrobüs calls at. The app must be able to state
    /// what really serves a stop.
    func testStopNamedAfterTheMetrobusIsNotServedByIt() {
        let store = TransitStore.shared
        let lines = store.linesCalling(at: "101452")   // "AVCILAR METROBÜS"
        XCTAssertFalse(lines.isEmpty, "the stop must be served by something")
        XCTAssertFalse(lines.contains { TransitMode.of(line: $0) == .metrobus },
                       "no Metrobüs calls at 101452 — the name is misleading, "
                       + "which is exactly why the lines are shown in search")
    }

    /// And the real platforms are served by it.
    func testRealMetrobusPlatformIsServedByMetrobus() {
        let lines = TransitStore.shared.linesCalling(at: "900332")
        XCTAssertTrue(lines.contains { TransitMode.of(line: $0) == .metrobus },
                      "900332 is a Metrobüs platform; got \(lines)")
    }
}

final class FormatTests: XCTestCase {
    func testDurations() {
        XCTAssertEqual(Fmt.duration(20), "now")
        XCTAssertEqual(Fmt.duration(300), "5 min")
        XCTAssertEqual(Fmt.duration(3900), "1 h 05")
    }
    func testDistances() {
        XCTAssertEqual(Fmt.distance(108), "110 m")
        XCTAssertEqual(Fmt.distance(4800), "4.8 km")
    }
    func testAges() {
        XCTAssertEqual(Fmt.age(42), "42s ago")
        XCTAssertEqual(Fmt.age(125), "2m 5s ago")
    }
}

// MARK: - Continuity and motion (added after the first device test)

final class MotionTests: XCTestCase {

    private func veh(_ door: String, _ lat: Double, _ lon: Double, ageSeconds: Double) -> Vehicle {
        Vehicle(doorNo: door, lat: lat, lon: lon, lineCode: "146", patternId: "146_G_D6038",
                lineName: "TEST", direction: "D",
                lastFix: Date().addingTimeInterval(-ageSeconds), nearStopCode: nil)
    }

    /// A vehicle dropped from a single response must not vanish from the map.
    func testMergeKeepsRecentlySeenVehicle() {
        let a = veh("A-1", 41.05, 28.70, ageSeconds: 30)
        let b = veh("B-2", 41.06, 28.71, ageSeconds: 30)
        let merged = JourneyEngine.merge(existing: [a, b], fresh: [a])
        XCTAssertEqual(Set(merged.map(\.doorNo)), ["A-1", "B-2"])
    }

    /// But it must not be kept forever: an old fix is dropped, not shown stale.
    func testMergeDropsStaleVehicle() {
        let fresh = veh("A-1", 41.05, 28.70, ageSeconds: 20)
        let old = veh("B-2", 41.06, 28.71, ageSeconds: 600)
        let merged = JourneyEngine.merge(existing: [fresh, old], fresh: [fresh])
        XCTAssertEqual(merged.map(\.doorNo), ["A-1"])
    }

    /// A fresh report always wins over the retained copy.
    func testMergePrefersFreshFix() {
        let old = veh("A-1", 41.05, 28.70, ageSeconds: 120)
        let new = veh("A-1", 41.06, 28.71, ageSeconds: 5)
        let merged = JourneyEngine.merge(existing: [old], fresh: [new])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].lat, 41.06, accuracy: 1e-9)
    }

    func testPointAlongPolylineIsMonotonicAndBearsNorth() {
        let line = [CLLocationCoordinate2D(latitude: 41.00, longitude: 28.70),
                    CLLocationCoordinate2D(latitude: 41.01, longitude: 28.70),
                    CLLocationCoordinate2D(latitude: 41.02, longitude: 28.70)]
        let cum = Geo.cumulative(line)
        let a = Geo.point(along: 0, on: line, cumulative: cum)
        let b = Geo.point(along: cum.last! / 2, on: line, cumulative: cum)
        let c = Geo.point(along: cum.last! * 5, on: line, cumulative: cum)   // clamped
        XCTAssertNotNil(a); XCTAssertNotNil(b); XCTAssertNotNil(c)
        XCTAssertLessThan(a!.coordinate.latitude, b!.coordinate.latitude)
        XCTAssertLessThan(b!.coordinate.latitude, c!.coordinate.latitude)
        XCTAssertEqual(c!.coordinate.latitude, 41.02, accuracy: 1e-6)
        XCTAssertEqual(b!.bearing, 0, accuracy: 1.0)                          // due north
    }

    func testMeasuredSpeedUsesRealFixSpacing() {
        var h = VehicleHistory()
        let t0 = Date().addingTimeInterval(-120)
        h.record(Vehicle(doorNo: "A-1", lat: 41.000, lon: 28.700, lineCode: "146",
                         patternId: "p", lineName: "", direction: "D",
                         lastFix: t0, nearStopCode: nil))
        // 0.009° of latitude ≈ 1001 m, covered in 60 s ≈ 60 km/h.
        h.record(Vehicle(doorNo: "A-1", lat: 41.009, lon: 28.700, lineCode: "146",
                         patternId: "p", lineName: "", direction: "D",
                         lastFix: t0.addingTimeInterval(60), nearStopCode: nil))
        let v = h.speedMetresPerSecond
        XCTAssertNotNil(v)
        XCTAssertEqual(v! * 3.6, 60, accuracy: 4)
        XCTAssertEqual(h.courseDegrees ?? -1, 0, accuracy: 1.0)
    }

    /// One fix measures nothing, and ROVA says so instead of printing a zero.
    func testSpeedUnknownFromASingleFix() {
        var h = VehicleHistory()
        h.record(veh("A-1", 41.0, 28.7, ageSeconds: 10))
        XCTAssertNil(h.speedMetresPerSecond)
    }

    /// The "2 minutes for an hour" regression.
    ///
    /// A bus that keeps reporting from the same spot used to be invisible to
    /// every check in the engine, so it was described at its scheduled time
    /// forever. It must now be recognised as standing still.
    func testStationaryBusIsDetectedAsStalled() {
        var h = VehicleHistory()
        let t0 = Date().addingTimeInterval(-600)
        for i in 0..<10 {
            h.record(Vehicle(doorNo: "A-1", lat: 41.0000, lon: 28.7000, lineCode: "146",
                             patternId: "p", lineName: "", direction: "D",
                             lastFix: t0.addingTimeInterval(Double(i) * 60),
                             nearStopCode: nil))
        }
        let stalled = h.stalledSeconds
        XCTAssertNotNil(stalled, "a bus parked for ten minutes must read as stalled")
        XCTAssertGreaterThanOrEqual(stalled!, 500)
    }

    /// A moving bus must never be accused of standing still.
    func testMovingBusIsNotStalled() {
        var h = VehicleHistory()
        let t0 = Date().addingTimeInterval(-600)
        for i in 0..<10 {
            h.record(Vehicle(doorNo: "A-1", lat: 41.0 + Double(i) * 0.004, lon: 28.7,
                             lineCode: "146", patternId: "p", lineName: "", direction: "D",
                             lastFix: t0.addingTimeInterval(Double(i) * 60),
                             nearStopCode: nil))
        }
        XCTAssertNil(h.stalledSeconds)
    }

    /// A bus that went silent is stale, which is a different fault with a
    /// different message — it must not be reported as "not moving".
    func testSilentBusIsNotCalledStalled() {
        var h = VehicleHistory()
        let t0 = Date().addingTimeInterval(-3600)
        for i in 0..<6 {
            h.record(Vehicle(doorNo: "A-1", lat: 41.0, lon: 28.7, lineCode: "146",
                             patternId: "p", lineName: "", direction: "D",
                             lastFix: t0.addingTimeInterval(Double(i) * 60),
                             nearStopCode: nil))
        }
        XCTAssertNil(h.stalledSeconds)
    }

    /// A pushed update is re-validated exactly like a polled one.
    func testSocketPushDecodesRealPayload() {
        let json = """
        {"type":"vehicles","lineCode":"146","vehicles":[
          {"vehicleId":"K1617","patternId":"146_D_D0",
           "position":{"lat":41.07938,"lon":28.6704635},
           "sourceTime":"2026-11-12T20:40:58.000Z"}]}
        """
        let v = LiveSocket.decodeForTesting(json)
        XCTAssertEqual(v?.count, 1)
        XCTAssertEqual(v?.first?.doorNo, "K1617")
        XCTAssertEqual(v?.first?.lineCode, "146")
        XCTAssertEqual(v?.first?.patternId, "146_D_D0")
    }

    /// The socket must not become a hole in the validation. A server that
    /// starts sending rubbish is not to be trusted just because it is ours.
    func testSocketPushRejectsImpossiblePositionsAndFutureFixes() {
        let outsideIstanbul = """
        {"type":"vehicles","lineCode":"146","vehicles":[
          {"vehicleId":"BAD","patternId":"p","position":{"lat":0,"lon":0},
           "sourceTime":"2026-11-12T20:40:58.000Z"}]}
        """
        XCTAssertEqual(LiveSocket.decodeForTesting(outsideIstanbul)?.count, 0)

        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let fromTheFuture = """
        {"type":"vehicles","lineCode":"146","vehicles":[
          {"vehicleId":"BAD","patternId":"p",
           "position":{"lat":41.0,"lon":28.7},"sourceTime":"\(future)"}]}
        """
        XCTAssertEqual(LiveSocket.decodeForTesting(fromTheFuture)?.count, 0)
    }

    /// Implausible speeds are data errors, not 300 km/h buses.
    func testImplausibleSpeedRejected() {
        var h = VehicleHistory()
        let t0 = Date().addingTimeInterval(-200)
        h.record(Vehicle(doorNo: "A-1", lat: 41.00, lon: 28.70, lineCode: "146", patternId: "p",
                         lineName: "", direction: "D", lastFix: t0, nearStopCode: nil))
        h.record(Vehicle(doorNo: "A-1", lat: 41.20, lon: 28.70, lineCode: "146", patternId: "p",
                         lineName: "", direction: "D",
                         lastFix: t0.addingTimeInterval(30), nearStopCode: nil))
        XCTAssertNil(h.speedMetresPerSecond)
    }

    /// The animator must place a new vehicle at once, never at 0,0 first.
    @MainActor
    func testAnimatorPlacesVehicleImmediately() {
        let line = (0...20).map {
            CLLocationCoordinate2D(latitude: 41.00 + Double($0) * 0.002, longitude: 28.70)
        }
        let a = VehicleAnimator()
        a.setRoute(line, boardAlong: Geo.cumulative(line).last)
        a.update(vehicles: [veh("A-1", 41.010, 28.7001, ageSeconds: 10)],
                 speeds: ["A-1": 8.0])
        guard let d = a.display(doorNo: "A-1") else { return XCTFail("no display") }
        XCTAssertEqual(d.coordinate.latitude, 41.010, accuracy: 0.002)
        XCTAssertGreaterThan(d.metresToBoard ?? 0, 0)
        XCTAssertEqual(d.speedKmh ?? 0, 28.8, accuracy: 0.5)
    }

    /// Extrapolation is capped, so a vehicle whose feed died stops creeping.
    @MainActor
    func testStaleVehicleIsNotGlidedForever() {
        let line = (0...200).map {
            CLLocationCoordinate2D(latitude: 41.00 + Double($0) * 0.002, longitude: 28.70)
        }
        let a = VehicleAnimator()
        a.setRoute(line, boardAlong: Geo.cumulative(line).last)
        a.update(vehicles: [veh("A-1", 41.010, 28.7, ageSeconds: 3600)], speeds: ["A-1": 10.0])
        guard let d = a.display(doorNo: "A-1") else { return XCTFail("no display") }
        XCTAssertLessThanOrEqual(d.leadMetres, 701)
        XCTAssertGreaterThan(d.fixAge, 3000)                 // the age stays honest
        XCTAssertFalse(DataState.forFix(age: d.fixAge).isLive)
    }

    /// The marker must never be drawn past the last position İETT published.
    ///
    /// It used to be pushed ahead at the vehicle's measured speed, which looked
    /// smooth until the next fix revealed the bus had been sitting in traffic —
    /// and the marker jumped backwards. From the pavement that reads as the app
    /// lying, so the prediction was removed. Smoothing real data is honest;
    /// running ahead of it is not.
    @MainActor
    func testMarkerNeverRunsAheadOfTheLastFix() async throws {
        let line = (0...200).map {
            CLLocationCoordinate2D(latitude: 41.00 + Double($0) * 0.001, longitude: 28.70)
        }
        let a = VehicleAnimator()
        a.setRoute(line, boardAlong: Geo.cumulative(line).last)
        let fix = veh("A-1", 41.050, 28.70, ageSeconds: 5)
        a.update(vehicles: [fix], speeds: ["A-1": 12.0])
        let placed = try XCTUnwrap(a.display(doorNo: "A-1"))
        XCTAssertEqual(Geo.metres(placed.coordinate, fix.coordinate), 0, accuracy: 30)

        // Let real time pass with no new fix: it must stay put, not creep.
        try await Task.sleep(nanoseconds: 1_600_000_000)
        let later = try XCTUnwrap(a.display(doorNo: "A-1"))
        XCTAssertEqual(Geo.metres(later.coordinate, fix.coordinate), 0, accuracy: 30)
        XCTAssertFalse(later.isEstimatedBetweenFixes)
    }

    /// Age alone must not move the marker one metre.
    @MainActor
    func testStaleFixIsDrawnWhereItWasReported() throws {
        let line = (0...300).map {
            CLLocationCoordinate2D(latitude: 41.00 + Double($0) * 0.001, longitude: 28.70)
        }
        func placed(age: Double) throws -> CLLocationCoordinate2D {
            let a = VehicleAnimator()
            a.setRoute(line, boardAlong: nil)
            a.update(vehicles: [veh("A-1", 41.050, 28.70, ageSeconds: age)], speeds: ["A-1": 10.0])
            return try XCTUnwrap(a.display(doorNo: "A-1")).coordinate
        }
        let fresh = try placed(age: 5)
        let old = try placed(age: 600)
        XCTAssertEqual(Geo.metres(fresh, old), 0, accuracy: 1,
                       "a stale bus is drawn where it was last seen, not where it might be")
    }

    /// The backend's wire format decodes to the same honest Vehicle, keeping
    /// the source's own GPS timestamp rather than the time it was received.
    func testBackendPayloadKeepsSourceTime() throws {
        let fix = Date().addingTimeInterval(-77)
        let iso = ISO8601DateFormatter()
        let json = """
        {"lineCode":"146","count":1,"vehicles":[
          {"vehicleId":"M2533","patternId":"146_G_D6038",
           "position":{"lat":41.0593,"lon":28.6703},
           "sourceTime":"\(iso.string(from: fix))","nearStopCode":"177182"}]}
        """
        let v = try XCTUnwrap(BackendClient.decodeForTesting(json))
        XCTAssertEqual(v.count, 1)
        XCTAssertEqual(v[0].doorNo, "M2533")
        XCTAssertEqual(v[0].lastFix.timeIntervalSince1970, fix.timeIntervalSince1970, accuracy: 1.5)
        XCTAssertEqual(v[0].fixAge, 77, accuracy: 3)
    }

    /// A backend that sends nonsense is not trusted just because it is ours.
    func testBackendRejectsImpossiblePositionsAndFutureFixes() throws {
        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(600))
        let json = """
        {"lineCode":"146","count":3,"vehicles":[
          {"vehicleId":"BAD1","patternId":"p","position":{"lat":0,"lon":0},
           "sourceTime":"2026-11-12T08:00:00Z","nearStopCode":null},
          {"vehicleId":"BAD2","patternId":"p","position":{"lat":41.05,"lon":28.67},
           "sourceTime":"\(future)","nearStopCode":null},
          {"vehicleId":"GOOD","patternId":"p","position":{"lat":41.05,"lon":28.67},
           "sourceTime":"2026-11-12T08:00:00Z","nearStopCode":null}]}
        """
        let v = try XCTUnwrap(BackendClient.decodeForTesting(json))
        XCTAssertEqual(v.map(\.doorNo), ["GOOD"])
    }

    /// The highlighted stretch starts at the bus and ends at your stop.
    func testApproachSliceSpansBusToBoardingStop() {
        let line = (0...100).map {
            CLLocationCoordinate2D(latitude: 41.00 + Double($0) * 0.001, longitude: 28.70)
        }
        let cum = Geo.cumulative(line)
        let from = cum[20], to = cum[60]
        let slice = Geo.slice(line, cumulative: cum, from: from, to: to)
        XCTAssertGreaterThan(slice.count, 2)
        XCTAssertEqual(slice.first!.latitude, line[20].latitude, accuracy: 1e-5)
        XCTAssertEqual(slice.last!.latitude, line[60].latitude, accuracy: 1e-5)
        let length = Geo.cumulative(slice).last ?? 0
        XCTAssertEqual(length, to - from, accuracy: 5)
    }

    /// A bus already past your stop has nothing to highlight.
    func testApproachSliceEmptyWhenBusIsPastTheStop() {
        let line = (0...20).map {
            CLLocationCoordinate2D(latitude: 41.00 + Double($0) * 0.001, longitude: 28.70)
        }
        let cum = Geo.cumulative(line)
        XCTAssertTrue(Geo.slice(line, cumulative: cum, from: cum[15], to: cum[5]).isEmpty)
    }

    /// A fix is live for two publish cycles, not one: the old 75 s cut-off made
    /// a healthy bus flicker green/amber once a minute.
    func testDataStateFollowsTheSourceCadence() {
        XCTAssertTrue(DataState.forFix(age: 10).isLive)
        XCTAssertTrue(DataState.forFix(age: 120).isLive, "a 2-minute-old fix is normal for a 60 s feed")
        XCTAssertFalse(DataState.forFix(age: 200).isLive)
        if case .recentlyUpdated = DataState.forFix(age: 200) {} else {
            XCTFail("200 s should be recently updated")
        }
        if case .delayedData = DataState.forFix(age: 400) {} else {
            XCTFail("400 s should be delayed")
        }
    }

    /// A bus whose own güzergah does not call at the stop is not approaching
    /// it — most often it is the same line running the other way.
    func testVehicleOnAnotherPatternIsNotOfferedAsArriving() throws {
        let store = TransitStore.shared
        XCTAssertFalse(store.patterns.isEmpty)
        let planner = JourneyPlanner(store: store)
        let plan = planner.plan(from: DefaultJourney.origin.coordinate,
                                to: DefaultJourney.destination.coordinate, limit: 4)
        let leg = try XCTUnwrap(plan.first?.busLegs.first)
        let board = try XCTUnwrap(leg.boardStop)
        let line = try XCTUnwrap(leg.lineCode)

        let ghost = Vehicle(doorNo: "GHOST", lat: board.lat + 0.004, lon: board.lon,
                            lineCode: line, patternId: "\(line)_NOT_A_REAL_PATTERN",
                            lineName: "", direction: "D",
                            lastFix: Date(), nearStopCode: nil)
        let engine = ETAEngine(store: store)
        let out = engine.candidates(vehicles: [ghost], lineCode: line, boardStop: board,
                                    preferredPattern: leg.patternId, histories: [:])
        XCTAssertTrue(out.isEmpty, "a vehicle on an unrelated pattern must not be shown as arriving")
    }

    func testSliceBetweenCoordinatesCutsTheDrawnLine() {
        let line = (0...100).map {
            CLLocationCoordinate2D(latitude: 41.00 + Double($0) * 0.001, longitude: 28.70)
        }
        let cut = Geo.sliceBetween(line, from: line[30], to: line[70])
        XCTAssertGreaterThan(cut.count, 2)
        XCTAssertEqual(cut.first!.latitude, line[30].latitude, accuracy: 1e-4)
        XCTAssertEqual(cut.last!.latitude, line[70].latitude, accuracy: 1e-4)
    }

    /// Pressing Start on a real vehicle produces an ordered stop list that
    /// ends where you get off and marks where you get on.
    @MainActor
    func testTripStopsRunFromTheBusToYourAlightingStop() async {
        let engine = JourneyEngine()
        await engine.plan(from: DefaultJourney.origin.coordinate,
                          to: DefaultJourney.destination.coordinate)
        guard let j = engine.journeys.first,
              let leg = j.option.busLegs.first,
              let line = leg.lineCode, let pid = leg.patternId,
              let board = leg.boardStop, let alight = leg.alightStop else {
            return XCTFail("no journey to follow")
        }
        let store = TransitStore.shared
        let ps = store.patternStops(pid)
        guard let bi = ps.firstIndex(where: { $0.stopCode == board.code }), bi >= 3,
              let startStop = store.stop(ps[bi - 3].stopCode) else {
            return XCTFail("boarding stop too close to the start of the pattern")
        }

        // A vehicle three stops before the boarding stop, reporting this very
        // pattern — exactly what the feed gives us.
        let v = Vehicle(doorNo: "TRIP-1", lat: startStop.lat, lon: startStop.lon,
                        lineCode: line, patternId: pid, lineName: "", direction: "D",
                        lastFix: Date(), nearStopCode: startStop.code)
        // Pin the journey before injecting. Without this the engine is free to
        // re-rank and focus a different pattern — which it does once the shared
        // İETT hourly budget is spent and planning falls back to the timetable
        // — and the assertions below would then be measuring one pattern's bus
        // against another pattern's boarding point.
        engine.select(j.option)
        engine.injectForTesting(vehicles: [v], line: line)
        engine.startTrip("TRIP-1")
        guard engine.routeContext?.patternId == pid else {
            return XCTFail("engine focused \(engine.routeContext?.patternId ?? "nothing") "
                           + "instead of the planned pattern \(pid)")
        }

        let stops = engine.tripStops()
        XCTAssertGreaterThan(stops.count, 3)
        XCTAssertEqual(stops.last?.code, alight.code, "the list must end where you get off")
        XCTAssertTrue(stops.last?.isAlight == true)
        XCTAssertEqual(stops.filter(\.isBoard).count, 1, "exactly one boarding stop")
        XCTAssertEqual(stops.map(\.index), stops.map(\.index).sorted(), "stops must be in order")

        // Predicted times must increase along the route, never go backwards.
        let times = stops.compactMap(\.eta)
        XCTAssertEqual(times, times.sorted(), "arrival times must not go backwards")

        // The bus is before the boarding stop, so the trip is still waiting.
        XCTAssertEqual(engine.tripPhase, .waiting)
        engine.endTrip()
        XCTAssertNil(engine.tripDoorNo)
        XCTAssertTrue(engine.tripStops().isEmpty)
    }

    // Local helpers: these tests live outside ETATests.
    private func busCorridor() -> (Pattern, [CLLocationCoordinate2D])? {
        let st = TransitStore.shared
        guard let p = st.patterns.values
            .filter({ $0.line == "146" && $0.stopCount > 15 })
            .sorted(by: { $0.id < $1.id }).first else { return nil }
        let shape = st.patternShape(p.id)
        return shape.count > 15 ? (p, shape) : nil
    }

    private func busAt(_ i: Int, _ shape: [CLLocationCoordinate2D], _ pid: String) -> Vehicle {
        Vehicle(doorNo: "B-TEST", lat: shape[i].latitude, lon: shape[i].longitude,
                lineCode: "146", patternId: pid, lineName: "", direction: "G",
                lastFix: Date(), nearStopCode: nil)
    }

    /// Some İETT patterns carry so few timepoints that the interpolated
    /// offsets collapse and the timetable implies a bus doing 200 km/h. The
    /// sanity rule must take over and say why.
    func testCollapsedScheduleFallsBackToDistance() throws {
        let (p, shape) = try XCTUnwrap(busCorridor())
        var e = ETAEngine(store: TransitStore.shared)
        // Forcing the threshold down makes the real corridor look "too fast",
        // which is exactly the condition a collapsed timetable produces.
        e.implausibleSpeed = 0.5
        e.typicalBusSpeed = 7.0
        let eta = try XCTUnwrap(e.estimate(vehicle: busAt(2, shape, p.id),
                                           pattern: p, stopIndex: 14, history: nil))
        let remaining = try XCTUnwrap(eta.remainingMetres)
        XCTAssertEqual(eta.predictedMinutes, remaining / 7.0 / 60, accuracy: 0.1)
        XCTAssertLessThanOrEqual(eta.confidence, .low)
        XCTAssertTrue(eta.lowConfidenceReason?.contains("almost no timing") == true,
                      "got: \(eta.lowConfidenceReason ?? "nil")")
    }

    /// And with the real thresholds, no pattern of this line may produce an
    /// arrival time that implies a speed no bus reaches.
    func testNoRealPatternImpliesAnImpossibleSpeed() {
        let st = TransitStore.shared
        let e = ETAEngine(store: st)
        var checked = 0
        for p in st.patterns.values.filter({ $0.line == "146" && $0.stopCount > 15 }) {
            let shape = st.patternShape(p.id)
            guard shape.count > 15 else { continue }
            guard let eta = e.estimate(vehicle: busAt(1, shape, p.id),
                                       pattern: p, stopIndex: 14, history: nil),
                  let m = eta.remainingMetres, m > 400 else { continue }
            checked += 1
            let kmh = (m / 1000) / (eta.predictedMinutes / 60)
            XCTAssertLessThan(kmh, 61, "pattern \(p.id) implies \(Int(kmh)) km/h")
        }
        XCTAssertGreaterThan(checked, 0, "nothing was actually checked")
    }

    /// The store is read from the main actor and from the detached planner at
    /// the same time. One SQLite connection stepped from two threads, plus a
    /// cache mutated from both, crashed the app while typing a destination.
    /// This hammers it from every direction at once.
    func testStoreSurvivesConcurrentReaders() async {
        let store = TransitStore.shared
        let patterns = Array(store.patterns.keys.prefix(40))
        XCTAssertFalse(patterns.isEmpty)
        let stopCodes = Array(store.stops.keys.prefix(40))

        await withTaskGroup(of: Int.self) { group in
            for i in 0..<16 {
                group.addTask {
                    var touched = 0
                    for n in 0..<25 {
                        let pid = patterns[(i + n) % patterns.count]
                        touched += store.patternStops(pid).count
                        touched += store.patternShape(pid).count
                        touched += store.patternsCalling(at: stopCodes[(i * n) % stopCodes.count]).count
                        touched += store.activeServices(on: Date()).count
                        touched += store.stopsNear(DefaultJourney.origin.coordinate,
                                                   radius: 800, limit: 20).count
                    }
                    return touched
                }
            }
            var total = 0
            for await t in group { total += t }
            XCTAssertGreaterThan(total, 0)
        }
    }

    /// And the planner itself, run concurrently, must not trip over the store.
    func testConcurrentPlansDoNotCrash() async {
        let store = TransitStore.shared
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    JourneyPlanner(store: store)
                        .plan(from: DefaultJourney.origin.coordinate,
                              to: DefaultJourney.destination.coordinate, limit: 4).count
                }
            }
            var n = 0
            for await c in group { n += c }
            XCTAssertGreaterThan(n, 0)
        }
    }

    /// The bus you are following is never dropped, however quiet the feed
    /// goes. Losing it mid-ride and making the user re-pick their location is
    /// the failure this guards.
    func testFollowedVehicleIsNeverDropped() {
        let riding = Vehicle(doorNo: "MINE", lat: 41.02, lon: 28.72, lineCode: "34",
                             patternId: "p", lineName: "", direction: "D",
                             lastFix: Date().addingTimeInterval(-3600), nearStopCode: nil)
        let other = Vehicle(doorNo: "OTHER", lat: 41.03, lon: 28.73, lineCode: "34",
                            patternId: "p", lineName: "", direction: "D",
                            lastFix: Date().addingTimeInterval(-3600), nearStopCode: nil)
        // An hour-old fix, and the feed no longer mentions either of them.
        let merged = JourneyEngine.merge(existing: [riding, other], fresh: [], pinned: "MINE")
        XCTAssertEqual(merged.map(\.doorNo), ["MINE"])
        // Its age is still reported truthfully — kept, not refreshed.
        XCTAssertGreaterThan(merged[0].fixAge, 3000)
        XCTAssertFalse(DataState.forFix(age: merged[0].fixAge).isLive)
    }
}
