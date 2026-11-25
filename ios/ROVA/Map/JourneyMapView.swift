import SwiftUI
import MapKit

struct JourneyMapView: View {
    @EnvironmentObject var engine: JourneyEngine
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var location: LocationService
    @StateObject private var walks = WalkRouteCache()
    private let store = TransitStore.shared
    /// Geometry captured at the moment Start was pressed, so the drawn route
    /// stays put for the whole trip.
    @State private var frozenShapes: [String: [CLLocationCoordinate2D]] = [:]
    @EnvironmentObject var motion: VehicleAnimator

    @Binding var camera: MapCameraPosition
    /// Reports the visible region so the caller can follow a vehicle without
    /// overriding the zoom the user has chosen.
    var onCameraChange: ((CLLocationCoordinate2D, MKCoordinateSpan) -> Void)? = nil
    /// True while the user is manipulating the map; following pauses then.
    var onInteractionChange: ((Bool) -> Void)? = nil
    var onTapMap: (CLLocationCoordinate2D) -> Void

    private var journey: LiveJourney? { engine.focusedJourney }

    var body: some View {
        MapReader { proxy in
            Map(position: $camera, interactionModes: .all) {
                UserAnnotation()

                if let j = journey {
                    routeContent(j)
                }

                // Riding it: the road still ahead of you, ending where you
                // get off. This is the question once you are on board.
                if engine.onBoardDoorNo != nil {
                    let ahead = engine.rideAheadEndpoints().map {
                        Geo.sliceBetween(drawnRouteForFocusedLeg, from: $0.0, to: $0.1)
                    } ?? []
                    if ahead.count >= 2 {
                        MapPolyline(coordinates: ahead)
                            .stroke(RV.Color.live.opacity(0.28),
                                    style: .init(lineWidth: 14, lineCap: .round, lineJoin: .round))
                        MapPolyline(coordinates: ahead)
                            .stroke(RV.Color.live,
                                    style: .init(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    }
                }

                // The bus you tapped: the stretch it still has to cover to
                // reach you, so the route to your destination is one line you
                // can follow with a finger.
                if let door = engine.trackedVehicleDoorNo, engine.onBoardDoorNo == nil {
                    let approach = engine.approachEndpoints(forVehicle: door).map {
                        Geo.sliceBetween(drawnRouteForFocusedLeg, from: $0.0, to: $0.1)
                    } ?? []
                    if approach.count >= 2 {
                        MapPolyline(coordinates: approach)
                            .stroke(RV.Color.live.opacity(0.30),
                                    style: .init(lineWidth: 13, lineCap: .round, lineJoin: .round))
                        MapPolyline(coordinates: approach)
                            .stroke(RV.Color.live,
                                    style: .init(lineWidth: 5, lineCap: .round, lineJoin: .round,
                                                 dash: [14, 9]))
                    }
                }

                ForEach(shownVehicles) { d in
                    Annotation("", coordinate: onBoardCoordinate(d), anchor: .center) {
                        VehicleMarker(display: d,
                                      tracked: d.doorNo == engine.trackedVehicleDoorNo)
                            .onTapGesture {
                                Haptic.select()
                                if engine.trackedVehicleDoorNo == d.doorNo {
                                    engine.trackedVehicleDoorNo = nil
                                } else {
                                    engine.selectVehicle(d.doorNo)
                                }
                            }
                    }
                    .annotationTitles(.hidden)
                }

                if engine.tripDoorNo != nil {
                    ForEach(engine.tripStops()) { st in
                        Annotation("", coordinate: st.coordinate, anchor: .center) {
                            TripStopMarker(stop: st)
                        }
                        .annotationTitles(.hidden)
                    }
                }

                Annotation("", coordinate: settings.home.coordinate, anchor: .bottom) {
                    EndpointMarker(symbol: "house.fill", tint: RV.Color.ink, label: settings.home.name)
                }
                Annotation("", coordinate: settings.destination.coordinate, anchor: .bottom) {
                    EndpointMarker(symbol: "flag.checkered", tint: RV.Color.accent,
                                   label: settings.destination.name)
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll, showsTraffic: false))
            .mapControls { MapCompass(); MapScaleView() }
            .onTapGesture { pt in
                if let c = proxy.convert(pt, from: .local) { onTapMap(c) }
            }
            .onMapCameraChange(frequency: .continuous) { ctx in
                onCameraChange?(ctx.region.center, ctx.region.span)
            }
            // While a finger is on the map, nothing moves it but the finger.
            .simultaneousGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in onInteractionChange?(true) }
                    .onEnded { _ in onInteractionChange?(false) })
        }
        .onChange(of: journey?.option.id) { _, _ in requestWalks() }
        .onChange(of: engine.tripDoorNo) { _, trip in
            guard trip != nil else { frozenShapes = [:]; return }
            var frozen: [String: [CLLocationCoordinate2D]] = [:]
            for leg in journey?.option.busLegs ?? [] {
                guard let pid = leg.patternId else { continue }
                frozen[pid] = store.realShape(pid) ?? leg.shape
            }
            frozenShapes = frozen
        }
        .onAppear { requestWalks() }
    }

