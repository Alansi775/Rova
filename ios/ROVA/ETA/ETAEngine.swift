import Foundation
import CoreLocation

/// Estimates when a specific, observed vehicle will reach a specific stop.
///
/// The model is deliberately conservative:
///
/// 1. **Route matching** — the GPS fix is snapped onto the geometry of the
///    pattern the vehicle reports. A fix further than `maxSnapOffset` from that
///    geometry is rejected rather than guessed at.
/// 2. **Travel time** — the base estimate is *scheduled* time-along-route, not
///    distance ÷ speed. İETT's own timetable already encodes stop spacing,
///    dwell time and time-of-day traffic for that corridor.
/// 3. **Observed progress** — if the vehicle has been watched for a while, the
///    ratio between its real progress and its scheduled progress scales the
///    estimate.
/// 4. **Staleness** — the age of the GPS fix is subtracted (the bus kept
///    moving while we were not looking) *and* widens the range and lowers the
///    confidence.
struct ETAEngine {
    let store: TransitStore
    var maxSnapOffset: Double = 450        // metres
    var minProgressSamples = 2
    /// Above this the timetable is not describing a bus: 17 m/s is 61 km/h
    /// door to door, including stops.
    /// How old a GPS fix may be before it stops being evidence at all.
    ///
    /// Fifteen minutes: long enough to ride out a tunnel or a gap in
    /// coverage, short enough that a bus which finished its shift hours ago
    /// can never be presented as approaching.
    var maxUsableFixAge: TimeInterval = 900

    /// The same limit, for callers that need it without an engine instance.
    static let liveFixAgeLimit: TimeInterval = 900

    /// The fastest a city bus could conceivably average door to door, used
    /// only to bound how soon one could physically arrive.
    ///
    /// Separate from `implausibleSpeed` on purpose. That one is the knob for
    /// "this timetable implies a speed no bus reaches", and tests drive it to
    /// absurd values to force that branch. Sharing a constant between a ratio
    /// test and a physical floor let one of them distort the other.
    var maxConceivableSpeed: Double = 17

    var implausibleSpeed: Double = 17
    /// A realistic Istanbul city-bus average including dwell: 25 km/h.
    var typicalBusSpeed: Double = 7.0

    struct Candidate {
        let vehicle: Vehicle
        let eta: ETA
    }

