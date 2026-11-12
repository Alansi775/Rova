import SwiftUI

struct JourneySheet: View {
    @EnvironmentObject var engine: JourneyEngine
    @EnvironmentObject var settings: Settings
    @Binding var detent: PresentationDetent
    var onFrame: () -> Void
    /// Search and settings are presented from here, not from the map view, so
    /// that opening one never dismisses the journey card.
    @Binding var editing: RootView.EndpointEdit?
    @Binding var showSettings: Bool
    var onPlaceChosen: (RootView.EndpointEdit, Place) -> Void

    @State private var now = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var primary: LiveJourney? { engine.focusedJourney }

    @State private var preview: LiveJourney?

    var body: some View {
        NavigationStack {
            content
                .navigationDestination(item: $preview) { j in
                    RoutePreview(journey: j) {
                        if let d = engine.startableVehicle(for: j.option) {
                            engine.select(j.option)
                            engine.startTrip(d)
                            preview = nil
                            detent = .height(260)
                            onFrame()
                        }
                    }
                    .environmentObject(engine)
                }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: RV.Space.l) {
                if engine.isPlanning && engine.journeys.isEmpty {
                    SkeletonHero()
                } else if engine.journeys.isEmpty {
                    EmptyState()
                } else if engine.tripDoorNo != nil {
                    TripView(now: now, expanded: detent != .height(260))
                } else if engine.onBoardDoorNo != nil {
                    OnBoardCard(now: now)
                        .onTapGesture { expand() }
                    if detent != .height(260), let p = primary {
                        JourneyDetail(journey: p)
                    }
                } else if let p = primary {
                    HeroCard(journey: p, now: now, expanded: detent != .height(260))
                        .onTapGesture { Haptic.tap(); preview = p }
                    if detent != .height(260) {
                        JourneyDetail(journey: p)
                    }
                    OtherOptions(current: p) { j in
                        preview = j
                    }
                }
                FooterNote()
            }
            .padding(.horizontal, RV.Space.l)
            .padding(.top, RV.Space.s)
            .padding(.bottom, RV.Space.xxl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(RV.Color.canvas)
        .onReceive(clock) { now = $0 }
        .refreshable { await engine.refresh(force: true) }
        .sheet(item: $editing) { which in
            SearchView(title: which == .origin ? "Starting point" : "Destination") { place in
                let w = which
                editing = nil
                onPlaceChosen(w, place)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(engine) }
    }

    private func expand() {
        Haptic.tap()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            detent = detent == .height(260) ? .medium : .height(260)
        }
    }
}

// MARK: - Hero

struct HeroCard: View {
    @EnvironmentObject var engine: JourneyEngine
    let journey: LiveJourney
    let now: Date
    /// Collapsed, the card answers one question: when do I leave. The numbers
    /// behind that answer appear when the sheet is pulled up.
    var expanded: Bool = true

    private var leg: JourneyLeg? { journey.option.busLegs.first }
    private var state: DataState {
        if let e = journey.eta { return e.state }
        return .scheduledOnly
    }

