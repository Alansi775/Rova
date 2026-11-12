import SwiftUI
import MapKit

struct RootView: View {
    @EnvironmentObject var engine: JourneyEngine
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var location: LocationService
    @EnvironmentObject var motion: VehicleAnimator

    @State private var camera: MapCameraPosition = .region(
        MKCoordinateRegion(center: .init(latitude: 41.0, longitude: 28.70),
                           span: .init(latitudeDelta: 0.09, longitudeDelta: 0.09)))
    @State private var sheet = true
    @State private var detent: PresentationDetent =
        ProcessInfo.processInfo.arguments.contains("-ROVAExpanded") ? .large : .height(260)
    @State private var editing: EndpointEdit?
    @State private var showSettings = false
    @State private var pendingPin: CLLocationCoordinate2D?

    enum EndpointEdit: Identifiable { case origin, destination
        var id: Int { self == .origin ? 0 : 1 } }

    var body: some View {
        ZStack(alignment: .top) {
            JourneyMapView(camera: $camera) { coord in
                // A tap while a bus is open just closes it — dropping a pin is
                // the second tap, never a surprise.
                if engine.trackedVehicleDoorNo != nil {
                    engine.trackedVehicleDoorNo = nil
                } else {
                    pendingPin = coord
                }
                Haptic.tap()
            }
            .ignoresSafeArea()

            VStack(spacing: RV.Space.m) {
                TopBar(origin: settings.home.name,
                       destination: settings.destination.name,
                       onEditOrigin: { editing = .origin },
                       onEditDestination: { editing = .destination },
                       onSwap: swap,
                       onSettings: { showSettings = true })

                if let door = engine.trackedVehicleDoorNo,
                   let d = motion.display(doorNo: door) {
                    VehicleCallout(display: d) { engine.trackedVehicleDoorNo = nil }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.horizontal, RV.Space.l)
            .animation(.spring(response: 0.38, dampingFraction: 0.86),
                       value: engine.trackedVehicleDoorNo)

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    MapButtons(onRecenter: recenterOnUser, onFrame: frameJourney)
                        .padding(.trailing, RV.Space.l)
                        .padding(.bottom, detentHeight + 16)
                }
            }
            .ignoresSafeArea(.keyboard)
        }
        // One sheet, and only one, is presented from this view. Search and
        // settings are presented *by* the journey sheet instead: two `.sheet`
        // modifiers on the same view fight each other, which is what made the
        // journey card disappear for good after a search.
        .sheet(isPresented: $sheet) {
            JourneySheet(detent: $detent, onFrame: frameJourney,
                         editing: $editing, showSettings: $showSettings,
                         onPlaceChosen: { which, place in
                             if which == .origin { settings.home = place }
                             else { settings.destination = place }
                             Haptic.success()
                             replan()
                         })
                .environmentObject(engine)
                .environmentObject(settings)
                .environmentObject(motion)
                .presentationDetents([.height(260), .medium, .large], selection: $detent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
                .interactiveDismissDisabled()
        }
        // Belt and braces: if the card is ever dismissed by anything at all,
        // it comes straight back. It is the app, not an optional extra.
        .onChange(of: sheet) { _, shown in
            if !shown {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    sheet = true
                }
            }
        }
        .confirmationDialog("Use this location",
                            isPresented: Binding(get: { pendingPin != nil },
                                                 set: { if !$0 { pendingPin = nil } })) {
            Button("Set as destination") { setPin(asOrigin: false) }
            Button("Set as starting point") { setPin(asOrigin: true) }
            Button("Cancel", role: .cancel) { pendingPin = nil }
        }
        .task {
            if !ProcessInfo.processInfo.arguments.contains("-ROVAUITest") {
                location.request()
                NotificationCenterService.shared.requestAuthorization()
            }
            await engine.applyBackend(settings.effectiveBackend)
            adoptCurrentLocation()
            replan()
            engine.startLiveUpdates()
            frameJourney()
            // Development inspection only: opens the first bus card so the map
            // UI can be screenshotted without a tap. Never set in a real run.
            if ProcessInfo.processInfo.arguments.contains("-ROVASelectFirstVehicle") {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                engine.trackedVehicleDoorNo = motion.displays.first?.doorNo
                if ProcessInfo.processInfo.arguments.contains("-ROVAStartTrip"),
                   let d = motion.displays.first?.doorNo {
                    engine.startTrip(d)
                }
            }
        }
        .onDisappear { engine.stopLiveUpdates() }
        .onChange(of: engine.selected?.id) { _, _ in frameJourney() }
        // Tap a bus — in the list below or on the map — and the map goes to
        // it. Selecting a vehicle used to change only which callout was
        // shown, so choosing a bus you could not already see told you
        // nothing about where it was.
        .onChange(of: engine.trackedVehicleDoorNo) { _, door in
            guard let door else { return }
            frameVehicle(door)
        }
        .onChange(of: location.current?.coordinate.latitude) { _, _ in adoptCurrentLocation() }
        .onChange(of: settings.backendURL) { _, _ in engine.applyBackendLater(settings.effectiveBackend) }
        .onChange(of: settings.backendToken) { _, _ in engine.applyBackendLater(settings.effectiveBackend) }
        .onChange(of: settings.useBackend) { _, _ in engine.applyBackendLater(settings.effectiveBackend) }
        .onChange(of: engine.selectedJourney?.eta?.predictedMinutes) { _, _ in
            if let j = engine.focusedJourney {
                NotificationCenterService.shared.schedule(
                    for: j, leadMinutes: settings.notifyBeforeMinutes)
            }
        }
    }

    private var detentHeight: CGFloat {
        switch detent {
        case .height(260): return 260
        default: return 260
        }
    }

    /// The journey starts where you are standing. ROVA only moves the start
    /// point when you have actually moved somewhere else — more than 150 m —
    /// so it never quietly re-plans under you while you wait at a stop.
    private func adoptCurrentLocation() {
        guard settings.followMyLocation, engine.tripDoorNo == nil,
              let here = location.current?.coordinate else { return }
        if Geo.metres(here, settings.home.coordinate) < 150 { return }
        Task {
            let n = await Reverse.describe(here)
            guard settings.followMyLocation, engine.tripDoorNo == nil else { return }
            settings.home = Place(name: n.0 == "Dropped pin" ? "My location" : n.0,
                                  subtitle: n.1, lat: here.latitude, lon: here.longitude)
            replan()
        }
    }

    private func replan() {
        Task { await engine.plan(from: settings.home.coordinate, to: settings.destination.coordinate) }
    }

    private func swap() {
        let a = settings.home
        settings.home = settings.destination
        settings.destination = a
        Haptic.tap()
        replan()
    }

    private func setPin(asOrigin: Bool) {
        guard let c = pendingPin else { return }
        pendingPin = nil
        Task {
            let name = await Reverse.describe(c)
            let p = Place(name: name.0, subtitle: name.1, lat: c.latitude, lon: c.longitude)
            if asOrigin { settings.home = p } else { settings.destination = p }
            Haptic.success()
            replan()
        }
    }

    private func recenterOnUser() {
        Haptic.tap()
        guard let l = location.current else { location.request(); return }
        withAnimation(.easeInOut(duration: 0.6)) {
            camera = .region(MKCoordinateRegion(center: l.coordinate,
                                                span: .init(latitudeDelta: 0.008, longitudeDelta: 0.008)))
        }
    }

    /// Centre on one vehicle, close enough to read the street it is on.
    ///
    /// The boarding stop is included when it is nearby, because "where is the
    /// bus" and "where am I getting on" are the same question while waiting.
    /// It is dropped when it is far, rather than zooming out until the bus is
    /// a dot — the point of tapping a bus is to see the bus.
    private func frameVehicle(_ door: String) {
        guard let d = motion.display(doorNo: door) else { return }
        var pts = [d.coordinate]
        if let board = engine.focusedJourney?.option.busLegs.first?.boardStop?.coordinate,
           Geo.metres(board, d.coordinate) < 2500 {
            pts.append(board)
        }
        guard var r = region(fitting: pts) else { return }
        // Never zoom out past a readable street level for a single vehicle.
        r.span.latitudeDelta = max(r.span.latitudeDelta, 0.004)
        r.span.longitudeDelta = max(r.span.longitudeDelta, 0.004)
        withAnimation(.easeInOut(duration: 0.55)) { camera = .region(r) }
    }

    private func frameJourney() {
        var pts: [CLLocationCoordinate2D] = [settings.home.coordinate, settings.destination.coordinate]
        if let j = engine.focusedJourney {
            pts += j.option.legs.flatMap(\.shape)
            pts += engine.mapVehicles.map(\.coordinate)
        }
        guard let r = region(fitting: pts) else { return }
        withAnimation(.easeInOut(duration: 0.65)) { camera = .region(r) }
    }

    private func region(fitting pts: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard !pts.isEmpty else { return nil }
        let lats = pts.map(\.latitude), lons = pts.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!
        return MKCoordinateRegion(
            center: .init(latitude: (minLat + maxLat)/2, longitude: (minLon + maxLon)/2),
            span: .init(latitudeDelta: max(0.006, (maxLat - minLat) * 2.1),
                        longitudeDelta: max(0.006, (maxLon - minLon) * 1.35)))
    }
}