    /// Compute an ETA for `vehicle` arriving at index `stopIndex` of `pattern`.
    func estimate(vehicle: Vehicle,
                  pattern: Pattern,
                  stopIndex: Int,
                  history: VehicleHistory?) -> ETA? {

        let ps = store.patternStops(pattern.id)
        guard stopIndex > 0, stopIndex < ps.count else { return nil }
        let shape = ps.compactMap { store.stop($0.stopCode)?.coordinate }
        guard shape.count == ps.count, shape.count >= 2 else { return nil }

        guard let snap = Geo.snap(vehicle.coordinate, to: shape) else { return nil }
        guard snap.offset <= maxSnapOffset else { return nil }

        // Scheduled seconds-along-route at the vehicle's projected position.
        let vIdx = snap.segment
        let fromOff = Double(ps[vIdx].offsetSec)
        let toOff = Double(ps[min(vIdx + 1, ps.count - 1)].offsetSec)
        let vehicleOffset = fromOff + (toOff - fromOff) * snap.t
        let targetOffset = Double(ps[stopIndex].offsetSec)

        // When the fix lands exactly on a vertex the projection reports the
        // previous segment with t = 1; treat that as standing at the later stop.
        let vehicleIndex = vIdx + (snap.t >= 0.999 ? 1 : 0)
        let stopsAway = stopIndex - vehicleIndex
        guard stopsAway >= 0 else { return nil }                 // already passed
        var scheduledRemaining = targetOffset - vehicleOffset
        guard scheduledRemaining > -90 else { return nil }
        scheduledRemaining = max(0, scheduledRemaining)

        // Remaining distance along the route.
        let cum = Geo.cumulative(shape)
        let remaining = max(0, cum[stopIndex] - snap.along)

        // Progress factor from observed movement.
        var factor = 1.0
        var factorConfidence = false
        if let h = history, h.samples.count >= minProgressSamples,
           let observed = h.progressRatio(shape: shape, patternStops: ps) {
            factor = min(1.9, max(0.55, observed))
            factorConfidence = true
        }

        var seconds = scheduledRemaining * factor

        // Sanity against the ground, not just against the timetable.
        //
        // A few İETT patterns carry almost no timepoints, so the interpolated
        // offsets collapse and the schedule claims the bus covers kilometres in
        // seconds — which is how "14 stops, 5 minutes" reached the screen. The
        // test is made on the schedule's own answer, before staleness is
        // subtracted, because that subtraction is a legitimate reason for a
        // short remaining time.
        var scheduleSuspect = false
        if remaining > 400, seconds > 0, remaining / seconds > implausibleSpeed {
            seconds = remaining / typicalBusSpeed
            scheduleSuspect = true
        }

        // A bus that is not moving does not get the timetable's optimism.
        //
        // Until this existed, a stationary vehicle fell through every check
        // and was reported at its scheduled time, unchanged, for as long as it
        // sat there. Now the time it has already stood still is added to the
        // estimate — it has to start moving before it can arrive — and the
        // number is marked as what it is.
        let stalled = history?.stalledSeconds
        if let stalled {
            seconds += stalled
            factorConfidence = false
        }

        // The fix is `fixAge` old; assume the bus kept moving at the same rate.
        let age = vehicle.fixAge

        // Beyond this, a position is not evidence about where a bus is now.
        //
        // İETT keeps publishing the last known position of vehicles that have
        // finished for the day: measured on line 34BZ at 02:07, 112 vehicles
        // were listed and not one had reported within three minutes — the
        // median fix was 2.5 hours old and the oldest was 11 hours. Those are
        // buses parked in a depot, and describing one as "1 stop away,
        // arriving Now" is simply false.
        guard age <= maxUsableFixAge else { return nil }

        seconds = max(0, seconds - age)

        // Very short hops still need a floor — the bus has to stop and open doors.
        if stopsAway > 0 { seconds = max(seconds, 25 * Double(stopsAway)) }

        // A bus cannot arrive sooner than the road allows, and that bounds
        // the estimate itself — not only the early end of its range.
        //
        // Applying it to the range alone produced a headline of "8 min" above
        // a range of "21–293 min": a figure outside its own interval, which
        // is worse than either number alone because it tells the reader the
        // app is not even internally consistent.
        let physicalFloor = remaining / maxConceivableSpeed
        seconds = max(seconds, physicalFloor)

        let state = DataState.forFix(age: age)

        // Uncertainty grows with horizon, staleness and lack of observed progress.
        var spread = 0.14 * seconds + 45
        if !factorConfidence { spread *= 1.25 }
        if scheduleSuspect { spread *= 1.6 }
        spread += age * 0.6
        spread += Double(max(0, stopsAway - 6)) * 12
        spread += snap.offset * 0.25

        var (confidence, reason) = classify(age: age, offset: snap.offset,
                                            stopsAway: stopsAway,
                                            hasProgress: factorConfidence,
                                            horizon: seconds)
        if scheduleSuspect {
            confidence = min(confidence, .low)
            reason = "İETT publishes almost no timing for this route — "
                   + "estimated from distance alone"
        }
        if let stalled {
            // This outranks every other reason: a number is close to useless
            // next to the fact that the bus is standing still.
            confidence = .low
            reason = "This bus has not moved for \(Int(stalled / 60)) minutes"
            spread = max(spread, stalled)
        }

        // The early end of the range is bounded by the road, not just by the
        // spread. A wide spread used to drag the lower bound to zero, giving
        // ranges like "0–47 min" — and because `leaveInSeconds` is measured
        // against that lower bound, a zero there reads as "leave now" for a
        // bus that is kilometres away. That is the false urgency that sends
        // someone down to an empty stop.
        //
        // `implausibleSpeed` is the fastest a city bus could conceivably
        // average door to door, so remaining distance divided by it is the
        // soonest this bus could physically be here.
        let minM = max(0, max(physicalFloor, seconds - spread) / 60)
        let maxM = (seconds + spread) / 60
        return ETA(vehicleDoorNo: vehicle.doorNo,
                   lineCode: pattern.line,
                   patternId: pattern.id,
                   predictedMinutes: seconds / 60,
                   rangeMinutes: minM...max(maxM, minM + 0.5),
                   lastFixAge: age,
                   confidence: confidence,
                   lowConfidenceReason: reason,
                   state: state,
                   remainingMetres: remaining,
                   stopsAway: stopsAway,
                   stalledSeconds: stalled)
    }

