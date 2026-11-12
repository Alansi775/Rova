import Foundation
import SwiftUI
import CoreLocation

/// Orchestrates planning, live polling and ETA computation.
@MainActor
final class JourneyEngine: ObservableObject {

    // Published state ----------------------------------------------------
    @Published private(set) var options: [JourneyOption] = []
    @Published private(set) var live: [UUID: (eta: ETA?, alternatives: [ETA])] = [:]
    @Published private(set) var vehicles: [String: [Vehicle]] = [:]      // line → vehicles
    @Published private(set) var isPlanning = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var liveProblem: String?
    @Published private(set) var requestsLeft: Int = 80

    /// Where the positions on screen came from, most recently.
    enum LiveSource: Equatable { case none, backend, direct }
    @Published private(set) var liveSource: LiveSource = .none
    @Published private(set) var backendStatus = "Not configured"

    var backendTint: Color {
        switch liveSource {
        case .backend: return RV.Color.live
        case .direct:  return RV.Color.warn
        case .none:    return RV.Color.scheduled
        }
    }

    /// Apply the user's backend settings. Safe to call repeatedly.
    func applyBackend(_ config: BackendClient.Config?) async {
        await BackendClient.shared.configure(config)
        await LiveSocket.shared.configure(config)
        if config == nil {
            liveSource = .none
            backendStatus = "Off — reading İETT directly"
            await LiveSocket.shared.disconnect()
        } else {
            backendStatus = "Connecting…"
            await installSocketHandler()
        }
    }

