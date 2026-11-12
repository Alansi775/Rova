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
    /// Set when the card is closed deliberately, so it is not pulled back.
    @State private var sheetClosedOnPurpose = false
    /// Live camera geometry, so the map can follow a bus without resetting
    /// the zoom the user chose.
    @State private var currentCentre: CLLocationCoordinate2D?
    @State private var currentSpan: MKCoordinateSpan?
    @State private var mapIsBeingDragged = false
    @State private var detent: PresentationDetent =
        ProcessInfo.processInfo.arguments.contains("-ROVAExpanded") ? .large : .height(260)
    @State private var editing: EndpointEdit?
    @State private var showSettings = false
    @State private var pendingPin: CLLocationCoordinate2D?

    enum EndpointEdit: Identifiable { case origin, destination
        var id: Int { self == .origin ? 0 : 1 } }

    var body: some View {
        ZStack(alignment: .top) {
            JourneyMapView(camera: $camera,
                           onCameraChange: { c, span in
                               currentCentre = c; currentSpan = span
                           },
                           onInteractionChange: { mapIsBeingDragged = $0 }) { coord in
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
                         },
                         onClose: {
                             sheetClosedOnPurpose = true
                             sheet = false
                         })
                .environmentObject(engine)
                .environmentObject(settings)
                .environmentObject(motion)
                .presentationDetents([.height(130), .height(260), .medium, .large], selection: $detent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(28)
                .interactiveDismissDisabled()
        }
        // Belt and braces: if the card is ever dismissed by anything at all,
        // it comes straight back. It is the app, not an optional extra.
        // The card comes back if something dismissed it by accident, but not
        // when it was closed on purpose: sometimes you only want the map.
        .onChange(of: sheet) { _, shown in
            if !shown && !sheetClosedOnPurpose {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    sheet = true
                }
            }
        }
        // The pin chooser is drawn on the map, not presented.
        //
        // It used to be a confirmationDialog on this same view. Presenting it
        // dismissed the journey sheet, the auto-restore then brought the
        // sheet back 350 ms later, and the dialog vanished with it — which is
        // why the two buttons flashed for under a second and the card below
        // jumped away and returned. Two presentations from one view fight;
        // this one does not need to be a presentation at all.
        .overlay(alignment: .center) { pinChooser }
        // Closing the card must never be a one-way door.
        .overlay(alignment: .bottom) {
            if !sheet {
                Button {
                    Haptic.tap()
                    sheetClosedOnPurpose = false
                    sheet = true
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 11, weight: .bold))
                        Text(engine.journeys.isEmpty ? "Plan a journey" : "Show journey")
                            .font(.rvCallout)
                    }
                    .foregroundStyle(RV.Color.ink)
                    .padding(.horizontal, RV.Space.l)
                    .padding(.vertical, RV.Space.m)
                    .glassEffect(.regular, in: .capsule)
                }
                .buttonStyle(.plain)
                .padding(.bottom, RV.Space.xl)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
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
        .task { MetroNetwork.shared.load() }
        .onChange(of: engine.selected?.id) { _, _ in frameJourney() }
        .onChange(of: motion.displays) { _, _ in followTrackedVehicle() }
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
        case .height(130): return 130
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
    /// Put the chosen bus in the middle of the screen.
    ///
    /// It used to frame the bus *and* the boarding stop, which pushed the bus
    /// off to one side and zoomed out until it was a dot. The point of
    /// tapping a bus is to look at the bus.
    private func frameVehicle(_ door: String, animated: Bool = true) {
        guard let d = motion.display(doorNo: door) else { return }
        let span = currentSpan ?? MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)
        let r = MKCoordinateRegion(center: d.coordinate, span: span)
        if animated {
            withAnimation(.easeInOut(duration: 0.55)) { camera = .region(r) }
        } else {
            camera = .region(r)
        }
    }

    /// Keep a tracked bus centred as it moves, without fighting the user.
    ///
    /// Recentring is skipped while the map is being dragged, and only happens
    /// once the marker has drifted meaningfully from the middle — otherwise
    /// the map twitches on every animation frame.
    private func followTrackedVehicle() {
        guard let door = engine.trackedVehicleDoorNo, !mapIsBeingDragged,
              let d = motion.display(doorNo: door),
              let centre = currentCentre, let span = currentSpan else { return }
        // A tenth of the visible height is enough drift to re-centre on.
        let slack = span.latitudeDelta * 0.18
        if abs(d.coordinate.latitude - centre.latitude) > slack
            || abs(d.coordinate.longitude - centre.longitude) > span.longitudeDelta * 0.18 {
            withAnimation(.easeInOut(duration: 0.8)) {
                camera = .region(MKCoordinateRegion(center: d.coordinate, span: span))
            }
        }
    }

    /// The map-tap chooser, drawn in place.
    @ViewBuilder
    private var pinChooser: some View {
        if pendingPin != nil {
            VStack(spacing: RV.Space.s) {
                Text("Use this point as").rvOverlineStyle()
                Button("Starting point") { setPin(asOrigin: true) }
                    .buttonStyle(.rvProminent)
                Button("Destination") { setPin(asOrigin: false) }
                    .buttonStyle(.rvSecondary)
                Button("Cancel") { pendingPin = nil }
                    .font(.rvCallout).foregroundStyle(RV.Color.inkMuted)
                    .padding(.top, 2)
            }
            .padding(RV.Space.l)
            .frame(maxWidth: 280)
            .glassEffect(.regular, in: .rect(cornerRadius: RV.Radius.l, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
            .transition(.scale(scale: 0.94).combined(with: .opacity))
        }
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