    /// Once a trip is running the map is about one bus, so the rest go away.
    private var shownVehicles: [VehicleDisplay] {
        guard let trip = engine.tripDoorNo else { return motion.displays }
        return motion.displays.filter { $0.doorNo == trip }
    }

    /// The route İETT publishes for this pattern.
    ///
    /// This used to ask Apple Maps for driving directions between consecutive
    /// stops and stitch them together, because the project believed no
    /// published geometry existed. It does: it is on İstanbul's open data
    /// portal, it covers 2 868 of our 2 876 patterns, and it is now in the
    /// bundled database. The drawn line is the bus's real alignment, resolved
    /// instantly and completely, so it cannot arrive half-built or break in
    /// the middle the way a stitched car route did.
    ///
    /// Timing is untouched: it still comes from the stop sequence and the
    /// schedule. This changes only what is drawn.
    private func busShape(_ leg: JourneyLeg) -> [CLLocationCoordinate2D] {
        guard let pid = leg.patternId, leg.shape.count >= 2 else { return leg.shape }
        if let real = store.realShape(pid) { return real }
        // No published alignment for this pattern (eight of them are İETT
        // free-text notes stored in the code column). Fall back to the stop
        // sequence, which is honest about being a skeleton, rather than to a
        // car route pretending to be a bus.
        if engine.tripDoorNo != nil, let frozen = frozenShapes[pid] { return frozen }
        return leg.shape
    }

    /// The ride split at the bus: behind it, and ahead of it.
    private func travelledAndRemaining(_ leg: JourneyLeg)
        -> (travelled: [CLLocationCoordinate2D], remaining: [CLLocationCoordinate2D])? {
        guard let p = engine.tripProgress, let pid = leg.patternId else { return nil }
        let shape = store.realShape(pid) ?? leg.shape
        guard shape.count >= 2 else { return nil }
        let cum = Geo.cumulative(shape)
        guard let total = cum.last, total > 1 else { return nil }
        let here = min(max(0, p.metresAlong), total)
        let travelled = Geo.slice(shape, cumulative: cum, from: 0, to: here)
        let remaining = Geo.slice(shape, cumulative: cum, from: here, to: total)
        guard remaining.count >= 2 else { return nil }
        return (travelled, remaining)
    }

    private var drawnRouteForFocusedLeg: [CLLocationCoordinate2D] {
        guard let leg = journey?.option.busLegs.first else { return [] }
        return busShape(leg)
    }

    /// The bus you are riding is exactly where your phone is. İETT's fix for
    /// it can be a minute old and a few hundred metres behind; your own GPS is
    /// the better truth, and it is yours, so ROVA uses it while you are aboard.
    private func onBoardCoordinate(_ d: VehicleDisplay) -> CLLocationCoordinate2D {
        guard engine.onBoardDoorNo == d.doorNo, let me = location.current else { return d.coordinate }
        return me.coordinate
    }

