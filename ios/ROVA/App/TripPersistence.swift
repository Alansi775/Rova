import Foundation

/// Remembers the trip you are on, across leaving the app and coming back.
///
/// A rider standing on a bus, having pressed Start, switched away and returned
/// to find the trip gone and the app offering buses that were still to come.
/// Everything about the trip lived in memory only, and `JourneyOption.id` is a
/// fresh UUID on every plan, so even re-planning the identical journey produced
/// something the old state could not be matched against.
///
/// Only what cannot be derived is stored: which vehicle, which journey (by its
/// stable signature), and when it started. The journey itself is replanned on
/// launch and matched by signature, so a restored trip is a real current plan
/// rather than a stale snapshot of one.
///
/// A trip is not restored indefinitely. Nobody is still on a bus they boarded
/// six hours ago, and restoring one would be its own kind of lie — the app
/// would claim to know where someone is when it has no idea.
struct TripPersistence {
    struct Saved: Codable, Equatable {
        let doorNo: String
        let signature: String
        let startedAt: Date
        /// True when the rider said they had actually boarded.
        let onBoard: Bool
    }

    /// Beyond this a saved trip is discarded rather than restored.
    static let maximumAge: TimeInterval = 3 * 3600

    private let key = "rova.trip.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func save(_ trip: Saved?) {
        guard let trip else { defaults.removeObject(forKey: key); return }
        if let data = try? JSONEncoder().encode(trip) {
            defaults.set(data, forKey: key)
        }
    }

    /// The saved trip, or nil if there is none or it is too old to believe.
    func load(now: Date = Date()) -> Saved? {
        guard let data = defaults.data(forKey: key),
              let trip = try? JSONDecoder().decode(Saved.self, from: data)
        else { return nil }
        guard now.timeIntervalSince(trip.startedAt) <= Self.maximumAge else {
            defaults.removeObject(forKey: key)
            return nil
        }
        return trip
    }

    func clear() { defaults.removeObject(forKey: key) }
}
