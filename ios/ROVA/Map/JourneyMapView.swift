import SwiftUI
import MapKit

struct JourneyMapView: View {
    @EnvironmentObject var engine: JourneyEngine
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var location: LocationService
    @StateObject private var walks = WalkRouteCache()
    @StateObject private var roads = RoadShapes.shared
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
                frozen[pid] = roads.shape(pid, stops: leg.shape) ?? leg.shape
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

    /// Road geometry when Apple has given it to us, the stop sequence until
    /// then. Drawing changes; nothing about the timing does.
    private func busShape(_ leg: JourneyLeg) -> [CLLocationCoordinate2D] {
        guard let pid = leg.patternId, leg.shape.count >= 2 else { return leg.shape }
        // Once you have pressed Start the line under you does not change shape.
        // Road geometry that finishes resolving mid-journey is kept for next
        // time rather than redrawing the route while you are watching it.
        if engine.tripDoorNo != nil, let frozen = frozenShapes[pid] { return frozen }
        return roads.shape(pid, stops: leg.shape) ?? leg.shape
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
            if leg.kind == .bus {
                let drawn = busShape(leg)
                MapPolyline(coordinates: drawn)
                    .stroke(RV.Color.accent.opacity(0.28), style: .init(lineWidth: 11, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: drawn)
                    .stroke(RV.Color.accent, style: .init(lineWidth: 5, lineCap: .round, lineJoin: .round))
            } else if leg.shape.count >= 2 {
                MapPolyline(coordinates: walks.path(leg.shape[0], leg.shape[1]) ?? leg.shape)
                    .stroke(RV.Color.inkMuted,
                            style: .init(lineWidth: 4, lineCap: .round, dash: [1, 8]))
            }
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