    private func classify(age: TimeInterval, offset: Double, stopsAway: Int,
                          hasProgress: Bool, horizon: Double) -> (Confidence, String?) {
        if age > 300 { return (.low, "Last GPS fix is \(Int(age / 60)) minutes old") }
        if offset > 250 { return (.low, "Vehicle is \(Int(offset)) m off the published route") }
        if horizon > 45 * 60 { return (.low, "The bus is still far from your stop") }
        if age > 120 { return (.medium, "GPS fix is \(Int(age)) s old") }
        if stopsAway > 12 { return (.medium, "\(stopsAway) stops away — traffic can still change this") }
        if !hasProgress { return (.medium, "Not enough movement observed yet") }
        if horizon > 20 * 60 { return (.medium, "Long horizon") }
        return (.high, nil)
    }

    /// Rank every vehicle on a line for one boarding stop.
    func candidates(vehicles: [Vehicle],
                    lineCode: String,
                    boardStop: Stop,
                    preferredPattern: String?,
                    histories: [String: VehicleHistory]) -> [Candidate] {

        // Every pattern of this line that calls at the boarding stop.
        let calling = store.patternsCalling(at: boardStop.code)
            .filter { $0.0.line == lineCode }
        guard !calling.isEmpty else { return [] }
        let indexByPattern = Dictionary(calling.map { ($0.0.id, $0.1) }, uniquingKeysWith: min)

        var out: [Candidate] = []
        for v in vehicles where v.lineCode == lineCode || v.lineCode.isEmpty {
            // Prefer the pattern the vehicle itself reports; otherwise try them all.
            // A vehicle that reports its own güzergah is taken at its word. If
            // that güzergah does not call at this stop, the bus is not coming
            // here — most often it is the same line running the other way.
            // Trying every pattern "just in case" is what used to invent a bus
            // approaching a stop it was actually driving away from.
            var tried: [String] = []
            if !v.patternId.isEmpty {
                guard indexByPattern[v.patternId] != nil else { continue }
                tried = [v.patternId]
            } else {
                tried = Array(indexByPattern.keys)
            }

            var best: ETA?
            for pid in tried {
                guard let pat = store.patterns[pid], let idx = indexByPattern[pid] else { continue }
                guard let eta = estimate(vehicle: v, pattern: pat, stopIndex: idx,
                                         history: histories[v.doorNo]) else { continue }
                if best == nil || eta.predictedMinutes < best!.predictedMinutes { best = eta }
            }
            if let b = best { out.append(Candidate(vehicle: v, eta: b)) }
        }
        out.sort {
            if $0.eta.predictedMinutes != $1.eta.predictedMinutes {
                return $0.eta.predictedMinutes < $1.eta.predictedMinutes
            }
            return $0.eta.confidence > $1.eta.confidence
        }
        if let preferredPattern {
            out.sort { a, b in
                let am = a.eta.patternId == preferredPattern ? 0 : 1
                let bm = b.eta.patternId == preferredPattern ? 0 : 1
                if am != bm { return am < bm }
                return a.eta.predictedMinutes < b.eta.predictedMinutes
            }
        }
        return out
    }
}

// MARK: - Observed movement

/// Rolling GPS history for one vehicle, used to measure real progress and to
/// animate the marker only between genuine fixes.
struct VehicleHistory {
    struct Sample { let at: Date; let fix: Date; let coord: CLLocationCoordinate2D }
    private(set) var samples: [Sample] = []