// MARK: - Top bar

struct TopBar: View {
    let origin: String
    let destination: String
    var onEditOrigin: () -> Void
    var onEditDestination: () -> Void
    var onSwap: () -> Void
    var onSettings: () -> Void

    var body: some View {
        HStack(spacing: RV.Space.m) {
            VStack(spacing: 0) {
                row(dot: AnyView(Circle().strokeBorder(RV.Color.inkMuted, lineWidth: 2.5).frame(width: 10, height: 10)),
                    text: origin, action: onEditOrigin)
                HStack(spacing: RV.Space.m) {
                    VStack(spacing: 2) {
                        ForEach(0..<3, id: \.self) { _ in
                            Circle().fill(RV.Color.inkFaint).frame(width: 2, height: 2)
                        }
                    }
                    .frame(width: 10)
                    Divider().opacity(0)
                }
                .frame(height: 12)
                row(dot: AnyView(RoundedRectangle(cornerRadius: 2).fill(RV.Color.accent).frame(width: 10, height: 10)),
                    text: destination, action: onEditDestination)
            }
            .padding(.vertical, RV.Space.m)

            // These two used to sit flush against the top and bottom of the
            // card: the left column carried vertical padding and this one did
            // not, so the glass circles touched the card's own edge and the
            // whole control looked cramped. They now breathe, and they are
            // 36pt — a comfortable tap target rather than a tight one.
            VStack(spacing: RV.Space.m) {
                circleButton("arrow.up.arrow.down", "Swap origin and destination", onSwap)
                circleButton("slider.horizontal.3", "Settings", onSettings)
            }
            .padding(.vertical, RV.Space.m)
            .padding(.trailing, RV.Space.m)
        }
        .padding(.leading, RV.Space.l)
        .glassEffect(.regular, in: .rect(cornerRadius: RV.Radius.l, style: .continuous))
    }

