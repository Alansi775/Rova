import Foundation
import SwiftUI
import CoreLocation

/// Istanbul's rail network — metro, tram, funicular and cable car — from
/// Metro İstanbul's own public service.
///
/// Source: `https://api.ibb.gov.tr/MetroIstanbul/api/MetroMobile/V2/`, listed
/// on the İBB Open Data Portal as `metro-istanbul-hat-bilgisi-listesi` and
/// `metro-istanbul-istasyon-bilgi-listesi`. No key, no registration. Verified
/// returning 18 lines and stations with real coordinates.
///
/// **There is no live train tracking, and ROVA does not pretend otherwise.**
/// Metro İstanbul publishes lines, stations, service hours and timetables; it
/// publishes no train positions, and no endpoint for them was found. So rail
/// here is *timetable* information, marked as such everywhere it appears, and
/// it must never be drawn with the live vehicle markers used for buses. A bus
/// on this map is a real vehicle reporting its position; a train is a
/// published schedule. Those are different kinds of claim.
///
/// Line colours come from the service's own `Color` field rather than from
/// memory, so M2 is the green İstanbul actually signs it with.
@MainActor
final class MetroNetwork: ObservableObject {
    static let shared = MetroNetwork()

    struct Line: Codable, Identifiable, Sendable, Equatable {
        let id: Int
        let name: String            // "M2", "T1", "F1"
        let colourR: Int
        let colourG: Int
        let colourB: Int
        /// First and last service of the day, as published.
        let firstTime: String?
        let lastTime: String?

        var colour: Color { Color(red: Double(colourR) / 255,
                                  green: Double(colourG) / 255,
                                  blue: Double(colourB) / 255) }
    }

    struct Station: Codable, Identifiable, Sendable, Equatable {
        let id: Int
        let name: String
        let lineId: Int
        let lineName: String
        /// Position in the line's sequence, as published.
        let order: Int
        let lat: Double
        let lon: Double

        var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var stations: [Station] = []
    @Published private(set) var lastError: String?

    private let cache: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("metro-network.json")
    }()

    private struct Snapshot: Codable { let lines: [Line]; let stations: [Station]; let at: Date }

    private var loading = false

    /// The official colour for a rail line, or nil if it is not one.
    func colour(of lineName: String) -> Color? {
        lines.first { $0.name.caseInsensitiveCompare(lineName) == .orderedSame }?.colour
    }

    func stations(onLine lineName: String) -> [Station] {
        stations.filter { $0.lineName.caseInsensitiveCompare(lineName) == .orderedSame }
            .sorted { $0.order < $1.order }
    }

    /// Load from disk, then refresh from the service if the cache is old.
    func load() {
        guard !loading else { return }
        loading = true
        if let d = try? Data(contentsOf: cache),
           let s = try? JSONDecoder().decode(Snapshot.self, from: d) {
            lines = s.lines
            stations = s.stations
            // The network changes when a line opens, not by the hour.
            if Date().timeIntervalSince(s.at) < 7 * 24 * 3600 { loading = false; return }
        }
        Task { [weak self] in
            let fetched = await Self.fetch()
            guard let self else { return }
            loading = false
            switch fetched {
            case .success(let snap):
                lines = snap.lines
                stations = snap.stations
                lastError = nil
                if let d = try? JSONEncoder().encode(snap) { try? d.write(to: cache) }
            case .failure(let e):
                // Keep whatever the cache held; say what went wrong rather
                // than silently showing an empty network.
                lastError = e.message
            }
        }
    }

    struct FetchError: Error { let message: String }

    private nonisolated static func fetch() async -> Result<Snapshot, FetchError> {
        let base = "https://api.ibb.gov.tr/MetroIstanbul/api/MetroMobile/V2/"
        do {
            async let l: [Line] = decodeLines(from: URL(string: base + "GetLines")!)
            async let s: [Station] = decodeStations(from: URL(string: base + "GetStations")!)
            let (lines, stations) = try await (l, s)
            guard !lines.isEmpty, !stations.isEmpty else {
                return .failure(FetchError(message: "Metro İstanbul returned an empty network"))
            }
            return .success(Snapshot(lines: lines, stations: stations, at: Date()))
        } catch {
            return .failure(FetchError(message: error.localizedDescription))
        }
    }

    // MARK: wire format

    private struct Envelope<T: Decodable>: Decodable {
        let Success: Bool
        let Data: T?
    }

    private struct RawColour: Decodable {
        let Color_R: String?; let Color_G: String?; let Color_B: String?
    }

    private struct RawLine: Decodable {
        let Id: Int; let Name: String; let Color: RawColour?
        let FirstTime: String?; let LastTime: String?
    }

    private struct RawStationDetail: Decodable {
        let Latitude: String?; let Longitude: String?
    }

    private struct RawStation: Decodable {
        let Id: Int; let Name: String; let LineId: Int; let LineName: String?
        let Order: Int?; let DetailInfo: RawStationDetail?
    }

    private nonisolated static func decodeLines(from url: URL) async throws -> [Line] {
        let (d, _) = try await URLSession.shared.data(from: url)
        let env = try JSONDecoder().decode(Envelope<[RawLine]>.self, from: d)
        guard env.Success, let rows = env.Data else { return [] }
        return rows.compactMap { r in
            // A line with no published colour is kept; the UI falls back to
            // ink rather than inventing a shade.
            Line(id: r.Id, name: r.Name,
                 colourR: Int(r.Color?.Color_R ?? "") ?? 0,
                 colourG: Int(r.Color?.Color_G ?? "") ?? 0,
                 colourB: Int(r.Color?.Color_B ?? "") ?? 0,
                 firstTime: r.FirstTime, lastTime: r.LastTime)
        }
    }

    private nonisolated static func decodeStations(from url: URL) async throws -> [Station] {
        let (d, _) = try await URLSession.shared.data(from: url)
        let env = try JSONDecoder().decode(Envelope<[RawStation]>.self, from: d)
        guard env.Success, let rows = env.Data else { return [] }
        return rows.compactMap { r in
            // Coordinates arrive as strings and are sometimes absent. A
            // station without a position is dropped rather than placed at
            // zero, which would put it in the Gulf of Guinea.
            guard let latS = r.DetailInfo?.Latitude, let lonS = r.DetailInfo?.Longitude,
                  let lat = Double(latS), let lon = Double(lonS),
                  (40.5...41.9).contains(lat), (27.0...30.5).contains(lon) else { return nil }
            return Station(id: r.Id, name: r.Name, lineId: r.LineId,
                           lineName: r.LineName ?? "", order: r.Order ?? 0,
                           lat: lat, lon: lon)
        }
    }

    /// Exposed for tests: parse without hitting the network.
    nonisolated static func decodeLinesForTesting(_ json: String) -> [Line]? {
        guard let d = json.data(using: .utf8),
              let env = try? JSONDecoder().decode(Envelope<[RawLine]>.self, from: d),
              let rows = env.Data else { return nil }
        return rows.map {
            Line(id: $0.Id, name: $0.Name,
                 colourR: Int($0.Color?.Color_R ?? "") ?? 0,
                 colourG: Int($0.Color?.Color_G ?? "") ?? 0,
                 colourB: Int($0.Color?.Color_B ?? "") ?? 0,
                 firstTime: $0.FirstTime, lastTime: $0.LastTime)
        }
    }
}
