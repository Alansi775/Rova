import Foundation
import SwiftUI
import CoreLocation

/// A vehicle as it is drawn on the map right now.
///
/// `coordinate` is **not** the raw GPS fix: İETT publishes one fix per vehicle
/// about every 60 s, and a marker that teleports a kilometre once a minute is
/// unreadable. ROVA slides the marker along the published route between fixes
/// at the vehicle's own measured speed, so you can see where it is and which
/// way it is going at a glance.
///
/// That is an interpolation, so it is labelled as one: `fixAge` is always the
/// true age of the last GPS report and is shown next to the marker's detail,
/// and `isEstimatedBetweenFixes` is true whenever the drawn position is ahead
/// of the last confirmed one.
struct VehicleDisplay: Identifiable, Equatable {
    let vehicle: Vehicle
    var coordinate: CLLocationCoordinate2D
    var bearing: Double
    /// Measured ground speed between the last two usable fixes, if any.
    var speedKmh: Double?
    /// Metres between the marker and the last confirmed GPS position. It eases
    /// toward each new fix, so this is only ever a fraction of one step, and
    /// never the result of guessing where the bus went next.
    var leadMetres: Double
    /// Distance still to run along the route to the boarding stop.
    var metresToBoard: Double?

    var doorNo: String { vehicle.doorNo }
    var id: String { vehicle.doorNo }
    var fixAge: TimeInterval { vehicle.fixAge }
    /// Always false now: the marker never runs ahead of published data.
    var isEstimatedBetweenFixes: Bool { false }

    static func == (a: VehicleDisplay, b: VehicleDisplay) -> Bool {
        a.vehicle.doorNo == b.vehicle.doorNo
            && abs(a.coordinate.latitude - b.coordinate.latitude) < 1e-7
            && abs(a.coordinate.longitude - b.coordinate.longitude) < 1e-7
            && abs(a.bearing - b.bearing) < 0.5
            && a.vehicle.lastFix == b.vehicle.lastFix
    }
}

/// Keeps every watched vehicle moving on screen between GPS fixes.
@MainActor
final class VehicleAnimator: ObservableObject {

    @Published private(set) var displays: [VehicleDisplay] = []

    private struct Track {
        var vehicle: Vehicle
        var snapAlong: Double          // along-route metres of the last real fix
        var speed: Double              // m/s, measured or fallen back to
        var measuredSpeed: Double?     // nil when it could not be measured
        var displayAlong: Double       // what is currently drawn
        var offRoute: Bool
        var displayCoord: CLLocationCoordinate2D
        var bearing: Double
    }

    private var tracks: [String: Track] = [:]
    private var shape: [CLLocationCoordinate2D] = []
    private var cum: [Double] = []
    private var boardAlong: Double?
    private var timer: Timer?

    /// ROVA does not run the marker ahead of the data.
    ///
    /// It used to: the marker was pushed forward from the last fix at the
    /// vehicle's measured speed, which looked smooth right up until the next
    /// fix arrived and showed the bus had been sitting in traffic — and the
    /// marker **jumped backwards**. From the pavement that reads as the app
    /// lying: "leave now" followed by the bus retreating and five more minutes.
    ///
    /// Now the marker only ever moves toward a position İETT has actually
    /// published. Between fixes it glides to the newest one and then stops.
    /// Smoothing real data is honest; predicting past it is not.


    // MARK: input

    /// The route the watched buses are running, plus where the user boards.
    func setRoute(_ shape: [CLLocationCoordinate2D], boardAlong: Double?) {
        guard shape.count != self.shape.count || shape.first?.latitude != self.shape.first?.latitude else {
            self.boardAlong = boardAlong
            return
        }
        self.shape = shape
        self.cum = shape.count >= 2 ? Geo.cumulative(shape) : []
        self.boardAlong = boardAlong
        tracks.removeAll()
    }

    /// Fresh fixes. Keeps the drawn position and eases it onto the new one.
    func update(vehicles: [Vehicle], speeds: [String: Double?]) {
        var kept: [String: Track] = [:]
        for v in vehicles {
            let measured = speeds[v.doorNo] ?? nil
            let snap = cum.isEmpty ? nil : Geo.snap(v.coordinate, to: shape)
            let offRoute = snap == nil || (snap!.offset > 900)
            var t = tracks[v.doorNo] ?? Track(
                vehicle: v,
                snapAlong: snap?.along ?? 0,
                speed: measured ?? 6.5,
                measuredSpeed: measured,
                displayAlong: snap?.along ?? 0,
                offRoute: offRoute,
                displayCoord: snap?.point ?? v.coordinate,
                bearing: 0)
            t.vehicle = v
            t.measuredSpeed = measured
            // A measured zero is real (the bus is at a stop or in traffic); only
            // an unmeasurable speed falls back to a nominal city-bus pace.
            t.speed = measured ?? min(t.speed, 6.5)
            t.offRoute = offRoute
            if let s = snap, !offRoute {
                // A new fix behind the drawn position means the extrapolation
                // ran ahead; snap back rather than wait it out.
                if s.along + 40 < t.displayAlong { t.displayAlong = s.along }
                t.snapAlong = s.along
            } else {
                t.displayCoord = v.coordinate
            }
            kept[v.doorNo] = t
        }
        tracks = kept
        step(easing: 1.0)        // place new arrivals immediately
        start()
    }

    func clear() {
        tracks.removeAll()
        displays = []
        stop()
    }

    // MARK: ticking

    private func start() {
        guard timer == nil, !tracks.isEmpty else { return }
        let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step(easing: 0.16) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() { timer?.invalidate(); timer = nil }

    private func step(easing: Double) {
        guard !tracks.isEmpty else { stop(); displays = []; return }
        var out: [VehicleDisplay] = []
        out.reserveCapacity(tracks.count)

        for (door, var t) in tracks {
            if t.offRoute || cum.isEmpty {
                let prev = t.displayCoord
                t.displayCoord = t.vehicle.coordinate
                if Geo.metres(prev, t.displayCoord) > 20 {
                    t.bearing = Geo.bearing(prev, t.displayCoord)
                }
                tracks[door] = t
                out.append(VehicleDisplay(vehicle: t.vehicle, coordinate: t.displayCoord,
                                          bearing: t.bearing, speedKmh: t.measuredSpeed.map { $0 * 3.6 },
                                          leadMetres: 0, metresToBoard: nil))
                continue
            }

            // The target is the last published position. Nothing beyond it.
            let target = t.snapAlong

            t.displayAlong += (target - t.displayAlong) * easing
            if abs(target - t.displayAlong) < 0.5 { t.displayAlong = target }

            if let p = Geo.point(along: t.displayAlong, on: shape, cumulative: cum) {
                t.displayCoord = p.coordinate
                // Hold the last bearing while stationary so the marker does not spin.
                if t.speed > 0.8 || t.bearing == 0 { t.bearing = p.bearing }
            }
            tracks[door] = t

            out.append(VehicleDisplay(
                vehicle: t.vehicle,
                coordinate: t.displayCoord,
                bearing: t.bearing,
                speedKmh: t.measuredSpeed.map { $0 * 3.6 },
                leadMetres: abs(t.displayAlong - t.snapAlong),
                metresToBoard: boardAlong.map { max(0, $0 - t.displayAlong) }))
        }

        out.sort { ($0.metresToBoard ?? .infinity) < ($1.metresToBoard ?? .infinity) }
        if out != displays { displays = out }
    }

    func display(doorNo: String) -> VehicleDisplay? { displays.first { $0.doorNo == doorNo } }
}
