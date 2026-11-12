import Foundation
import CoreLocation

/// Verified default journey.
///
/// Both coordinates were resolved with Apple's own geocoder (MKLocalSearch,
/// Istanbul region) and cross-checked against the İETT stop network:
/// the nearest stop to the origin is *Adile Naşit Caddesi* (108 m), on the
/// street named in the resolved address.
enum DefaultJourney {
    static let origin = Place(
        name: "Şafak Residence",
        subtitle: "Adile Naşit Blv. No:37, Esenyurt, İstanbul",
        lat: 41.016013, lon: 28.683227)

    static let destination = Place(
        name: "Avcılar Metrobüs",
        subtitle: "Avcılar Metrobüs İstasyonu, Avcılar, İstanbul",
        lat: 40.985755, lon: 28.724028)
}

/// User-visible settings, persisted in `UserDefaults`.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    @Published var home: Place { didSet { save(home, "rova.home") } }
    @Published var destination: Place { didSet { save(destination, "rova.dest") } }
    /// Optional ROVA backend (prediction logging + health). The app works fully
    /// without it — live data comes straight from İETT.
    @Published var backendURL: String {
        didSet { UserDefaults.standard.set(backendURL, forKey: "rova.backend") }
    }
    @Published var backendToken: String {
        didSet { UserDefaults.standard.set(backendToken, forKey: "rova.backendToken") }
    }
    /// Use the Mac's backend as the live source when it answers. Positions are
    /// identical — the backend simply pays the İETT quota so the phone need
    /// not, which lets the map refresh far more often on mobile data.
    @Published var useBackend: Bool {
        didSet { UserDefaults.standard.set(useBackend, forKey: "rova.useBackend") }
    }

    /// URL and token the app was built with, read from an untracked bundled
    /// file so no credential lives in the source or in Git.
    var effectiveBackend: BackendClient.Config? {
        let bundled = BackendClient.bundledConfig()
        let url = backendURL.trimmingCharacters(in: .whitespaces)
        let token = backendToken.trimmingCharacters(in: .whitespaces)
        let u = url.isEmpty ? (bundled?.url ?? "") : url
        let t = token.isEmpty ? (bundled?.token ?? "") : token
        guard useBackend, !u.isEmpty, !t.isEmpty else { return nil }
        return .init(url: u.hasSuffix("/") ? u : u + "/", token: t)
    }
    /// Start from where you are, not from a saved address. Turning this off
    /// pins the starting point to whatever you last chose.
    @Published var followMyLocation: Bool {
        didSet { UserDefaults.standard.set(followMyLocation, forKey: "rova.followMe") }
    }
    @Published var notifyBeforeMinutes: Int {
        didSet { UserDefaults.standard.set(notifyBeforeMinutes, forKey: "rova.notify") }
    }

    private init() {
        home = Self.load("rova.home") ?? DefaultJourney.origin
        destination = Self.load("rova.dest") ?? DefaultJourney.destination
        backendURL = UserDefaults.standard.string(forKey: "rova.backend") ?? ""
        backendToken = UserDefaults.standard.string(forKey: "rova.backendToken") ?? ""
        useBackend = UserDefaults.standard.object(forKey: "rova.useBackend") as? Bool ?? true
        followMyLocation = UserDefaults.standard.object(forKey: "rova.followMe") as? Bool ?? true
        let n = UserDefaults.standard.integer(forKey: "rova.notify")
        notifyBeforeMinutes = n == 0 ? 5 : n
    }

    private func save(_ p: Place, _ key: String) {
        if let d = try? JSONEncoder().encode(p) { UserDefaults.standard.set(d, forKey: key) }
    }
    private static func load(_ key: String) -> Place? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Place.self, from: d)
    }

    func resetJourney() {
        home = DefaultJourney.origin
        destination = DefaultJourney.destination
    }
}
