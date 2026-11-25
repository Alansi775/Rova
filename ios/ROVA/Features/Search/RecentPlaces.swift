import Foundation

/// Places you have searched for before.
///
/// Typing the same destination every single day is the kind of friction that
/// makes an app feel like a form rather than a tool. Recents are stored on the
/// device and nowhere else: a list of where someone travels is about as
/// personal as data gets, and it has no business leaving the phone.
@MainActor
final class RecentPlaces: ObservableObject {
    static let shared = RecentPlaces()

    /// Enough to cover a routine without becoming a list nobody reads.
    static let limit = 8

    @Published private(set) var places: [Place] = []

    private let key = "rova.recentPlaces.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// Record a place, most recent first, without duplicating it.
    ///
    /// Matching is by rounded coordinate rather than by name: the same corner
    /// comes back from the geocoder as "Toker Kardeşler Sk. 1A" one day and
    /// "Toker Kardeşler Sokağı" the next, and a recents list that fills up
    /// with four spellings of one address is worse than none.
    func remember(_ place: Place) {
        var next = places.filter { !isSamePlace($0, place) }
        next.insert(place, at: 0)
        places = Array(next.prefix(Self.limit))
        save()
    }

    func remove(_ place: Place) {
        places.removeAll { isSamePlace($0, place) }
        save()
    }

    func removeAll() {
        places = []
        save()
    }

    private func isSamePlace(_ a: Place, _ b: Place) -> Bool {
        // ~11 m at Istanbul's latitude.
        func round4(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }
        return round4(a.lat) == round4(b.lat) && round4(a.lon) == round4(b.lon)
    }

    private func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Place].self, from: data)
        else { return }
        places = Array(decoded.prefix(Self.limit))
    }

    private func save() {
        if let data = try? JSONEncoder().encode(places) {
            defaults.set(data, forKey: key)
        }
    }
}