    var body: some View {
        RVCard {
            VStack(alignment: .leading, spacing: RV.Space.l) {
                HStack(alignment: .firstTextBaseline, spacing: RV.Space.m) {
                    if let line = leg?.lineCode { LineBadge(code: line) }
                    Text(leg?.headsign ?? "")
                        .font(.rvCallout).foregroundStyle(RV.Color.inkMuted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    StatePill(state: state, compact: true)
                }

                if let eta = journey.eta {
                    arrival(eta)
                } else {
                    scheduledFallback()
                }

                if expanded {
                Divider().overlay(RV.Color.hairline)

                HStack(spacing: RV.Space.xl) {
                    MetricColumn(value: Fmt.duration(journey.totalSeconds), label: "Door to door",
                                 tint: journey.eta == nil ? RV.Color.inkMuted : RV.Color.ink)
                    MetricColumn(value: Fmt.duration(journey.option.walkSeconds), label: "Walk")
                    MetricColumn(value: Fmt.duration(journey.option.rideSeconds), label: "On bus")
                    MetricColumn(value: journey.option.transfers == 0 ? "Direct" : "\(journey.option.transfers)",
                                 label: journey.option.transfers == 0 ? "Service" : "Transfers")
                    Spacer(minLength: 0)
                }
                }
            }
        }
    }

    @ViewBuilder
    private func arrival(_ eta: ETA) -> some View {
        VStack(alignment: .leading, spacing: RV.Space.s) {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                // A stalled bus gets a dash, not a countdown. The number was
                // the lie: it sat at "2 min" for an hour while the bus never
                // moved, because a motionless vehicle matched the timetable
                // perfectly. The honest headline is that it is not coming yet.
                if eta.stalledSeconds != nil {
                    Text("—")
                        .font(.rvNumeral(52))
                        .foregroundStyle(RV.Color.inkMuted)
                } else {
                    Text(Fmt.minutesShort(eta.predictedMinutes))
                        .font(.rvNumeral(52))
                        .foregroundStyle(RV.Color.ink)
                        .contentTransition(.numericText())
                    if eta.predictedMinutes >= 0.75 {
                        Text("min").font(.rvHeadline).foregroundStyle(RV.Color.inkMuted)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(eta.rangeMinutes.lowerBound.rounded()))–\(Int(eta.rangeMinutes.upperBound.rounded())) min")
                        .font(.rvCallout).monospacedDigit()
                        .foregroundStyle(RV.Color.inkMuted)
                    Text(eta.confidence.label).rvOverlineStyle()
                        .foregroundStyle(eta.confidence.tint)
                }
            }

            if let stalled = eta.stalledSeconds {
                Text("This bus has not moved for \(Fmt.duration(Int(stalled))). "
                     + "It is still reporting, so it has not vanished — but no "
                     + "arrival time is worth giving you until it starts again.")
                    .font(.rvBody).foregroundStyle(RV.Color.ink)
            } else {
                Text("until the bus reaches \(leg?.boardStop?.name ?? "your stop")")
                    .font(.rvBody).foregroundStyle(RV.Color.inkMuted)
            }

            if expanded, let missed = journey.missedETA {
                Label("A \(missed.lineCode) is \(Int(missed.predictedMinutes.rounded())) min away — "
                      + "too soon for the \(Fmt.duration(journey.walkToStopSeconds)) walk.",
                      systemImage: "figure.walk.departure")
                    .font(.rvCaption).foregroundStyle(RV.Color.inkFaint)
            }
            // Never send someone down to the street on data that cannot carry
            // the instruction. "Leave now" is the single most consequential
            // sentence in the app — it puts a person on the pavement — so it
            // is spoken only from a fix that is fresh, from a bus that is
            // moving, and at a confidence above the floor. A 33-minute-old
            // fix with a 0–47 minute range used to say it anyway.
            if eta.stalledSeconds == nil, eta.confidence != .low,
               let leaveIn = journey.leaveInSeconds {
                LeaveBanner(seconds: leaveIn, window: journey.arrivalWindow,
                            walkIsMeasured: journey.walkIsMeasured)
            } else if eta.stalledSeconds == nil, journey.leaveInSeconds != nil {
                Label("Not certain enough to tell you when to leave.",
                      systemImage: "questionmark.circle")
                    .font(.rvCaption).foregroundStyle(RV.Color.inkMuted)
            }
            if let door = eta.vehicleDoorNo {
                StartButton(doorNo: door)
            }
            if expanded || eta.isUnreliable, let r = eta.lowConfidenceReason {
                Label(r, systemImage: "info.circle")
                    .font(.rvCaption).foregroundStyle(RV.Color.inkFaint)
            }
        }
    }

    @ViewBuilder
    private func scheduledFallback() -> some View {
        let next = leg.map { engine.scheduledDepartures(for: $0, limit: 1) } ?? []
        VStack(alignment: .leading, spacing: RV.Space.s) {
            if let d = next.first {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(Fmt.clock(d))
                        .font(.rvNumeral(46))
                        .foregroundStyle(RV.Color.ink)
                    Text(Fmt.duration(Int(d.timeIntervalSince(now))))
                        .font(.rvHeadline).foregroundStyle(RV.Color.inkMuted)
                    Spacer(minLength: 0)
                }
                Text("next scheduled departure from \(leg?.boardStop?.name ?? "your stop")")
                    .font(.rvBody).foregroundStyle(RV.Color.inkMuted)
            } else {
                Text("No more buses today")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(RV.Color.ink)
            }
            // Why there is no live bus, said here rather than in a footnote.
            //
            // The engine already knew it was being rate limited and could say
            // when positions would resume, but that sentence lived in a small
            // caption at the bottom of the sheet — usually below the fold. So
            // the screen showed an empty map and no reason, which reads as
            // the app being broken or making things up.
            if let problem = engine.liveProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.rvCallout)
                    .foregroundStyle(RV.Color.ink)
                    .padding(.horizontal, RV.Space.m)
                    .padding(.vertical, RV.Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RV.Color.warn.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: RV.Radius.s, style: .continuous))
            } else {
                Label("No vehicle is reporting a GPS position on this line yet — this is the timetable, not a confirmed arrival.",
                      systemImage: "info.circle")
                    .font(.rvCaption).foregroundStyle(RV.Color.inkFaint)
            }
        }
    }
}

