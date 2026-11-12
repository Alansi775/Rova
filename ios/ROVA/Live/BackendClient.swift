import Foundation

/// Talks to the ROVA backend running on the Mac, reached over HTTPS.
///
/// Why it exists: İETT allows about 100 requests an hour per caller. When the
/// backend is the one calling, it spends that quota at the source's own 60 s
/// cadence and the phone can then poll **the backend** as often as it likes
/// for nothing — which is what makes the map refresh quickly on mobile data.
///
/// It is strictly an accelerator. Every failure here falls back to calling
/// İETT directly, so a dead tunnel or a sleeping Mac costs you nothing but a
/// slower refresh. The positions it returns are the same validated fixes with
/// their original `sourceTime`, so nothing is ever shown as fresher than it is.
actor BackendClient {
    static let shared = BackendClient()

    struct Config: Codable, Sendable, Equatable {
        var url: String
        var token: String
    }

    /// Loaded from an untracked bundled file, overridable in Settings.
    /// Nothing is compiled into the source, and nothing goes into Git.
    static func bundledConfig() -> Config? {
        guard let u = Bundle.main.url(forResource: "backend", withExtension: "json"),
              let d = try? Data(contentsOf: u),
              let c = try? JSONDecoder().decode(Config.self, from: d),
              !c.url.isEmpty, !c.token.isEmpty else { return nil }
        return c
    }

    private var config: Config?
    private var failures = 0
    private var mutedUntil: Date?
    private(set) var lastOutcome: String?

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 12
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    func configure(_ c: Config?) {
        if c != config { failures = 0; mutedUntil = nil }
        config = c
    }

    var isConfigured: Bool { config != nil }

    /// True when the backend is worth trying right now.
    var isAvailable: Bool {
        guard config != nil else { return false }
        if let m = mutedUntil, m > Date() { return false }
        return true
    }

    private func request(_ path: String, method: String) throws -> URLRequest {
        guard let c = config, let base = URL(string: c.url),
              let url = URL(string: path, relativeTo: base) else { throw Err.notConfigured }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer \(c.token)", forHTTPHeaderField: "Authorization")
        r.setValue("ROVA/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        return r
    }

    enum Err: Error, LocalizedError {
        case notConfigured, unavailable, badStatus(Int), empty
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "No ROVA backend configured"
            case .unavailable:   return "ROVA backend unreachable"
            case .badStatus(let c): return "ROVA backend returned \(c)"
            case .empty:         return "ROVA backend has no positions for this line yet"
            }
        }
    }

    /// Tell the backend which line to spend its İETT quota on, then read it.
    func vehicles(line: String, watch: Bool) async throws -> [Vehicle] {
        guard isAvailable else { throw Err.unavailable }
        do {
            if watch { _ = try? await send(request("v1/watch/\(line)", method: "POST")) }
            let data = try await send(request("v1/lines/\(line)/vehicles", method: "GET"))
            let decoded = try JSONDecoder().decode(Payload.self, from: data)
            let vehicles = decoded.vehicles.compactMap { $0.toVehicle(line: decoded.lineCode) }
            guard !vehicles.isEmpty else { throw Err.empty }
            failures = 0
            mutedUntil = nil
            lastOutcome = "ok"
            return vehicles
        } catch {
            failures += 1
            lastOutcome = error.localizedDescription
            // Back off rather than hammering a Mac that is asleep.
            if failures >= 2 {
                mutedUntil = Date().addingTimeInterval(min(300, Double(failures) * 45))
            }
            throw error
        }
    }

    private func send(_ r: URLRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw Err.unavailable }
        guard (200..<300).contains(http.statusCode) else { throw Err.badStatus(http.statusCode) }
        return data
    }

    /// Decoding is pure, so it is tested directly rather than over the network.
    nonisolated static func decodeForTesting(_ json: String) -> [Vehicle]? {
        guard let d = json.data(using: .utf8),
              let p = try? JSONDecoder().decode(Payload.self, from: d) else { return nil }
        return p.vehicles.compactMap { $0.toVehicle(line: p.lineCode) }
    }

    // MARK: wire format

    private struct Payload: Decodable {
        let lineCode: String
        let vehicles: [Row]
    }

    private struct Row: Decodable {
        struct Position: Decodable { let lat: Double; let lon: Double }
        let vehicleId: String
        let patternId: String?
        let position: Position
        let sourceTime: String
        let nearStopCode: String?

        /// The backend already validated these, but ROVA re-checks: a client
        /// that trusts its server blindly is a client that will one day draw a
        /// bus in the sea.
        func toVehicle(line: String) -> Vehicle? {
            guard position.lat > 40.5, position.lat < 41.9,
                  position.lon > 27.0, position.lon < 30.5 else { return nil }
            guard let fix = Self.iso.date(from: sourceTime)
                    ?? Self.isoPlain.date(from: sourceTime) else { return nil }
            guard fix.timeIntervalSinceNow < 60 else { return nil }   // no fixes from the future
            return Vehicle(doorNo: vehicleId, lat: position.lat, lon: position.lon,
                           lineCode: line, patternId: patternId ?? "",
                           lineName: "", direction: "",
                           lastFix: fix, nearStopCode: nearStopCode)
        }

        /// Built per call: ISO8601DateFormatter is not Sendable, and a shared
        /// instance would be a data race under Swift 6.
        private static var iso: ISO8601DateFormatter {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }
        private static var isoPlain: ISO8601DateFormatter { ISO8601DateFormatter() }
    }
}