    @MapContentBuilder
    private func routeContent(_ j: LiveJourney) -> some MapContent {
        ForEach(j.option.legs) { leg in
            if leg.kind == .bus, engine.tripDoorNo != nil,
               let split = travelledAndRemaining(leg) {
                // While a trip is running the route is drawn once, in two
                // colours: what you have already ridden, and what is still
                // ahead. The split point is the bus's measured position on
                // the road, so the boundary moves because the bus moved.
                MapPolyline(coordinates: split.remaining)
                    .stroke(RV.Color.accent.opacity(0.26),
                            style: .init(lineWidth: 12, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: split.remaining)
                    .stroke(RV.Color.accent,
                            style: .init(lineWidth: 6, lineCap: .round, lineJoin: .round))
                if split.travelled.count >= 2 {
                    MapPolyline(coordinates: split.travelled)
                        .stroke(RV.Color.inkFaint.opacity(0.55),
                                style: .init(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
            } else if leg.kind == .bus {
                let drawn = busShape(leg)
                // A solid line is a claim that a bus is coming along it. When
                // nothing on the line is reporting a position, the alignment
                // is still true — İETT publishes it, the bus does run that way
                // — but it is the timetable, not an arrival. It is drawn
                // dashed and muted so the map never shows a confident route
                // under the words "No live bus to follow".
                let live = engine.hasLiveVehicle(onLine: leg.lineCode ?? "")
                MapPolyline(coordinates: drawn)
                    .stroke(RV.Color.accent.opacity(live ? 0.28 : 0.10),
                            style: .init(lineWidth: 11, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: drawn)
                    .stroke(live ? RV.Color.accent : RV.Color.inkMuted,
                            style: .init(lineWidth: live ? 5 : 4, lineCap: .round,
                                         lineJoin: .round,
                                         dash: live ? [] : [10, 9]))
            } else if leg.shape.count >= 2 {
                MapPolyline(coordinates: walks.path(leg.shape[0], leg.shape[1]) ?? leg.shape)
                    .stroke(RV.Color.inkMuted,
                            style: .init(lineWidth: 4, lineCap: .round, dash: [1, 8]))
            }
        }
        // You, on the route. Not a bus marker somewhere near the road, but a
        // point on the line itself, between the stop you have left and the
        // one you are coming to.
        if let p = engine.tripProgress {
            Annotation("", coordinate: p.coordinate, anchor: .center) {
                TripProgressDot()
            }
            .annotationTitles(.hidden)
        }
        ForEach(j.option.busLegs) { leg in
            if let b = leg.boardStop {
                Annotation("", coordinate: b.coordinate, anchor: .center) {
                    StopMarker(kind: .board, line: leg.lineCode ?? "")
                }
                .annotationTitles(.hidden)
            }
            if let a = leg.alightStop {
                Annotation("", coordinate: a.coordinate, anchor: .center) {
                    StopMarker(kind: .alight, line: leg.lineCode ?? "")
                }
                .annotationTitles(.hidden)
            }
        }
    }

    private func requestWalks() {
        guard let j = journey else { return }
        for leg in j.option.legs where leg.kind == .walk && leg.shape.count >= 2 {
            walks.request(leg.shape[0], leg.shape[1])
        }
    }
}

// MARK: - Markers

/// A bus on the map: where it is, and which way it is pointing.
struct VehicleMarker: View {
    let display: VehicleDisplay
    var tracked: Bool

    private var state: DataState { .forFix(age: display.fixAge) }
    private var moving: Bool { (display.speedKmh ?? 0) > 3 }
    private var mode: TransitMode { .of(line: display.vehicle.lineCode) }

    var body: some View {
        ZStack {
            if tracked {
                Circle().fill(state.tint.opacity(0.16)).frame(width: 52, height: 52)
            }
            // Direction of travel, drawn outside the dot so it reads at a glance.
            Image(systemName: "arrowtriangle.up.fill")
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(state.tint)
                .offset(y: tracked ? -24 : -21)
                .rotationEffect(.degrees(display.bearing), anchor: .center)
                .opacity(moving ? 1 : 0.35)

            // The body carries the *mode*, so a Metrobüs is recognisable at a
            // glance. Freshness is the ring around it — two different facts,
            // two different channels, neither able to be mistaken for the
            // other. Colouring the body by freshness made every vehicle look
            // alike and hid which system you were actually looking at.
            Circle()
                .fill(mode.tint)
                .frame(width: tracked ? 32 : 27, height: tracked ? 32 : 27)
                .overlay(Circle().strokeBorder(state.tint, lineWidth: 3))
                .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
            Image(systemName: moving ? "bus.fill" : "bus")
                .font(.system(size: tracked ? 14 : 12, weight: .bold))
                .foregroundStyle(mode.tint == RV.Color.ink ? RV.Color.onInk : .white)
        }
        .frame(width: 56, height: 56)
        .contentShape(Circle())
        .animation(.easeInOut(duration: 0.25), value: tracked)
        .animation(.easeInOut(duration: 0.6), value: display.bearing)
    }
}

/// A stop on the bus you are following: named when it still matters, a dot
/// once it is behind you.
struct TripStopMarker: View {
    let stop: TripStop
    private var tint: Color {
        stop.isAlight ? RV.Color.live : (stop.isBoard ? RV.Color.accent : RV.Color.inkMuted)
    }
    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().fill(RV.Color.canvas).frame(width: stop.passed ? 8 : 13,
                                                     height: stop.passed ? 8 : 13)
                Circle().strokeBorder(stop.passed ? RV.Color.inkFaint : tint,
                                      lineWidth: stop.passed ? 2 : 3.5)
                    .frame(width: stop.passed ? 8 : 13, height: stop.passed ? 8 : 13)
            }
            if !stop.passed && (stop.isBoard || stop.isAlight) {
                Text(stop.name)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RV.Color.canvas.opacity(0.9), in: Capsule())
                    .fixedSize()
            }
        }
        .opacity(stop.passed ? 0.55 : 1)
    }
}

struct StopMarker: View {
    enum Kind { case board, alight }
    let kind: Kind
    let line: String
    var body: some View {
        ZStack {
            Circle().fill(RV.Color.canvas).frame(width: 18, height: 18)
            Circle().strokeBorder(kind == .board ? RV.Color.accent : RV.Color.ink, lineWidth: 4)
                .frame(width: 18, height: 18)
        }
        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
    }
}

struct EndpointMarker: View {
    let symbol: String
    let tint: Color
    let label: String
    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().fill(RV.Color.canvas)
                    .frame(width: 30, height: 30)
                    .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
                Image(systemName: symbol).font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tint)
            }
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RV.Color.canvas.opacity(0.88), in: Capsule())
                .fixedSize()
        }
    }
}