    mutating func record(_ v: Vehicle) {
        if let last = samples.last, abs(last.fix.timeIntervalSince(v.lastFix)) < 1 { return }
        samples.append(Sample(at: Date(), fix: v.lastFix, coord: v.coordinate))
        if samples.count > 40 { samples.removeFirst(samples.count - 40) }
    }

    /// Ground speed in metres per second, measured between the two most
    /// recent GPS fixes that are far enough apart in time to mean anything.
    ///
    /// The feed carries no speed field, so this is measured, never guessed —
    /// and it returns nil rather than zero when there is nothing to measure.
    var speedMetresPerSecond: Double? {
        guard samples.count >= 2 else { return nil }
        let last = samples[samples.count - 1]
        for i in stride(from: samples.count - 2, through: 0, by: -1) {
            let dt = last.fix.timeIntervalSince(samples[i].fix)
            guard dt >= 25 else { continue }
            guard dt <= 420 else { break }
            let d = Geo.metres(samples[i].coord, last.coord)
            let v = d / dt
            return v > 36 ? nil : v          // 130 km/h on a city bus is bad data
        }
        return nil
    }

    /// How long this vehicle has been reporting fresh fixes from the same spot.
    ///
    /// This exists because a stationary bus used to be the *best* case in the
    /// engine: `progressRatio` needs scheduled progress to divide by, a bus
    /// that has not moved has made none, so the ratio came back nil, the
    /// progress factor fell back to 1.0, and the estimate dropped straight
    /// onto the raw timetable — which is how "2 minutes" stayed on screen for
    /// an hour while the bus never came.
    ///
    /// Measured against the ground, not the timetable. Returns nil unless the
    /// vehicle is genuinely stuck: it must still be reporting (a vehicle that
    /// went silent is stale, which is a different thing and is already shown
    /// as such), and it must have sat still long enough that traffic lights
    /// and a stop dwell are ruled out.
    var stalledSeconds: TimeInterval? {
        guard let last = samples.last else { return nil }
        // Still reporting? A silent vehicle is handled by `fixAge`, not here.
        guard Date().timeIntervalSince(last.fix) < 240 else { return nil }
        var span: TimeInterval = 0
        for i in stride(from: samples.count - 2, through: 0, by: -1) {
            guard Geo.metres(samples[i].coord, last.coord) <= 60 else { break }
            span = last.fix.timeIntervalSince(samples[i].fix)
        }
        // Three minutes parked is a jam, a layover or a dead feed — not a
        // red light, and not something to keep quiet about.
        return span >= 180 ? span : nil
    }

    /// Where the vehicle is heading, from its own recent movement.
    var courseDegrees: Double? {
        guard samples.count >= 2 else { return nil }
        let last = samples[samples.count - 1]
        for i in stride(from: samples.count - 2, through: 0, by: -1) {
            guard Geo.metres(samples[i].coord, last.coord) > 25 else { continue }
            return Geo.bearing(samples[i].coord, last.coord)
        }
        return nil
    }

    /// Real progress ÷ scheduled progress over the observed window.
    /// Returns nil when the window is too short to be meaningful.
    func progressRatio(shape: [CLLocationCoordinate2D], patternStops: [PatternStop]) -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let dt = last.fix.timeIntervalSince(first.fix)
        guard dt >= 90 else { return nil }
        guard let a = Geo.snap(first.coord, to: shape), let b = Geo.snap(last.coord, to: shape),
              a.offset < 450, b.offset < 450 else { return nil }
        func sched(_ p: Geo.Projection) -> Double {
            let i = min(p.segment, patternStops.count - 2)
            let f = Double(patternStops[i].offsetSec)
            let t = Double(patternStops[i + 1].offsetSec)
            return f + (t - f) * p.t
        }
        let scheduledDelta = sched(b) - sched(a)
        guard scheduledDelta > 30 else { return nil }
        // > 1 means the bus is slower than the timetable.
        return dt / scheduledDelta
    }
}
