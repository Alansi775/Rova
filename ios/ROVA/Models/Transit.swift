import Foundation
import CoreLocation

// MARK: - Static network

struct Stop: Identifiable, Hashable, Sendable {
    let code: String
    let name: String
    let lat: Double
    let lon: Double
    let district: String
    let direction: String
    let smart: Bool
    var id: String { code }
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

struct BusLine: Identifiable, Hashable, Sendable {
    let code: String
    let name: String
    let lengthKm: Double
    let tripMinutes: Double
    var id: String { code }
}

/// One directional variant of a line (IETT "güzergah"), e.g. `142_G_D0`.
struct Pattern: Identifiable, Hashable, Sendable {
    let id: String
    let line: String
    let direction: String      // "D" (gidiş) or "G" (dönüş)
    let headsign: String
    let note: String
    let stopCount: Int
}

struct PatternStop: Hashable, Sendable {
    let seq: Int
    let stopCode: String
    /// Scheduled seconds from the start of the trip.
    let offsetSec: Int
}

// MARK: - Live vehicles

struct Vehicle: Identifiable, Hashable, Sendable {
    let doorNo: String             // kapino — IETT vehicle identifier
    let lat: Double
    let lon: Double
    let lineCode: String           // hatkodu
    let patternId: String          // guzergahkodu
    let lineName: String           // hatad
    let direction: String          // yon
    let lastFix: Date              // son_konum_zamani
    let nearStopCode: String?      // yakinDurakKodu
    var id: String { doorNo }
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }

    var fixAge: TimeInterval { max(0, Date().timeIntervalSince(lastFix)) }
}

/// Honest description of how much the app knows right now.
enum DataState: Sendable, Equatable {
    case liveGPS(age: TimeInterval)
    case recentlyUpdated(age: TimeInterval)
    case delayedData(age: TimeInterval)
    case scheduledOnly
    case liveUnavailable(reason: String)

    /// Thresholds follow the source's real cadence, not wishful thinking.
    ///
    /// İETT publishes a new fix roughly every 60 s, and ROVA polls on its own
    /// clock, so a perfectly healthy vehicle's fix is routinely 0–130 s old.
    /// The old 75 s cut-off made every bus flicker green → amber → green once a
    /// minute, which read as a broken app rather than a normal feed. A fix is
    /// live while it is within two publish cycles, degraded within five, and
    /// only then called delayed.
    static func forFix(age: TimeInterval) -> DataState {
        switch age {
        case ..<150: return .liveGPS(age: age)
        case ..<330: return .recentlyUpdated(age: age)
        default:     return .delayedData(age: age)
        }
    }

    var label: String {
        switch self {
        case .liveGPS:          return "Live GPS"
        case .recentlyUpdated:  return "Recently updated"
        case .delayedData:      return "Delayed data"
        case .scheduledOnly:    return "Scheduled only"
        case .liveUnavailable:  return "Live location unavailable"
        }
    }

    var isLive: Bool { if case .liveGPS = self { return true }; return false }

    var age: TimeInterval? {
        switch self {
        case .liveGPS(let a), .recentlyUpdated(let a), .delayedData(let a): return a
        default: return nil
        }
    }
}

enum Confidence: String, Sendable, Comparable {
    case high, medium, low, none
    private var rank: Int { ["high": 3, "medium": 2, "low": 1, "none": 0][rawValue]! }
    static func < (a: Confidence, b: Confidence) -> Bool { a.rank < b.rank }
}

// MARK: - ETA

struct ETA: Sendable, Equatable {
    let vehicleDoorNo: String?
    let lineCode: String
    let patternId: String
    let predictedMinutes: Double
    let rangeMinutes: ClosedRange<Double>
    let lastFixAge: TimeInterval?
    let confidence: Confidence
    let lowConfidenceReason: String?
    let state: DataState
    /// Metres the vehicle still has to cover along the route to reach the stop.
    let remainingMetres: Double?
    let stopsAway: Int?
    /// Set when the vehicle is reporting but has not moved. The minutes are
    /// then a floor, not a prediction, and the UI must say so.
    var stalledSeconds: TimeInterval? = nil

    /// True when ROVA should not put a confident minute figure on screen.
    var isUnreliable: Bool {
        if stalledSeconds != nil { return true }
        if case .delayedData = state { return true }
        return false
    }
}

// MARK: - Journey plan

struct JourneyLeg: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case walk, bus }
    let id = UUID()
    let kind: Kind
    let seconds: Int
    let distanceMetres: Double

    // bus legs
    let lineCode: String?
    let patternId: String?
    let headsign: String?
    let boardStop: Stop?
    let alightStop: Stop?
    let intermediateStops: Int
    /// Stop coordinates along this leg, for drawing the route.
    let shape: [CLLocationCoordinate2D]

    static func walk(seconds: Int, metres: Double, shape: [CLLocationCoordinate2D]) -> JourneyLeg {
        .init(kind: .walk, seconds: seconds, distanceMetres: metres, lineCode: nil,
              patternId: nil, headsign: nil, boardStop: nil, alightStop: nil,
              intermediateStops: 0, shape: shape)
    }

    func hash(into h: inout Hasher) { h.combine(id) }
    static func == (a: JourneyLeg, b: JourneyLeg) -> Bool { a.id == b.id }
}

struct JourneyOption: Identifiable, Hashable, Sendable {
    let id = UUID()
    let legs: [JourneyLeg]