    private func circleButton(_ icon: String, _ label: String,
                              _ action: @escaping () -> Void) -> some View {
        Button(action: { Haptic.tap(); action() }) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(RV.Color.inkMuted)
                .frame(width: 36, height: 36)
                .glassEffect(.regular, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func row(dot: AnyView, text: String, action: @escaping () -> Void) -> some View {
        Button(action: { Haptic.tap(); action() }) {
            HStack(spacing: RV.Space.m) {
                dot.frame(width: 10)
                Text(text).font(.rvHeadline).foregroundStyle(RV.Color.ink)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                // Says, without a word of instruction, that this is a field
                // you can type a place into.
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RV.Color.inkFaint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct MapButtons: View {
    var onRecenter: () -> Void
    var onFrame: () -> Void
    var body: some View {
        VStack(spacing: 1) {
            button("location.fill", onRecenter)
            Divider().frame(width: 40)
            button("arrow.down.left.and.arrow.up.right", onFrame)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
    }
    private func button(_ s: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Image(systemName: s).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(RV.Color.accent)
                .frame(width: 44, height: 44)
        }
    }
}

enum Reverse {
    static func describe(_ c: CLLocationCoordinate2D) async -> (String, String) {
        let g = CLGeocoder()
        guard let p = try? await g.reverseGeocodeLocation(
            CLLocation(latitude: c.latitude, longitude: c.longitude)).first else {
            return ("Dropped pin", String(format: "%.5f, %.5f", c.latitude, c.longitude))
        }
        let name = p.name ?? p.thoroughfare ?? "Dropped pin"
        let sub = [p.subLocality, p.locality].compactMap { $0 }.joined(separator: ", ")
        return (name, sub.isEmpty ? "Istanbul" : sub)
    }
}
