import XCTest
import CoreLocation
@testable import ROVA

/// Integration tests that call the real İETT service from the app's own client.
///
/// They are skipped unless `ROVA_LIVE_TESTS=1` is in the environment, so a run
/// without network never reports a false pass — and they never assert on mock
/// data.
final class LiveIntegrationTests: XCTestCase {

    private var enabled: Bool { ProcessInfo.processInfo.environment["ROVA_LIVE_TESTS"] == "1" }

    /// Run a live call, skipping only when İETT is rate limiting this device.
    ///
    /// A rate limit means the test could not be *performed*, which is what
    /// XCTSkip is for. It is deliberately narrow: every other error still
    /// fails, because a test that swallows failures is worse than no test.
    private func live<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let e as LiveError {
            if case .rateLimited(let after) = e {
                throw XCTSkip("İETT is rate limiting this device — "
                              + "retry in \(Int(after)) s. Not a product failure.")
            }
            throw e
        }
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(enabled, "set ROVA_LIVE_TESTS=1 to run live İETT tests")
    }

    /// The whole path for a journey that is nowhere near the user: plan from
    /// İstanbul Aydın Üniversitesi (Beşyol) to Avcılar, then check that live
    /// Metrobüs vehicles actually reach the map.
    ///
    /// This is the case of looking up a friend's bus from home. It exercises
    /// planning, line selection, the live fetch and the map filter together,
    /// because each of those was individually correct while the Metrobüs
    /// still failed to appear — and only the whole chain proves it works.
    @MainActor
    func testRemoteJourneyShowsLiveMetrobusOnTheMap() async throws {
        let engine = JourneyEngine()
        // Take the same path the phone takes. The backend exists to absorb
        // İETT's hourly quota; without it this test burns the device's own
        // allowance and then reports a rate limit rather than the truth.
        if let cfg = BackendClient.bundledConfig() {
            await engine.applyBackend(cfg)
        }
        let origin = CLLocationCoordinate2D(latitude: 40.99460, longitude: 28.79498)
        let dest   = CLLocationCoordinate2D(latitude: 40.983944, longitude: 28.725631)

        await engine.plan(from: origin, to: dest)

        let metrobusOptions = engine.options.filter { o in
            o.lineCodes.contains { TransitMode.of(line: $0) == .metrobus }
        }
        XCTAssertFalse(metrobusOptions.isEmpty,
                       "Beşyol to Avcılar is a Metrobüs journey; got "
                       + "\(engine.options.map(\.lineCodes))")

        // The best option must be one of them — the Metrobüs is faster here.
        let best = try XCTUnwrap(engine.journeys.first)
        XCTAssertTrue(best.option.lineCodes.contains {
            TransitMode.of(line: $0) == .metrobus
        }, "expected a Metrobüs first, got \(best.option.lineCodes)")

        // And live vehicles for it must reach the map. Outside service hours
        // this is legitimately empty, so the assertion is conditional — but
        // whatever arrives must be real.
        // Distinguish "nothing is running" from "vehicles exist but never
        // reach the map". Skipping on both hides the second, which is the
        // actual failure mode: the engine held vehicles and drew none.
        let fetched = engine.vehicles
        let fetchedCount = fetched.values.reduce(0) { $0 + $1.count }
        let onMap = engine.mapVehicles

        if fetchedCount == 0 {
            throw XCTSkip("no vehicles fetched at all — "
                          + "line(s) \(engine.options.first?.lineCodes ?? []), "
                          + "live problem: \(engine.liveProblem ?? "none")")
        }

        XCTAssertFalse(onMap.isEmpty,
            "the engine holds \(fetchedCount) live vehicles "
            + "(\(fetched.map { "\($0.key):\($0.value.count)" }.joined(separator: ", "))) "
            + "but none reached the map. Focused line: "
            + "\(engine.focusedJourney?.option.busLegs.first?.lineCode ?? "nil"), "
            + "pattern: \(engine.focusedJourney?.option.busLegs.first?.patternId ?? "nil")")
        for v in onMap {
            XCTAssertTrue((40.5...41.9).contains(v.coordinate.latitude))
            XCTAssertTrue((27.0...30.5).contains(v.coordinate.longitude))
            XCTAssertLessThan(v.lastFix.timeIntervalSinceNow, 120,
                              "no fix may come from the future")
            XCTAssertFalse(v.doorNo.isEmpty, "every vehicle must carry its real door number")
        }
    }

    func testFetchesRealVehiclesFromIETT() async throws {
        let client = IETTLiveClient()
        let vehicles = try await live { try await client.vehicles(line: "146", force: true) }

        // An empty list is a legitimate answer outside service hours. What must
        // hold is that everything accepted is a usable, validated fix.
        for v in vehicles {
            XCTAssertFalse(v.doorNo.isEmpty)
            XCTAssertTrue((40.5...41.9).contains(v.lat), "lat out of Istanbul: \(v.lat)")
            XCTAssertTrue((27.0...30.5).contains(v.lon), "lon out of Istanbul: \(v.lon)")
            XCTAssertLessThan(v.lastFix.timeIntervalSinceNow, 120)
            XCTAssertEqual(v.lineCode, "146")
        }
        print("ROVA live: 146 → \(vehicles.count) vehicles")
    }

    func testLivePatternIdsResolveAgainstTheBundle() async throws {
        let client = IETTLiveClient()
        let vehicles = try await live { try await client.vehicles(line: "146", force: true) }
        try XCTSkipIf(vehicles.isEmpty, "no vehicles running on 146 right now")

        for v in vehicles where !v.patternId.isEmpty {
            XCTAssertNotNil(TransitStore.shared.patterns[v.patternId],
                            "live güzergah \(v.patternId) is not in the bundled network")
        }
    }

    /// The full product path: plan the real journey, fetch live buses for its
    /// line, match them to the route and produce an ETA for the boarding stop.
    func testEndToEndJourneyProducesAnHonestResult() async throws {
        let store = TransitStore.shared
        let planner = JourneyPlanner(store: store)
        let options = planner.plan(from: DefaultJourney.origin.coordinate,
                                   to: DefaultJourney.destination.coordinate)
        XCTAssertFalse(options.isEmpty)

        let engine = ETAEngine(store: store)
        let client = IETTLiveClient()
        var produced = 0
        var linesWithVehicles = 0

        for option in options.prefix(4) {
            guard let leg = option.busLegs.first,
                  let line = leg.lineCode,
                  let board = leg.boardStop else { continue }

            let vehicles = try await live { try await client.vehicles(line: line, force: false) }
            if vehicles.isEmpty { continue }
            linesWithVehicles += 1

            let candidates = engine.candidates(vehicles: vehicles, lineCode: line,
                                               boardStop: board,
                                               preferredPattern: leg.patternId,
                                               histories: [:])
            for c in candidates {
                produced += 1
                let eta = c.eta
                XCTAssertGreaterThanOrEqual(eta.predictedMinutes, 0)
                XCTAssertLessThan(eta.predictedMinutes, 180, "an ETA over 3 h is not useful")
                XCTAssertLessThanOrEqual(eta.rangeMinutes.lowerBound, eta.predictedMinutes + 0.01)
                XCTAssertGreaterThanOrEqual(eta.rangeMinutes.upperBound, eta.predictedMinutes - 0.01)
                XCTAssertNotNil(eta.vehicleDoorNo)
                XCTAssertEqual(eta.lineCode, line)

                // Honesty rules.
                if let age = eta.lastFixAge, age > 180 {
                    XCTAssertFalse(eta.state.isLive, "a \(Int(age)) s old fix must not be labelled live")
                }
                if eta.confidence != .high {
                    XCTAssertNotNil(eta.lowConfidenceReason,
                                    "anything below high confidence must say why")
                }
                print("ROVA live: \(line) vehicle \(eta.vehicleDoorNo ?? "?") → "
                      + "\(String(format: "%.1f", eta.predictedMinutes)) min "
                      + "[\(eta.confidence.rawValue)] \(eta.state.label) "
                      + "\(eta.stopsAway ?? -1) stops")
            }
        }

        if linesWithVehicles == 0 {
            print("ROVA live: no İETT vehicle is reporting on any planned line right now — "
                  + "the app correctly shows the timetable instead.")
        } else {
            XCTAssertGreaterThan(produced, 0,
                "vehicles were returned but none could be matched to the route")
        }
    }

    func testBudgetIsRespectedAcrossRepeatedCalls() async throws {
        let client = IETTLiveClient()
        _ = try await live { try await client.vehicles(line: "146", force: true) }
        let before = await client.remainingRequestsThisHour
        // A cached read must not spend another slot.
        _ = try await live { try await client.vehicles(line: "146", force: false) }
        let after = await client.remainingRequestsThisHour
        XCTAssertEqual(before, after, "a cached read must not consume İETT quota")
    }
}