    /// Push updates land here. They are merged exactly like polled ones, so a
    /// pushed fix gets the same retention, the same güzergah filter and the
    /// same pinning of the bus being followed — delivery changed, not truth.
    private var socketInstalled = false
    private func installSocketHandler() async {
        guard !socketInstalled else { return }
        socketInstalled = true
        await LiveSocket.shared.onVehicles { [weak self] line, fresh in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.vehicles[line] = Self.merge(
                    existing: self.vehicles[line] ?? [], fresh: fresh,
                    pinned: self.tripDoorNo ?? self.onBoardDoorNo)
                self.lastRefresh = Date()
                self.liveSource = .backend
                self.backendStatus = "Live — pushed from backend"
                self.recompute()
            }
        }
    }

    /// Tell the backend which lines are worth the İETT quota, and keep the
    /// socket subscribed to them.
    private func syncSocketSubscription() {
        let wanted = Set(watchList.prefix(2))
        guard !wanted.isEmpty else { return }
        Task { await LiveSocket.shared.subscribe(to: wanted) }
    }

    nonisolated func applyBackendLater(_ config: BackendClient.Config?) {
        Task { await self.applyBackend(config) }
    }
    @Published var selected: JourneyOption?
    @Published var trackedVehicleDoorNo: String?
    /// The vehicle the user says they are riding. Changes what the whole app
    /// is about: not "when does it get here" but "when do I get off".
    @Published var onBoardDoorNo: String?

    /// Slides vehicle markers between the feed's ~60 s fixes. Observed
    /// directly by the map so a 8 Hz position update does not redraw the sheet.
    let motion = VehicleAnimator()

    private let store = TransitStore.shared
    private lazy var planner = JourneyPlanner(store: store)
    private lazy var eta = ETAEngine(store: store)
    private var histories: [String: VehicleHistory] = [:]
    private var lastFetch: [String: Date] = [:]
    private var ticker: Task<Void, Never>?

    /// Journeys ordered by when they actually get you there, which is the only
    /// ordering that matters: walk + wait (live if known, timetable otherwise)
    /// + ride. A faster bus you have to wait 40 minutes for is not the best
    /// option at 5 a.m.
    var journeys: [LiveJourney] {
        let all = options.map { o -> LiveJourney in
            let l = live[o.id]
            return LiveJourney(option: o, nearestETA: l?.eta, alternatives: l?.alternatives ?? [])
        }
        return all.sorted { doorToDoor($0) < doorToDoor($1) }
    }

    /// Seconds from now until arrival, or a large sentinel when the option
    /// cannot be served today.
    func doorToDoor(_ j: LiveJourney) -> Int {
        let walkToStop = j.walkToStopSeconds
        let tail = j.option.walkSeconds - walkToStop
        let wait: Int
        if let eta = j.eta {
            wait = max(walkToStop, Int(eta.predictedMinutes * 60))
        } else if let leg = j.option.busLegs.first,
                  let next = cachedDeparture(for: leg) {
            let until = Int(next.timeIntervalSinceNow)
            guard until >= walkToStop - 120 else { return 1 << 24 }
            wait = max(walkToStop, until)
        } else {
            return 1 << 24
        }
        return wait + j.option.rideSeconds + tail
    }

    private var departureCache: [UUID: Date?] = [:]

    private func cachedDeparture(for leg: JourneyLeg) -> Date? {
        if let c = departureCache[leg.id] { return c }
        let d = scheduledDepartures(for: leg, limit: 1).first
        departureCache[leg.id] = d
        return d
    }

    /// Put a journey on the map: it becomes the focused one, its line is
    /// fetched straight away rather than at the next tick, and its buses are
    /// handed to the animator immediately so the map is never briefly empty.
    func select(_ option: JourneyOption) {
        selected = option
        trackedVehicleDoorNo = nil
        refreshMotion()
        guard let line = option.busLegs.first?.lineCode else { return }
        Task { [weak self] in
            guard let self else { return }
            let age = lastFetch[line].map { Date().timeIntervalSince($0) } ?? .infinity
            if age > 25 { await fetch(line: line) }
            recompute()
        }
    }

    /// Back to whatever ROVA thinks is best.
    func clearSelection() {
        selected = nil
        trackedVehicleDoorNo = nil
        refreshMotion()
    }

    var selectedJourney: LiveJourney? {
        guard let s = selected else { return nil }
        return journeys.first { $0.option.id == s.id }
    }

    // MARK: planning

    func plan(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D,
              force: Bool = false) async {
        // Re-planning rebuilds every option, which would drop the journey the
        // user is in the middle of. While a trip is running, only an explicit
        // action may replan.
        if tripDoorNo != nil && !force { return }
        isPlanning = true
        let p = planner
        let result = await Task.detached(priority: .userInitiated) {
            p.plan(from: from, to: to, limit: 6)
        }.value
        options = result
        live = [:]
        departureCache = [:]
        if let sel = selected, !result.contains(where: { $0.id == sel.id }) { selected = nil }
        isPlanning = false
        await refresh(force: true)
    }

    // MARK: live refresh

    /// The journey currently on screen: the user's choice, else the best one.
    var focusedJourney: LiveJourney? { selectedJourney ?? journeys.first }

    /// Lines worth watching, most important first.
    private var watchList: [String] {
        var seen = Set<String>()
        var out: [String] = []
        if let d = onBoardDoorNo, let l = vehicle(doorNo: d)?.lineCode, seen.insert(l).inserted {
            out.append(l)
        }
        if let l = focusedJourney?.option.busLegs.first?.lineCode, seen.insert(l).inserted {
            out.append(l)
        }
        for j in journeys.prefix(4) {
            for l in j.option.lineCodes where seen.insert(l).inserted { out.append(l) }
        }
        return out
    }

    /// Target refresh interval per line.
    ///
    /// Measured on 2026-11-12: İETT publishes a new `son_konum_zamani` for a
    /// moving vehicle every ~60 s (observed gaps 53–67 s). Polling faster than
    /// the source refreshes buys nothing and spends the hourly quota, so the
    /// line being watched is polled at the source cadence and the rest much
    /// more slowly.
    private func interval(for line: String) -> TimeInterval {
        let focused = line == focusedJourney?.option.busLegs.first?.lineCode
        // With the socket live, polling is a safety net rather than the means
        // of delivery: updates arrive as the backend ingests them. Keep a slow
        // poll anyway, so a silently half-dead socket cannot freeze the map.
        if socketIsLive { return focused ? 90 : 300 }
        // Reading from our own backend costs no İETT quota, so the watched
        // line can be pulled far more often — which is what keeps the map
        // feeling alive on mobile data.
        if liveSource == .backend { return focused ? 20 : 180 }
        return focused ? 60 : 600
    }

    func startLiveUpdates() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollSocketState()
                await self?.tick()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    @Published private(set) var socketIsLive = false

    private func pollSocketState() async {
        let s = await LiveSocket.shared.state
        socketIsLive = (s == .live)
        syncSocketSubscription()
    }

    func stopLiveUpdates() {
        ticker?.cancel(); ticker = nil; motion.clear()
        Task { await LiveSocket.shared.disconnect() }
    }

    private func tick() async {
        // Pick the single most overdue line, so we never burst the İETT quota.
        let due = watchList
            .map { ($0, (lastFetch[$0].map { Date().timeIntervalSince($0) } ?? .infinity) / interval(for: $0)) }
            .filter { $0.1 >= 1 }
            .sorted { $0.1 > $1.1 }
        guard let next = due.first?.0 else { return }
        await fetch(line: next)
        recompute()
    }

    func refresh(force: Bool = false) async {
        isRefreshing = true
        defer { isRefreshing = false }
        for line in watchList.prefix(force ? 3 : 1) {
            await fetch(line: line, force: force)
        }
        recompute()
    }

    private func fetch(line: String, force: Bool = false) async {
        // Prefer the ROVA backend: it pays İETT's hourly quota, so the phone
        // can ask it far more often. Anything at all goes wrong — Mac asleep,
        // tunnel down, no data for the line — and we fall straight through to
        // İETT, which is what the app has always done.
        if await BackendClient.shared.isAvailable {
            let watch = line == focusedJourney?.option.busLegs.first?.lineCode
            do {
                let v = try await BackendClient.shared.vehicles(line: line, watch: watch)
                accept(v, for: line)
                liveSource = .backend
                backendStatus = "Connected — \(v.count) vehicles on \(line)"
                liveProblem = nil
                return
            } catch {
                backendStatus = error.localizedDescription
            }
        } else if await BackendClient.shared.isConfigured {
            backendStatus = "Unreachable — reading İETT directly"
        }

        do {
            let v = try await IETTLiveClient.shared.vehicles(line: line, force: force)
            accept(v, for: line)
            liveSource = .direct
        } catch {
            if case LiveError.budgetExhausted = error {
                // Silent: the scheduler simply waits.
            } else {
                liveProblem = error.localizedDescription
            }
            lastFetch[line] = Date()
        }
        requestsLeft = await IETTLiveClient.shared.remainingRequestsThisHour
    }

    /// Test seam: push known positions in without touching the network.
    func injectForTesting(vehicles v: [Vehicle], line: String) {
        accept(v, for: line)
        recompute()
    }

    private func accept(_ v: [Vehicle], for line: String) {
        vehicles[line] = Self.merge(existing: vehicles[line] ?? [], fresh: v,
                                    pinned: tripDoorNo ?? onBoardDoorNo)
        lastFetch[line] = Date()
        lastRefresh = Date()
        for veh in v { histories[veh.doorNo, default: VehicleHistory()].record(veh) }
    }

    /// İETT occasionally omits a vehicle from a single response and includes
    /// it again in the next one. Replacing the list wholesale made markers
    /// blink out and back; instead a vehicle is kept until its own last fix is
    /// genuinely old, and its true fix age keeps driving its data state, so
    /// nothing is shown as fresher than it is.
    nonisolated static func merge(existing: [Vehicle], fresh: [Vehicle],
                                  keepFor: TimeInterval = 150,
                                  pinned: String? = nil) -> [Vehicle] {
        var byDoor = Dictionary(fresh.map { ($0.doorNo, $0) }, uniquingKeysWith: { a, _ in a })
        for old in existing where byDoor[old.doorNo] == nil {
            // The bus you are riding is never quietly removed. Losing it
            // mid-journey and making you set your location again is not an
            // acceptable answer; if the feed goes quiet ROVA says so and keeps
            // the last known position on screen, labelled with its real age.
            if old.doorNo == pinned || old.fixAge <= keepFor { byDoor[old.doorNo] = old }
        }
        return Array(byDoor.values)
    }

    /// Door numbers already accepted as running the watched route. Keeping them
    /// is what stops a noisy fix from making a bus vanish for one poll: a
    /// vehicle joins at 450 m from the route and only leaves beyond 900 m.
    private var onRouteDoors: Set<String> = []

    func invalidateSchedules() { departureCache = [:] }

    private func recompute() {
        departureCache = [:]          // timetable answers age as the clock moves
        var next: [UUID: (ETA?, [ETA])] = [:]
        for o in options {
            guard let leg = o.busLegs.first, let line = leg.lineCode,
                  let board = leg.boardStop else { continue }
            let pool = vehicles[line] ?? []
            guard !pool.isEmpty else { next[o.id] = (nil, []); continue }
            let cands = eta.candidates(vehicles: pool, lineCode: line, boardStop: board,
                                       preferredPattern: leg.patternId, histories: histories)
            next[o.id] = (cands.first?.eta, cands.dropFirst().prefix(4).map(\.eta))
        }
        live = next
        refreshMotion()
    }

    // MARK: vehicle lookup

    func vehicle(doorNo: String) -> Vehicle? {
        for (_, list) in vehicles { if let v = list.first(where: { $0.doorNo == doorNo }) { return v } }
        return nil
    }

    func history(doorNo: String) -> VehicleHistory? { histories[doorNo] }

    /// Vehicles worth drawing on the map for the current context.
    var mapVehicles: [Vehicle] {
        guard let ctx = routeContext else { return [] }
        let followed = tripDoorNo ?? onBoardDoorNo
        return (vehicles[ctx.line] ?? []).filter { v in
            // Whatever else the filters say, the bus you are on stays.
            if v.doorNo == followed { return true }
            // The same line runs back the other way along the same road, and
            // those buses snapped onto this route perfectly — which is how a
            // bus that was driving *away* appeared on the map as one coming
            // towards you. A vehicle is only drawn on this route if it says it
            // is running this güzergah.
            guard v.patternId.isEmpty || v.patternId == ctx.patternId else { return false }
            guard let snap = Geo.snap(v.coordinate, to: ctx.shape) else { return false }
            let limit = onRouteDoors.contains(v.doorNo) ? 900.0 : 450.0
            guard snap.offset < limit else { return false }
            let behind = ctx.boardAlong - snap.along
            return behind > -1500 && behind < 25_000
        }
    }

    struct RouteContext {
        let line: String
        let patternId: String
        let shape: [CLLocationCoordinate2D]
        let boardAlong: Double
        let boardStop: Stop
    }

    /// Geometry of the bus leg currently on screen.
    var routeContext: RouteContext? {
        guard let leg = focusedJourney?.option.busLegs.first,
              let line = leg.lineCode, let board = leg.boardStop,
              let pid = leg.patternId else { return nil }
        let shape = store.patternShape(pid)
        guard shape.count > 2 else { return nil }
        let stops = store.patternStops(pid)
        let boardIdx = stops.firstIndex { $0.stopCode == board.code } ?? 0
        let cum = Geo.cumulative(shape)
        return RouteContext(line: line, patternId: pid, shape: shape,
                            boardAlong: cum[min(boardIdx, cum.count - 1)],
                            boardStop: board)
    }

    /// Hands the animator the route and the latest fixes.
    private func refreshMotion() {
        guard let ctx = routeContext else { motion.clear(); return }
        motion.setRoute(ctx.shape, boardAlong: ctx.boardAlong)
        let onScreen = mapVehicles
        onRouteDoors = Set(onScreen.map(\.doorNo))
        guard !onScreen.isEmpty else { motion.clear(); return }
        let speeds = Dictionary(uniqueKeysWithValues:
            onScreen.map { ($0.doorNo, histories[$0.doorNo]?.speedMetresPerSecond) })
        motion.update(vehicles: onScreen, speeds: speeds)
    }

    /// Where a tapped bus is now, and the stop it is coming to. The map cuts
    /// whichever geometry it is drawing between these two points.
    func approachEndpoints(forVehicle door: String)
        -> (CLLocationCoordinate2D, CLLocationCoordinate2D)? {
        guard let ctx = routeContext, let v = vehicle(doorNo: door),
              let snap = Geo.snap(v.coordinate, to: ctx.shape), snap.offset < 900,
              snap.along < ctx.boardAlong else { return nil }
        let here = motion.display(doorNo: door)?.coordinate ?? v.coordinate
        return (here, ctx.boardStop.coordinate)
    }

    /// Where you are now, and where you get off.
    func rideAheadEndpoints() -> (CLLocationCoordinate2D, CLLocationCoordinate2D)? {
        guard let door = onBoardDoorNo, let leg = onBoardLeg,
              let alight = leg.alightStop else { return nil }
        let here = motion.display(doorNo: door)?.coordinate
            ?? vehicle(doorNo: door)?.coordinate
        guard let here else { return nil }
        return (here, alight.coordinate)
    }

    /// The stretch of route a tapped bus still has to cover before it reaches
    /// your boarding stop — "where it is now, and how it gets to me".
    func approachShape(forVehicle door: String) -> [CLLocationCoordinate2D] {
        guard let ctx = routeContext,
              let v = vehicle(doorNo: door),
              let snap = Geo.snap(v.coordinate, to: ctx.shape), snap.offset < 900,
              snap.along < ctx.boardAlong else { return [] }
        let cum = Geo.cumulative(ctx.shape)
        // Start from where the marker is drawn, not the raw fix, so the line
        // begins at the bus you can see.
        let from = motion.display(doorNo: door).flatMap {
            Geo.snap($0.coordinate, to: ctx.shape)?.along
        } ?? snap.along
        return Geo.slice(ctx.shape, cumulative: cum,
                         from: min(from, ctx.boardAlong), to: ctx.boardAlong)
    }

    /// The part of the route that bus then carries you along, board → alight.
    func rideShape() -> [CLLocationCoordinate2D] {
        focusedJourney?.option.busLegs.first?.shape ?? []
    }

    /// Tapping a bus should show the journey that bus actually gives you, so a
    /// tap on a vehicle belonging to another option switches to that option.
    func selectVehicle(_ door: String) {
        if let v = vehicle(doorNo: door),
           focusedJourney?.option.busLegs.first?.lineCode != v.lineCode,
           let owning = journeys.first(where: { $0.option.lineCodes.first == v.lineCode }) {
            select(owning.option)
        }
        trackedVehicleDoorNo = door
    }

    // MARK: the trip

    /// Press Start on a bus and ROVA follows that one vehicle, and nothing
    /// else, until you reach your destination.
    @Published private(set) var tripDoorNo: String?

    enum TripPhase: Equatable {
        case waiting        // the bus has not reached your stop yet
        case riding         // it is past your stop, so you are on it
        case arrived
    }

    func startTrip(_ door: String) {
        tripDoorNo = door
        trackedVehicleDoorNo = door
        onBoardDoorNo = nil
        refreshMotion()
        Haptic.success()
    }

    func endTrip() {
        tripDoorNo = nil
        onBoardDoorNo = nil
        refreshMotion()
    }

    func board(_ door: String) {
        onBoardDoorNo = door
        trackedVehicleDoorNo = door
        refreshMotion()
    }

    func getOff() {
        onBoardDoorNo = nil
        refreshMotion()
    }

    /// The leg after the one being followed, when there is one. İETT's fleet
    /// service returns no vehicles at all for the Metrobüs lines — checked
    /// again on 2026-11-12, lines 34 and 34A both answer with zero positions —
    /// so a journey that continues onto it has a timetable and nothing more.
    /// Saying that is better than a screen that looks broken.
    var legAfterFollowed: (line: String, hasLiveData: Bool, board: String)? {
        guard tripDoorNo != nil || onBoardDoorNo != nil,
              let option = focusedJourney?.option, option.busLegs.count > 1,
              let next = option.busLegs.dropFirst().first,
              let line = next.lineCode else { return nil }
        let reporting = !(vehicles[line] ?? []).isEmpty
        return (line, reporting, next.boardStop?.name ?? "the transfer stop")
    }

    /// Seconds since the followed bus last published a position, when that is
    /// long enough to be worth saying out loud.
    var followedBusSilentFor: TimeInterval? {
        guard let d = tripDoorNo ?? onBoardDoorNo, let v = vehicle(doorNo: d) else { return nil }
        return v.fixAge > 240 ? v.fixAge : nil
    }

    /// Where the followed bus is in the journey. Derived from its own position
    /// against your boarding stop, so it advances by itself — no button to
    /// forget to press.
    var tripPhase: TripPhase {
        guard let door = tripDoorNo, let ctx = routeContext,
              let v = vehicle(doorNo: door),
              let snap = Geo.snap(v.coordinate, to: ctx.shape) else { return .waiting }
        if onBoardDoorNo == door { return .riding }
        guard let leg = focusedJourney?.option.busLegs.first,
              let alight = leg.alightStop else { return .waiting }
        let stops = store.patternStops(ctx.patternId)
        let cum = Geo.cumulative(ctx.shape)
        if let ai = stops.firstIndex(where: { $0.stopCode == alight.code }),
           ai < cum.count, snap.along >= cum[ai] - 30 { return .arrived }
        // 40 m of slack: a bus sitting at the stop should already read as
        // boarded rather than still approaching.
        return snap.along >= ctx.boardAlong - 40 ? .riding : .waiting
    }

    /// The stops a journey calls at, board → alight, with predicted times from
    /// the best vehicle currently running it. With no vehicle reporting, the
    /// times come from the timetable and are marked as such by the caller.
    func previewStops(for option: JourneyOption) -> [TripStop] {
        guard let leg = option.busLegs.first, let pid = leg.patternId,
              let board = leg.boardStop, let alight = leg.alightStop,
              let pat = store.patterns[pid] else { return [] }
        let ps = store.patternStops(pid)
        guard let bi = ps.firstIndex(where: { $0.stopCode == board.code }),
              let ai = ps.firstIndex(where: { $0.stopCode == alight.code }), ai > bi else { return [] }

        let live = live[option.id]
        let door = (live?.eta ?? live?.alternatives.first)?.vehicleDoorNo
        let v = door.flatMap { vehicle(doorNo: $0) }

        // Timetable baseline: the run time between stops, which exists whether
        // or not a bus is reporting right now.
        let base = Date()
        var out: [TripStop] = []
        var previous: Date?
        for i in bi...ai {
            guard let st = store.stop(ps[i].stopCode) else { continue }
            let when: Date?
            if let v {
                when = eta.estimate(vehicle: v, pattern: pat, stopIndex: i,
                                    history: histories[v.doorNo])
                    .map { base.addingTimeInterval($0.predictedMinutes * 60) }
            } else if let first = cachedDeparture(for: leg) {
                when = first.addingTimeInterval(Double(ps[i].offsetSec - ps[bi].offsetSec))
            } else {
                when = nil
            }
            let gap = (when != nil && previous != nil)
                ? Int(when!.timeIntervalSince(previous!).rounded()) : nil
            if when != nil { previous = when }
            out.append(TripStop(code: st.code, name: st.name, index: i,
                                lat: st.lat, lon: st.lon, eta: when,
                                passed: false, isBoard: i == bi, isAlight: i == ai,
                                secondsFromPrevious: gap))
        }
        return out
    }

    /// The vehicle Start would follow for this journey, if one is reporting.
    func startableVehicle(for option: JourneyOption) -> String? {
        let l = live[option.id]
        return (l?.eta ?? l?.alternatives.first)?.vehicleDoorNo
    }

    /// The stops this bus calls at, from where it is now to where you get off.
    func tripStops() -> [TripStop] {
        guard let door = tripDoorNo, let ctx = routeContext,
              let v = vehicle(doorNo: door),
              let leg = focusedJourney?.option.busLegs.first,
              let board = leg.boardStop, let alight = leg.alightStop,
              let pat = store.patterns[ctx.patternId],
              let snap = Geo.snap(v.coordinate, to: ctx.shape) else { return [] }

        let ps = store.patternStops(ctx.patternId)
        guard let bi = ps.firstIndex(where: { $0.stopCode == board.code }),
              let ai = ps.firstIndex(where: { $0.stopCode == alight.code }),
              ai > bi else { return [] }

        // Show a little of the road already behind the bus, so you can see
        // where it is coming from, then everything up to your stop.
        let vehicleIndex = snap.segment + (snap.t >= 0.999 ? 1 : 0)
        let from = max(0, min(vehicleIndex - 1, bi))
        var out: [TripStop] = []
        var previousETA: Date?
        for i in from...ai {
            guard let st = store.stop(ps[i].stopCode) else { continue }
            let predicted = eta.estimate(vehicle: v, pattern: pat, stopIndex: i,
                                         history: histories[door])
                .map { Date().addingTimeInterval($0.predictedMinutes * 60) }
            let gap = (predicted != nil && previousETA != nil)
                ? Int(predicted!.timeIntervalSince(previousETA!).rounded()) : nil
            if predicted != nil { previousETA = predicted }
            out.append(TripStop(
                code: st.code, name: st.name, index: i,
                lat: st.lat, lon: st.lon,
                eta: predicted,
                passed: i < vehicleIndex,
                isBoard: i == bi, isAlight: i == ai,
                secondsFromPrevious: gap))
        }
        return out
    }

    private var onBoardLeg: JourneyLeg? {
        guard onBoardDoorNo != nil else { return nil }
        return focusedJourney?.option.busLegs.first
    }

    /// When you get off, and how many stops are left — the only two numbers
    /// that matter once you are aboard.
    var onBoardETA: ETA? {
        guard let door = onBoardDoorNo, let v = vehicle(doorNo: door),
              let leg = onBoardLeg, let pid = leg.patternId,
              let alight = leg.alightStop, let pat = store.patterns[pid] else { return nil }
        let stops = store.patternStops(pid)
        guard let idx = stops.firstIndex(where: { $0.stopCode == alight.code }) else { return nil }
        return eta.estimate(vehicle: v, pattern: pat, stopIndex: idx, history: histories[door])
    }

    /// The stretch of route still ahead of the bus you are on.
    var rideAheadShape: [CLLocationCoordinate2D] {
        guard let door = onBoardDoorNo, let ctx = routeContext,
              let leg = onBoardLeg, let alight = leg.alightStop else { return [] }
        let stops = store.patternStops(ctx.patternId)
        guard let idx = stops.firstIndex(where: { $0.stopCode == alight.code }) else { return [] }
        let cum = Geo.cumulative(ctx.shape)
        guard idx < cum.count else { return [] }
        let from = motion.display(doorNo: door).flatMap {
            Geo.snap($0.coordinate, to: ctx.shape)?.along
        } ?? vehicle(doorNo: door).flatMap { Geo.snap($0.coordinate, to: ctx.shape)?.along }
        guard let start = from, start < cum[idx] else { return [] }
        return Geo.slice(ctx.shape, cumulative: cum, from: start, to: cum[idx])
    }

    /// The next stop the given vehicle will call at on the watched route.
    func nextStopName(forVehicle door: String) -> String? {
        guard let ctx = routeContext,
              let v = vehicle(doorNo: door),
              let snap = Geo.snap(v.coordinate, to: ctx.shape) else { return nil }
        let stops = store.patternStops(ctx.patternId)
        let idx = min(snap.segment + 1, stops.count - 1)
        return store.stop(stops[idx].stopCode)?.name
    }

    /// How many stops the vehicle still has before the user's boarding stop.
    func stopsAway(forVehicle door: String) -> Int? {
        guard let j = focusedJourney else { return nil }
        let etas = ([j.nearestETA].compactMap { $0 } + j.alternatives)
        return etas.first { $0.vehicleDoorNo == door }?.stopsAway
    }

    /// The live ETA attached to a specific vehicle, if it has one.
    func eta(forVehicle door: String) -> ETA? {
        guard let j = focusedJourney else { return nil }
        return ([j.nearestETA].compactMap { $0 } + j.alternatives)
            .first { $0.vehicleDoorNo == door }
    }

    // MARK: scheduled fallback

    /// Next scheduled departures for a leg when no vehicle is reporting.
    func scheduledDepartures(for leg: JourneyLeg, limit: Int = 3) -> [Date] {
        guard let pid = leg.patternId, let board = leg.boardStop else { return [] }
        let ps = store.patternStops(pid)
        guard let idx = ps.firstIndex(where: { $0.stopCode == board.code }) else { return [] }
        let offset = ps[idx].offsetSec
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        let now = Date()
        let midnight = cal.startOfDay(for: now)
        let services = store.activeServices(on: now)
        let starts = store.departures(pattern: pid, services: services)
        let nowSec = Int(now.timeIntervalSince(midnight))
        return starts.map { $0 + offset }
            .filter { $0 >= nowSec - 60 }
            .prefix(limit)
            .map { midnight.addingTimeInterval(TimeInterval($0)) }
    }
}
