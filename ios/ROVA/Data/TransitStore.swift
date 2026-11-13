import Foundation
import SQLite3
import CoreLocation

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Read-only access to the bundled Istanbul transit network
/// (IETT stops + lines from the official SOAP service, patterns and schedules
/// derived from the İBB Open Data GTFS feed).
final class TransitStore: @unchecked Sendable {
    static let shared = TransitStore()

    private var db: OpaquePointer?
    private(set) var stops: [String: Stop] = [:]
    private(set) var lines: [String: BusLine] = [:]
    private(set) var patterns: [String: Pattern] = [:]
    private(set) var meta: [String: String] = [:]
    private var stopGrid: [GridKey: [Stop]] = [:]
    private var patternStopCache: [String: [PatternStop]] = [:]
    /// Separate from the SQLite lock so caching never nests inside a query.
    private let cacheLock = NSLock()
    private let lock = NSLock()

    private struct GridKey: Hashable { let x: Int; let y: Int }
    private static let cell = 0.01   // ≈ 1.1 km latitude

    private init() { open() }

    private func open() {
        guard let url = Bundle.main.url(forResource: "rova-transit", withExtension: "sqlite") else {
            assertionFailure("rova-transit.sqlite missing from bundle"); return
        }
        // FULLMUTEX as well as the lock above. The connection was opened in a
        // mode that traps on concurrent use — the crash report read
        // `sqlite3MutexMisuseAssert` inside `each` — and belt and braces is
        // the right answer for the one file the whole app reads from.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            assertionFailure("cannot open transit bundle"); return
        }
        loadStops(); loadLines(); loadPatterns(); loadMeta()
    }

    // MARK: query helper

    /// Every read goes through here, and every read takes the lock.
    ///
    /// One SQLite connection was being stepped from the main actor (the map,
    /// the trip stop list, search) and from the detached planner at the same
    /// time, and the in-memory caches were being mutated from both. That is
    /// what crashed the app while typing a destination: searching triggers a
    /// re-plan, and the two collided. The lock is reentrant-safe here because
    /// no query runs another query inside its row callback.
    private func each(_ sql: String, _ binds: [String] = [], _ row: (OpaquePointer) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        for (i, b) in binds.enumerated() {
            sqlite3_bind_text(st, Int32(i + 1), b, -1, SQLITE_TRANSIENT)
        }
        while sqlite3_step(st) == SQLITE_ROW { row(st!) }
    }

    private func text(_ s: OpaquePointer, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(s, i) else { return "" }
        return String(cString: c)
    }

    // MARK: loading

    private func loadStops() {
        each("SELECT code,name,lat,lon,district,direction,smart FROM stop") { s in
            let stop = Stop(code: text(s, 0), name: text(s, 1),
                            lat: sqlite3_column_double(s, 2), lon: sqlite3_column_double(s, 3),
                            district: text(s, 4), direction: text(s, 5),
                            smart: sqlite3_column_int(s, 6) == 1)
            stops[stop.code] = stop
            stopGrid[key(stop.lat, stop.lon), default: []].append(stop)
        }
    }

    private func loadLines() {
        each("SELECT code,name,length_km,trip_min FROM line") { s in
            let l = BusLine(code: text(s, 0), name: text(s, 1),
                            lengthKm: sqlite3_column_double(s, 2),
                            tripMinutes: sqlite3_column_double(s, 3))
            lines[l.code] = l
        }
    }

    private func loadPatterns() {
        each("SELECT id,line,direction,headsign,note,stop_count FROM pattern") { s in
            let p = Pattern(id: text(s, 0), line: text(s, 1), direction: text(s, 2),
                            headsign: text(s, 3), note: text(s, 4),
                            stopCount: Int(sqlite3_column_int(s, 5)))
            patterns[p.id] = p
        }
    }

    private func loadMeta() {
        each("SELECT k,v FROM meta") { s in meta[text(s, 0)] = text(s, 1) }
    }

    private func key(_ lat: Double, _ lon: Double) -> GridKey {
        GridKey(x: Int(floor(lon / Self.cell)), y: Int(floor(lat / Self.cell)))
    }

    // MARK: public API

    var isReady: Bool { !stops.isEmpty && !patterns.isEmpty }

    func stop(_ code: String) -> Stop? { stops[code] }
    func line(_ code: String) -> BusLine? { lines[code] }

    /// Stops within `radius` metres, nearest first.
    func stopsNear(_ c: CLLocationCoordinate2D, radius: Double, limit: Int = 40) -> [(Stop, Double)] {
        let span = Int(ceil(radius / 1000.0)) + 1
        let k = key(c.latitude, c.longitude)
        var out: [(Stop, Double)] = []
        for dx in -span...span {
            for dy in -span...span {
                for s in stopGrid[GridKey(x: k.x + dx, y: k.y + dy)] ?? [] {
                    let d = Geo.metres(c, s.coordinate)
                    if d <= radius { out.append((s, d)) }
                }
            }
        }
        out.sort { $0.1 < $1.1 }
        return Array(out.prefix(limit))
    }

    func patternStops(_ patternId: String) -> [PatternStop] {
        cacheLock.lock()
        if let c = patternStopCache[patternId] { cacheLock.unlock(); return c }
        cacheLock.unlock()

        var out: [PatternStop] = []
        each("SELECT seq,stop,offset_sec FROM pattern_stop WHERE pattern=? ORDER BY seq",
             [patternId]) { s in
            out.append(PatternStop(seq: Int(sqlite3_column_int(s, 0)),
                                   stopCode: text(s, 1),
                                   offsetSec: Int(sqlite3_column_int(s, 2))))
        }
        cacheLock.lock()
        patternStopCache[patternId] = out
        cacheLock.unlock()
        return out
    }

    /// Stop coordinates along a pattern — used as the route geometry.
    func patternShape(_ patternId: String) -> [CLLocationCoordinate2D] {
        patternStops(patternId).compactMap { stops[$0.stopCode]?.coordinate }
    }

    func patterns(ofLine code: String) -> [Pattern] {
        patterns.values.filter { $0.line == code }
    }

    /// Patterns that call at a stop, with the stop's index in each.
    func patternsCalling(at stopCode: String) -> [(Pattern, Int)] {
        var out: [(Pattern, Int)] = []
        each("SELECT pattern,seq FROM pattern_stop WHERE stop=?", [stopCode]) { s in
            if let p = patterns[text(s, 0)] { out.append((p, Int(sqlite3_column_int(s, 1)))) }
        }
        return out
    }

    /// The distinct lines that call at a stop, ordered.
    ///
    /// Exists because a stop's *name* is not a reliable guide to what serves
    /// it: "AVCILAR METROBÜS" is an ordinary bus stop named after the
    /// Metrobüs station, served only by 76D and 76O, while the actual
    /// Metrobüs platforms are 242 m away under an entirely different name.
    /// Someone choosing that stop expecting a Metrobüs has been misled by the
    /// data, and the only fix is to show what really calls there.
    func linesCalling(at stopCode: String) -> [String] {
        var seen = Set<String>()
        for (p, _) in patternsCalling(at: stopCode) { seen.insert(p.line) }
        return seen.sorted()
    }

    // MARK: schedules

    /// GTFS service ids active on a given date.
    func activeServices(on date: Date) -> [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        let wd = cal.component(.weekday, from: date)   // 1 = Sunday
        let col = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"][wd - 1]
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"
        f.timeZone = cal.timeZone
        let today = f.string(from: date)
        var out: [String] = []
        each("SELECT id FROM service WHERE \(col)=1 AND start_date<=? AND end_date>=?",
             [today, today]) { s in out.append(text(s, 0)) }
        return out
    }

    /// Scheduled departure seconds-after-midnight for a pattern today.
    func departures(pattern: String, services: [String]) -> [Int] {
        guard !services.isEmpty else { return [] }
        let qs = services.map { _ in "?" }.joined(separator: ",")
        var out: [Int] = []
        each("SELECT start_sec FROM departure WHERE pattern=? AND service IN (\(qs)) ORDER BY start_sec",
             [pattern] + services) { s in out.append(Int(sqlite3_column_int(s, 0))) }
        return out
    }
}