    var busLegs: [JourneyLeg] { legs.filter { $0.kind == .bus } }
    var transfers: Int { max(0, busLegs.count - 1) }
    var walkSeconds: Int { legs.filter { $0.kind == .walk }.reduce(0) { $0 + $1.seconds } }
    var rideSeconds: Int { busLegs.reduce(0) { $0 + $1.seconds } }
    var walkMetres: Double { legs.filter { $0.kind == .walk }.reduce(0) { $0 + $1.distanceMetres } }
    var lineCodes: [String] { busLegs.compactMap(\.lineCode) }
    var firstBoardStop: Stop? { busLegs.first?.boardStop }

    func hash(into h: inout Hasher) { h.combine(id) }
    static func == (a: JourneyOption, b: JourneyOption) -> Bool { a.id == b.id }
}

/// A journey option joined with whatever live information exists right now.
struct LiveJourney: Identifiable, Sendable, Hashable {
    let option: JourneyOption
    /// Nearest vehicle on the first bus leg, catchable or not.
    let nearestETA: ETA?
    /// Other vehicles running the same leg, in arrival order.
    let alternatives: [ETA]
    var id: UUID { option.id }

    /// A measured pedestrian route to the boarding stop, when one is known.
    /// Set by `JourneyEngine`; nil means nobody has measured this walk yet.
    var measuredWalk: WalkTimes.Walk? = nil

    /// Seconds of walking between here and the boarding stop.
    ///
    /// Prefers a measured pedestrian route over the planner's straight-line
    /// estimate, because this figure decides when you are told to leave.
    var walkToStopSeconds: Int {
        if let m = measuredWalk { return m.seconds }
        return option.legs.first(where: { $0.kind == .walk })?.seconds ?? 0
    }

    /// False when the walk is still the planner's straight-line estimate.
    /// The UI says so rather than letting an estimate look like a measurement.
    var walkIsMeasured: Bool { measuredWalk?.isMeasured == true }

    /// The first vehicle you could actually reach on foot.
    ///
    /// A bus two minutes away is useless when the stop is an eleven minute
    /// walk, so ROVA counts down the first one you can still catch — with a
    /// one-minute grace for a brisk pace.
    var eta: ETA? {
        let grace = 60.0
        let needed = Double(walkToStopSeconds) - grace
        let all = ([nearestETA].compactMap { $0 } + alternatives)
            .sorted { $0.predictedMinutes < $1.predictedMinutes }
        return all.first { $0.predictedMinutes * 60 >= needed }
    }

    /// A vehicle that is arriving but cannot be reached in time, if any.
    var missedETA: ETA? {
        guard let n = nearestETA, n.vehicleDoorNo != eta?.vehicleDoorNo,
              n.predictedMinutes * 60 < Double(walkToStopSeconds) - 60 else { return nil }
        return n
    }

    /// Other catchable vehicles behind the one being counted down.
    var following: [ETA] {
        guard let chosen = eta else { return [] }
        return alternatives.filter {
            $0.vehicleDoorNo != chosen.vehicleDoorNo
                && $0.predictedMinutes > chosen.predictedMinutes
        }
    }

    /// Door-to-door seconds using the catchable live ETA when there is one.
    var totalSeconds: Int {
        let tail = option.walkSeconds - walkToStopSeconds
        guard let eta else { return option.walkSeconds + option.rideSeconds }
        let wait = max(walkToStopSeconds, Int(eta.predictedMinutes * 60))
        return wait + option.rideSeconds + tail
    }

    /// When to leave, measured against the **earliest** the bus could arrive,
    /// not the middle of the range.
    ///
    /// Telling someone to leave on a best guess of 9 minutes when the honest
    /// range is 6–15 is how you get sent down to the stop and left standing —
    /// or, worse, arrive to watch it pull away. ROVA uses the early end, so
    /// following its advice means you are there before the bus can be.
    func hash(into h: inout Hasher) { h.combine(option.id) }
    static func == (a: LiveJourney, b: LiveJourney) -> Bool {
        a.option.id == b.option.id
            && a.nearestETA?.vehicleDoorNo == b.nearestETA?.vehicleDoorNo
            && a.nearestETA?.predictedMinutes == b.nearestETA?.predictedMinutes
    }

    var leaveInSeconds: Int? {
        guard let eta else { return nil }
        let earliest = max(0, eta.rangeMinutes.lowerBound) * 60
        return Int(earliest) - walkToStopSeconds
    }

    /// The window in which the bus can realistically turn up.
    var arrivalWindow: ClosedRange<Date>? {
        guard let eta else { return nil }
        let now = Date()
        return now.addingTimeInterval(max(0, eta.rangeMinutes.lowerBound) * 60)
            ... now.addingTimeInterval(eta.rangeMinutes.upperBound * 60)
    }
}

// MARK: - Following one bus

/// One stop on the bus you pressed Start on.
struct TripStop: Identifiable, Sendable, Equatable {
    let code: String
    let name: String
    /// Position in the pattern, which is what orders the list.
    let index: Int
    let lat: Double
    let lon: Double
    /// Predicted arrival of *this vehicle* at this stop, nil when it cannot be
    /// estimated. Never a schedule dressed up as a prediction.
    let eta: Date?
    let passed: Bool
    let isBoard: Bool
    let isAlight: Bool
    /// Predicted run time from the previous stop in the list.
    let secondsFromPrevious: Int?

    var id: String { code + "#\(index)" }
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

// MARK: - Places

struct Place: Codable, Hashable, Sendable {
    var name: String
    var subtitle: String
    var lat: Double
    var lon: Double
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}