struct LeaveBanner: View {
    let seconds: Int
    var window: ClosedRange<Date>?
    /// False when the walking time behind this advice is the planner's
    /// straight-line estimate rather than a measured pedestrian route.
    var walkIsMeasured: Bool = true
    // Urgency is weight, not colour: ink for "go now", amber for "soon",
    // green for "you have time". Nothing in ROVA is red.
    private var tint: Color { seconds < 45 ? RV.Color.ink : (seconds < 120 ? RV.Color.warn : RV.Color.live) }
    var body: some View {
        HStack(spacing: RV.Space.s) {
            Image(systemName: seconds <= 0 ? "figure.walk.motion" : "figure.walk")
                .font(.system(size: 13, weight: .bold))
            VStack(alignment: .leading, spacing: 1) {
                Text(seconds < 45 ? "Leave now to catch it"
                                  : "Leave in \(Fmt.duration(seconds))")
                    .font(.rvCallout)
                if let w = window {
                    // Said out loud, so the advice can be checked rather than
                    // just trusted.
                    Text("it can arrive \(Fmt.clock(w.lowerBound))–\(Fmt.clock(w.upperBound))")
                        .font(.system(size: 11, weight: .medium))
                        .opacity(0.8)
                }
                if !walkIsMeasured {
                    // The walk is the straight line, not the pavement. Say so:
                    // this advice is only as good as the number behind it.
                    Text("walking time estimated, not measured")
                        .font(.system(size: 11, weight: .medium))
                        .opacity(0.7)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, RV.Space.m).padding(.vertical, RV.Space.s)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: RV.Radius.s, style: .continuous))
    }
}

// MARK: - Detail

struct JourneyDetail: View {
    @EnvironmentObject var engine: JourneyEngine
    let journey: LiveJourney

    var body: some View {
        VStack(spacing: RV.Space.l) {
            if let eta = journey.eta, let door = eta.vehicleDoorNo,
               let v = engine.vehicle(doorNo: door) {
                VehicleCard(vehicle: v, eta: eta)
            }
            if journey.eta == nil, let leg = journey.option.busLegs.first {
                TimetableCard(departures: engine.scheduledDepartures(for: leg, limit: 4))
            }
            if !journey.following.isEmpty {
                AlternativeVehicles(etas: journey.following)
            }
            StepsCard(option: journey.option)
        }
    }
}

