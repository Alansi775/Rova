import SwiftUI

/// The buses that can take you there, one card each, soonest first.
///
/// This replaces a list of *journeys* with a list of *buses*, because that is
/// what a rider at a stop is actually choosing between. The app used to rank
/// whole itineraries and show the best one, so a bus on another line that
/// would have arrived sooner — serving the same destination — was never
/// offered at all.
///
/// The carousel and the map are two views of one selection. Swiping to a card
/// moves the map to that bus; tapping a bus on the map scrolls to its card.
/// Neither is the master: both read and write `engine.trackedVehicleDoorNo`.
struct BusCarousel: View {
    @EnvironmentObject var engine: JourneyEngine
    let now: Date
    var onStart: (JourneyEngine.BusCard) -> Void

    /// Bound to the scroll position, which is what makes the two directions
    /// work with one piece of state rather than two that can disagree.
    @State private var centred: String?

    private var cards: [JourneyEngine.BusCard] { engine.busCards }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: RV.Space.m) {
                ForEach(cards) { card in
                    BusCardView(card: card, now: now, onStart: { onStart(card) })
                        // 86 % of the width, so the next bus shows at the
                        // edge. A full-width card reads as a panel and hides
                        // that there is anything to swipe to; the sliver of
                        // the neighbour is the whole invitation.
                        .containerRelativeFrame(.horizontal) { width, _ in width * 0.86 }
                        .scrollTransition(axis: .horizontal) { content, phase in
                            // The neighbours sit back a little, so the one in
                            // the middle is unmistakably the one being
                            // talked about.
                            content
                                .scaleEffect(phase.isIdentity ? 1 : 0.94)
                                .opacity(phase.isIdentity ? 1 : 0.55)
                        }
                        .id(card.doorNo)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, RV.Space.m)
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $centred)
        .scrollIndicators(.hidden)
        .sensoryFeedback(.selection, trigger: centred)
        .frame(height: 176)
        // Swiped here → the map goes to that bus.
        .onChange(of: centred) { _, door in
            guard let door, let card = cards.first(where: { $0.doorNo == door }) else { return }
            guard engine.trackedVehicleDoorNo != door else { return }
            engine.choose(card)
        }
        // Tapped on the map → this scrolls to its card.
        .onChange(of: engine.trackedVehicleDoorNo) { _, door in
            guard let door, centred != door else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { centred = door }
        }
        .onAppear {
            centred = engine.trackedVehicleDoorNo ?? cards.first?.doorNo
        }
    }
}

/// One bus.
private struct BusCardView: View {
    @EnvironmentObject var engine: JourneyEngine
    let card: JourneyEngine.BusCard
    let now: Date
    var onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RV.Space.m) {
            HStack(spacing: RV.Space.s) {
                LineBadge(code: card.lineCode)
                // The door number, because it is what is painted on the bus
                // and the only way to be sure the one pulling in is yours.
                Text(card.doorNo)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(RV.Color.inkMuted)
                Spacer(minLength: 0)
                StatePill(state: card.eta.state, compact: true)
                if engine.trackedVehicleDoorNo == card.doorNo {
                    RefreshVehicleButton()
                }
            }

            countdown

            // When the journey needs a change, the card says so here rather
            // than letting the rider discover it at the alighting stop. The
            // second leg is a timetable until its own bus is close enough to
            // be tracked, so it is given as a line and a place, never as a
            // confident second countdown.
            if let change = transfer {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.system(size: 11, weight: .semibold))
                    Text(change)
                        .font(.rvCaption)
                        .lineLimit(2)
                }
                .foregroundStyle(RV.Color.inkMuted)
            }

            Button("Start", systemImage: "location.north.fill", action: onStart)
                .buttonStyle(.glassProminent)
                .tint(RV.Color.ink)
                .foregroundStyle(RV.Color.onInk)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(card.eta.isUnreliable)
        }
        .padding(RV.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RV.Color.cardFill,
                    in: RoundedRectangle(cornerRadius: RV.Radius.m, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }

    /// "Change at X to the 34G" — nil for a direct ride.
    private var transfer: String? {
        let legs = card.option.busLegs
        guard legs.count > 1, let second = legs.dropFirst().first,
              let at = legs.first?.alightStop?.name,
              let line = second.lineCode else { return nil }
        if let final = second.alightStop?.name {
            return "Change at \(at) to the \(line), off at \(final)"
        }
        return "Change at \(at) to the \(line)"
    }

    @ViewBuilder
    private var countdown: some View {
        if card.eta.isUnreliable {
            // A bus that is reporting but has not moved gets a dash, never a
            // number. The minutes would be a floor, not a prediction.
            VStack(alignment: .leading, spacing: 2) {
                Text("—").font(.rvNumeral(40)).foregroundStyle(RV.Color.inkFaint)
                Text(card.eta.lowConfidenceReason ?? "Not moving — no usable estimate")
                    .font(.rvCaption).foregroundStyle(RV.Color.inkMuted)
                    .lineLimit(2)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .lastTextBaseline, spacing: 5) {
                    Text(Fmt.minutesShort(card.eta.predictedMinutes))
                        .font(.rvNumeral(40)).foregroundStyle(RV.Color.ink)
                        .contentTransition(.numericText())
                    Text("min").font(.rvCallout).foregroundStyle(RV.Color.inkMuted)
                }
                if card.isReachable {
                    Text("\(Fmt.duration(card.walkSeconds)) walk to the stop")
                        .font(.rvCaption).foregroundStyle(RV.Color.inkMuted)
                } else {
                    // Said rather than hidden: knowing a bus is already out of
                    // reach is what stops a rider running for it.
                    Text("Too soon to reach on foot")
                        .font(.rvCaption).foregroundStyle(RV.Color.stale)
                }
            }
        }
    }
}
