import Foundation
import CoreLocation

/// Plans bus journeys over the bundled İETT network.
///
/// Direct rides and single-transfer itineraries are enumerated from the
/// pattern/stop graph, then scored on door-to-door scheduled time. Live vehicle
/// information is layered on afterwards by `JourneyEngine` — the planner itself
/// never claims to know where a bus is.
struct JourneyPlanner {
    let store: TransitStore

    var walkSpeed: Double = 1.30          // m/s, a realistic city pace
    var detourFactor: Double = 1.32       // straight line → street distance
    var maxOriginWalk: Double = 1000
    var maxDestWalk: Double = 1000
    var maxTransferWalk: Double = 350

    struct Access { let stop: Stop; let metres: Double }

    func walkSeconds(_ metres: Double) -> Int { Int((metres * detourFactor / walkSpeed).rounded()) }

    private func access(near c: CLLocationCoordinate2D, radius: Double, limit: Int) -> [Access] {
        store.stopsNear(c, radius: radius, limit: limit).map { Access(stop: $0.0, metres: $0.1) }
    }

    // MARK: plan

    func plan(from origin: CLLocationCoordinate2D,
              to destination: CLLocationCoordinate2D,
              limit: Int = 6) -> [JourneyOption] {

        let starts = access(near: origin, radius: maxOriginWalk, limit: 30)
        let ends   = access(near: destination, radius: maxDestWalk, limit: 30)
        guard !starts.isEmpty, !ends.isEmpty else { return [] }

        let startWalk = Dictionary(starts.map { ($0.stop.code, $0.metres) }, uniquingKeysWith: min)
        let endWalk   = Dictionary(ends.map { ($0.stop.code, $0.metres) }, uniquingKeysWith: min)

        // pattern → ordered stops, loaded once
        var cache: [String: [PatternStop]] = [:]
        func stopsOf(_ pid: String) -> [PatternStop] {
            if let c = cache[pid] { return c }
            let s = store.patternStops(pid); cache[pid] = s; return s
        }

        // Patterns reachable from the origin: pattern → earliest boardable index
        var boardable: [String: (idx: Int, stop: String, walk: Double)] = [:]
        for a in starts {
            for (p, idx) in store.patternsCalling(at: a.stop.code) {
                let cur = boardable[p.id]
                if cur == nil || a.metres + Double(idx) * 0.1 < cur!.walk {
                    boardable[p.id] = (idx, a.stop.code, a.metres)
                }
            }
        }
        // Patterns that reach the destination: pattern → latest alighting index
        var alightable: [String: (idx: Int, stop: String, walk: Double)] = [:]
        for a in ends {
            for (p, idx) in store.patternsCalling(at: a.stop.code) {
                let cur = alightable[p.id]
                if cur == nil || a.metres < cur!.walk { alightable[p.id] = (idx, a.stop.code, a.metres) }
            }
        }

        var options: [JourneyOption] = []

        // ---- direct rides -------------------------------------------------
        for (pid, b) in boardable {
            guard let a = alightable[pid], a.idx > b.idx, let pat = store.patterns[pid] else { continue }
            guard let leg = busLeg(pattern: pat, stops: stopsOf(pid), from: b.idx, to: a.idx) else { continue }
            options.append(JourneyOption(legs: [
                .walk(seconds: walkSeconds(b.walk), metres: b.walk,
                      shape: [origin, store.stop(b.stop)!.coordinate]),
                leg,
                .walk(seconds: walkSeconds(a.walk), metres: a.walk,
                      shape: [store.stop(a.stop)!.coordinate, destination])
            ]))
        }

        // ---- one transfer --------------------------------------------------
        if options.count < limit {
            // downstream stops of boardable patterns
            var reach: [String: (pid: String, boardIdx: Int, idx: Int, seconds: Int)] = [:]
            for (pid, b) in boardable {
                let ps = stopsOf(pid)
                guard b.idx < ps.count else { continue }
                let base = ps[b.idx].offsetSec
                for i in (b.idx + 1)..<ps.count {
                    let code = ps[i].stopCode
                    let secs = max(60, ps[i].offsetSec - base)
                    if reach[code] == nil || secs < reach[code]!.seconds {
                        reach[code] = (pid, b.idx, i, secs)
                    }
                }
            }
            // upstream stops of alighting patterns
            var arrive: [String: (pid: String, idx: Int, alightIdx: Int, seconds: Int)] = [:]
            for (pid, a) in alightable {
                let ps = stopsOf(pid)
                guard a.idx < ps.count else { continue }
                let end = ps[a.idx].offsetSec
                for i in 0..<a.idx {
                    let code = ps[i].stopCode
                    let secs = max(60, end - ps[i].offsetSec)
                    if arrive[code] == nil || secs < arrive[code]!.seconds {
                        arrive[code] = (pid, i, a.idx, secs)
                    }
                }
            }
            var candidates: [(JourneyOption, Int)] = []
            for (code, r) in reach {
                guard let a = arrive[code], a.pid != r.pid,
                      store.patterns[r.pid]?.line != store.patterns[a.pid]?.line,
                      let transferStop = store.stop(code) else { continue }
                guard let p1 = store.patterns[r.pid], let p2 = store.patterns[a.pid],
                      let leg1 = busLeg(pattern: p1, stops: stopsOf(r.pid), from: r.boardIdx, to: r.idx),
                      let leg2 = busLeg(pattern: p2, stops: stopsOf(a.pid), from: a.idx, to: a.alightIdx)
                else { continue }
                let bw = boardable[r.pid]!.walk, aw = alightable[a.pid]!.walk
                let opt = JourneyOption(legs: [
                    .walk(seconds: walkSeconds(bw), metres: bw,
                          shape: [origin, store.stop(boardable[r.pid]!.stop)!.coordinate]),
                    leg1,
                    .walk(seconds: 45, metres: 0, shape: [transferStop.coordinate]),
                    leg2,
                    .walk(seconds: walkSeconds(aw), metres: aw,
                          shape: [store.stop(alightable[a.pid]!.stop)!.coordinate, destination])
                ])
                candidates.append((opt, opt.walkSeconds + opt.rideSeconds + 420))  // +7 min transfer penalty
            }
            candidates.sort { $0.1 < $1.1 }
            var seenPairs = Set<String>()
            for (opt, _) in candidates {
                let key = opt.lineCodes.joined(separator: ">")
                if seenPairs.insert(key).inserted { options.append(opt) }
                if options.count >= limit * 2 { break }
            }
        }

        // ---- rank & de-duplicate -------------------------------------------
        options.sort { score($0) < score($1) }
        var seen = Set<String>()
        var out: [JourneyOption] = []
        for o in options {
            let key = o.lineCodes.joined(separator: ">") + "|" + (o.firstBoardStop?.code ?? "")
            guard seen.insert(key).inserted else { continue }
            out.append(o)
            if out.count >= limit { break }
        }
        return out
    }

    private func score(_ o: JourneyOption) -> Int {
        o.walkSeconds + o.rideSeconds + o.transfers * 420 + Int(o.walkMetres / 4)
    }

    private func busLeg(pattern: Pattern, stops: [PatternStop], from: Int, to: Int) -> JourneyLeg? {
        guard from >= 0, to < stops.count, to > from,
              let board = store.stop(stops[from].stopCode),
              let alight = store.stop(stops[to].stopCode) else { return nil }
        let shape = stops[from...to].compactMap { store.stop($0.stopCode)?.coordinate }
        var metres = 0.0
        for i in 1..<max(1, shape.count) { metres += Geo.metres(shape[i-1], shape[i]) }
        let seconds = max(120, stops[to].offsetSec - stops[from].offsetSec)
        return JourneyLeg(kind: .bus, seconds: seconds, distanceMetres: metres,
                          lineCode: pattern.line, patternId: pattern.id,
                          headsign: pattern.headsign, boardStop: board, alightStop: alight,
                          intermediateStops: to - from, shape: shape)
    }
}