struct VehicleCard: View {
    let vehicle: Vehicle
    let eta: ETA
    var body: some View {
        RVCard {
            VStack(alignment: .leading, spacing: RV.Space.m) {
                Text("Tracked vehicle").rvOverlineStyle()
                HStack(spacing: RV.Space.l) {
                    MetricColumn(value: vehicle.doorNo, label: "Door no")
                    if let m = eta.remainingMetres {
                        MetricColumn(value: Fmt.distance(m), label: "To your stop")
                    }
                    if let s = eta.stopsAway {
                        MetricColumn(value: "\(s)", label: s == 1 ? "Stop away" : "Stops away")
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: RV.Space.s) {
                    StatePill(state: eta.state)
                    Text("GPS \(Fmt.age(vehicle.fixAge))")
                        .font(.rvCaption).foregroundStyle(RV.Color.inkFaint)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

struct TimetableCard: View {
    let departures: [Date]
    var body: some View {
        RVCard {
            VStack(alignment: .leading, spacing: RV.Space.m) {
                Text("Scheduled departures").rvOverlineStyle()
                if departures.isEmpty {
                    Text("No further departures scheduled today.")
                        .font(.rvBody).foregroundStyle(RV.Color.inkMuted)
                } else {
                    HStack(spacing: RV.Space.m) {
                        ForEach(departures, id: \.self) { d in
                            VStack(spacing: 2) {
                                Text(Fmt.clock(d)).font(.system(size: 16, weight: .semibold)).monospacedDigit()
                                Text(Fmt.duration(Int(d.timeIntervalSinceNow)))
                                    .font(.rvCaption).foregroundStyle(RV.Color.inkFaint)
                            }
                            .padding(.horizontal, RV.Space.m).padding(.vertical, RV.Space.s)
                            .background(RV.Color.surface, in: RoundedRectangle(cornerRadius: RV.Radius.s))
                        }
                        Spacer(minLength: 0)
                    }
                    Text("Timetable only — not a confirmed arrival.")
                        .font(.rvCaption).foregroundStyle(RV.Color.inkFaint)
                }
            }
        }
    }
}

struct AlternativeVehicles: View {
    @EnvironmentObject var engine: JourneyEngine
    let etas: [ETA]
    var body: some View {
        RVCard {
            VStack(alignment: .leading, spacing: RV.Space.m) {
                Text("Buses behind it").rvOverlineStyle()
                ForEach(Array(etas.enumerated()), id: \.offset) { _, e in
                    Button {
                        guard let d = e.vehicleDoorNo else { return }
                        Haptic.select(); engine.selectVehicle(d)
                    } label: {
                    HStack(spacing: RV.Space.m) {
                        LineBadge(code: e.lineCode, compact: true)
                        Text(e.vehicleDoorNo ?? "—")
                            .font(.rvCaption).foregroundStyle(RV.Color.inkFaint).monospacedDigit()
                        Spacer(minLength: 0)
                        StatePill(state: e.state, compact: true)
                        Text("\(Int(e.predictedMinutes.rounded())) min")
                            .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct StepsCard: View {
    let option: JourneyOption
    var body: some View {
        RVCard {
            VStack(alignment: .leading, spacing: RV.Space.m) {
                Text("Steps").rvOverlineStyle()
                ForEach(option.legs) { leg in
                    HStack(alignment: .top, spacing: RV.Space.m) {
                        Image(systemName: leg.kind == .walk ? "figure.walk" : "bus.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(leg.kind == .walk ? RV.Color.inkMuted : RV.Color.accent)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            if leg.kind == .walk {
                                Text(leg.distanceMetres > 1
                                     ? "Walk \(Fmt.distance(leg.distanceMetres)) · \(Fmt.duration(leg.seconds))"
                                     : "Change buses · \(Fmt.duration(leg.seconds))")
                                    .font(.rvBody)
                            } else {
                                HStack(spacing: 6) {
                                    Text(leg.lineCode ?? "").font(.rvHeadline)
                                    Text("to \(leg.headsign ?? "")").font(.rvBody)
                                        .foregroundStyle(RV.Color.inkMuted).lineLimit(1)
                                }
                                Text("\(leg.boardStop?.name ?? "") → \(leg.alightStop?.name ?? "")")
                                    .font(.rvCaption).foregroundStyle(RV.Color.inkFaint)
                                Text("\(leg.intermediateStops) stops · \(Fmt.duration(leg.seconds))")
                                    .font(.rvCaption).foregroundStyle(RV.Color.inkFaint)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}

/// The one commitment ROVA asks for: this bus, from here to your destination.
struct StartButton: View {
    @EnvironmentObject var engine: JourneyEngine
    let doorNo: String
    var body: some View {
        Button {
            engine.startTrip(doorNo)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 13, weight: .bold))
                Text("Start").font(.rvHeadline)
                Spacer(minLength: 0)
                Text(doorNo).font(.rvCaption).monospacedDigit().opacity(0.75)
            }
        }
        .buttonStyle(.rvProminent)
    }
}

// MARK: - On board

/// Once you are on the bus the question changes completely: not "when does it
/// arrive" but "when do I get off". Nothing else belongs on this card.
struct OnBoardCard: View {
    @EnvironmentObject var engine: JourneyEngine
    @EnvironmentObject var settings: Settings
    let now: Date

    private var leg: JourneyLeg? { engine.focusedJourney?.option.busLegs.first }
    private var eta: ETA? { engine.onBoardETA }

    var body: some View {
        RVCard {
            VStack(alignment: .leading, spacing: RV.Space.l) {
                HStack(spacing: RV.Space.s) {
                    if let l = leg?.lineCode { LineBadge(code: l) }
                    Text("ON BOARD").rvOverlineStyle().foregroundStyle(RV.Color.live)
                    if let d = engine.onBoardDoorNo {
                        Text(d).font(.rvCaption).monospacedDigit()
                            .foregroundStyle(RV.Color.inkFaint)
                    }
                    Spacer(minLength: 0)
                    if let e = eta { StatePill(state: e.state, compact: true) }
                }

                if let e = eta {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text(Fmt.minutesShort(e.predictedMinutes))
                            .font(.rvNumeral(52)).foregroundStyle(RV.Color.ink)
                            .contentTransition(.numericText())
                        if e.predictedMinutes >= 0.75 {
                            Text("min").font(.rvHeadline).foregroundStyle(RV.Color.inkMuted)
                        }
                        Spacer(minLength: 0)
                        if let s = e.stopsAway {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(s)").font(.system(size: 19, weight: .semibold)).monospacedDigit()
                                Text(s == 1 ? "stop left" : "stops left").rvOverlineStyle()
                            }
                        }
                    }
                    Text("until you get off at \(leg?.alightStop?.name ?? "your stop")")
                        .font(.rvBody).foregroundStyle(RV.Color.inkMuted)

                    if e.predictedMinutes <= 2 {
                        Label("Get ready to get off", systemImage: "figure.wave")
                            .font(.rvCallout).foregroundStyle(RV.Color.live)
                            .padding(.horizontal, RV.Space.m).padding(.vertical, RV.Space.s)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RV.Color.live.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: RV.Radius.s, style: .continuous))
                    }
                } else {
                    Text("Waiting for this bus to report its position")
                        .font(.rvBody).foregroundStyle(RV.Color.inkMuted)
                }

                Button {
                    Haptic.tap(); engine.getOff()
                } label: {
                    Text("I have got off").font(.rvCallout)
                        .foregroundStyle(RV.Color.inkMuted)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Other options

struct OtherOptions: View {
    @EnvironmentObject var engine: JourneyEngine
    let current: LiveJourney
    /// Called after a pick so the map can take over the screen.
    var onPick: (LiveJourney) -> Void = { _ in }

    private var others: [LiveJourney] { engine.journeys.filter { $0.id != current.id } }

    var body: some View {
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: RV.Space.s) {
                Text("Other options").rvOverlineStyle().padding(.leading, 4)
                VStack(spacing: RV.Space.s) {
                    ForEach(others) { j in
                        Button {
                            Haptic.select()
                            engine.select(j.option)
                            onPick(j)
                        } label: { OptionRow(journey: j) }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct OptionRow: View {
    @EnvironmentObject var engine: JourneyEngine
    let journey: LiveJourney
    var body: some View {
        HStack(spacing: RV.Space.m) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    ForEach(Array(journey.option.lineCodes.enumerated()), id: \.offset) { i, c in
                        if i > 0 {
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                                .foregroundStyle(RV.Color.inkFaint)
                        }
                        LineBadge(code: c, compact: true)
                    }
                }
                Text("\(Fmt.distance(journey.option.walkMetres)) walk · \(journey.option.busLegs.first?.boardStop?.name ?? "")")
                    .font(.rvCaption).foregroundStyle(RV.Color.inkFaint).lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                if let e = journey.eta {
                    Text("\(Int(e.predictedMinutes.rounded())) min")
                        .font(.system(size: 17, weight: .semibold)).monospacedDigit()
                    StatePill(state: e.state, compact: true)
                } else if let leg = journey.option.busLegs.first,
                          let next = engine.scheduledDepartures(for: leg, limit: 1).first {
                    Text(Fmt.clock(next))
                        .font(.system(size: 17, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(RV.Color.inkMuted)
                    Text("scheduled").rvOverlineStyle()
                } else {
                    Text("—").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(RV.Color.inkFaint)
                    Text("no service").rvOverlineStyle()
                }
            }
        }
        .padding(RV.Space.m)
        .background(RV.Color.surface, in: RoundedRectangle(cornerRadius: RV.Radius.m, style: .continuous))
    }
}

// MARK: - States

struct SkeletonHero: View {
    @State private var shimmer = false
    var body: some View {
        RVCard {
            VStack(alignment: .leading, spacing: RV.Space.m) {
                bar(width: 120, height: 18)
                bar(width: 180, height: 44)
                bar(width: 240, height: 14)
            }
        }
        .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { shimmer = true } }
    }
    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(RV.Color.ink.opacity(shimmer ? 0.10 : 0.05))
            .frame(width: width, height: height)
    }
}

struct EmptyState: View {
    @EnvironmentObject var engine: JourneyEngine
    var body: some View {
        RVCard {
            VStack(alignment: .leading, spacing: RV.Space.s) {
                Text("No bus journey found").font(.rvHeadline)
                Text("ROVA could not connect these two points with the İETT network. Try moving the start or destination closer to a road served by buses.")
                    .font(.rvBody).foregroundStyle(RV.Color.inkMuted)
            }
        }
    }
}

struct FooterNote: View {
    @EnvironmentObject var engine: JourneyEngine
    var body: some View {
        VStack(spacing: 4) {
            if let p = engine.liveProblem {
                Label(p, systemImage: "exclamationmark.triangle")
                    .font(.rvCaption).foregroundStyle(RV.Color.stale)
                    .multilineTextAlignment(.center)
            }
            Text(engine.lastRefresh.map { "İETT data refreshed \(Fmt.age(Date().timeIntervalSince($0)))" }
                 ?? "Waiting for İETT data…")
                .font(.rvCaption).foregroundStyle(RV.Color.inkFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, RV.Space.s)
    }
}
