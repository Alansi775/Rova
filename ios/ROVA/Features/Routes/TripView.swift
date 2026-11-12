import SwiftUI

/// Following one bus, start to finish.
///
/// Press Start and the rest of the city goes away: one vehicle, its stops in
/// order, the minutes between them, what it has already passed and what is
/// still ahead — until you are at your destination.
struct TripView: View {
    @EnvironmentObject var engine: JourneyEngine
    @EnvironmentObject var settings: Settings
    let now: Date
    var expanded: Bool

    private var leg: JourneyLeg? { engine.focusedJourney?.option.busLegs.first }
    private var stops: [TripStop] { engine.tripStops() }
    private var phase: JourneyEngine.TripPhase { engine.tripPhase }

    /// The stop everything is counted to: your boarding stop while you wait,
    /// your alighting stop once you are aboard.
    private var target: TripStop? {
        switch phase {
        case .waiting: return stops.first(where: \.isBoard)
        default:       return stops.first(where: \.isAlight)
        }
    }

    var body: some View {
        VStack(spacing: RV.Space.l) {
            header
            if expanded { stopList } else { nextStopsPreview }
        }
    }

    // MARK: header

    private var header: some View {
        RVCard {
            VStack(alignment: .leading, spacing: RV.Space.l) {
                HStack(spacing: RV.Space.s) {
                    if let l = leg?.lineCode { LineBadge(code: l) }
                    Text(phaseLabel).rvOverlineStyle().foregroundStyle(phaseTint)
                    if let d = engine.tripDoorNo {
                        Text(d).font(.rvCaption).monospacedDigit()
                            .foregroundStyle(RV.Color.inkFaint)
                    }
                    Spacer(minLength: 0)
                    if let v = engine.tripDoorNo.flatMap({ engine.vehicle(doorNo: $0) }) {
                        StatePill(state: .forFix(age: v.fixAge), compact: true)
                    }
                }

                if phase == .arrived {
                    Text("You are at \(leg?.alightStop?.name ?? "your stop")")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(RV.Color.ink)
                } else if let t = target, let eta = t.eta {
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text(Fmt.minutesShort(max(0, eta.timeIntervalSince(now)) / 60))
                            .font(.rvNumeral(52)).foregroundStyle(RV.Color.ink)
                            .contentTransition(.numericText())
                        Text("min").font(.rvHeadline).foregroundStyle(RV.Color.inkMuted)
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(stopsRemaining)")
                                .font(.system(size: 19, weight: .semibold)).monospacedDigit()
                            Text(stopsRemaining == 1 ? "stop" : "stops").rvOverlineStyle()
                        }
                    }
                    Text(phase == .waiting
                         ? "until it reaches \(t.name)"
                         : "until you get off at \(t.name)")
                        .font(.rvBody).foregroundStyle(RV.Color.inkMuted)

                    if phase != .waiting, let e = target?.eta,
                       e.timeIntervalSince(now) <= 120 {
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

                // If the feed goes quiet, ROVA says so rather than letting the
                // bus quietly vanish off the map.
                if let next = engine.legAfterFollowed, !next.hasLiveData {
                    Label("After \(next.board) you change to \(next.line), which publishes "
                          + "no live positions — ROVA can only show its timetable.",
                          systemImage: "info.circle")
                        .font(.rvCaption).foregroundStyle(RV.Color.inkMuted)
                }

                if let silent = engine.followedBusSilentFor {
                    Label("This bus last reported \(Fmt.age(silent)) — shown where it was",
                          systemImage: "antenna.radiowaves.left.and.right.slash")
                        .font(.rvCaption).foregroundStyle(RV.Color.stale)
                }

                Button {
                    Haptic.tap(); engine.endTrip()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                        Text("End").font(.rvCallout)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(RV.Color.inkMuted)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var stopsRemaining: Int {
        guard let t = target else { return 0 }
        return max(0, stops.filter { !$0.passed && $0.index <= t.index }.count)
    }

    private var phaseLabel: String {
        switch phase {
        case .waiting: return "ON THE WAY TO YOU"
        case .riding:  return "ON BOARD"
        case .arrived: return "ARRIVED"
        }
    }

    private var phaseTint: Color {
        switch phase {
        case .waiting: return RV.Color.accent
        case .riding:  return RV.Color.live
        case .arrived: return RV.Color.inkMuted
        }
    }

    // MARK: stops

    /// Collapsed: just the next few, so the card stays readable.
    private var nextStopsPreview: some View {
        let upcoming = Array(stops.filter { !$0.passed }.prefix(3))
        return RVCard {
            VStack(alignment: .leading, spacing: RV.Space.m) {
                Text("Next stops").rvOverlineStyle()
                ForEach(upcoming) { s in row(s, compact: true) }
                if stops.filter({ !$0.passed }).count > upcoming.count {
                    Text("Pull up for the full list")
                        .font(.rvCaption).foregroundStyle(RV.Color.inkFaint)
                }
            }
        }
    }

    private var stopList: some View {
        RVCard {
            VStack(alignment: .leading, spacing: 0) {
                Text("Stops").rvOverlineStyle()
                    .padding(.bottom, RV.Space.m)
                ForEach(stops) { s in
                    row(s, compact: false)
                        .padding(.vertical, 5)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ s: TripStop, compact: Bool) -> some View {
        HStack(alignment: .center, spacing: RV.Space.m) {
            marker(s)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.name)
                    .font(s.isAlight ? .rvHeadline : .rvBody)
                    .foregroundStyle(s.passed ? RV.Color.inkFaint : RV.Color.ink)
                    .lineLimit(1)
                if !compact, let gap = s.secondsFromPrevious, gap >= 30 {
                    Text("\(max(1, Int((Double(gap) / 60).rounded()))) min from previous stop")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(RV.Color.inkFaint)
                }
                if s.isBoard {
                    Text("you get on").rvOverlineStyle().foregroundStyle(RV.Color.accent)
                } else if s.isAlight {
                    Text("you get off").rvOverlineStyle().foregroundStyle(RV.Color.live)
                }
            }
            Spacer(minLength: 0)
            if let e = s.eta {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Fmt.clock(e))
                        .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(s.passed ? RV.Color.inkFaint : RV.Color.ink)
                    if !s.passed {
                        Text(Fmt.duration(Int(e.timeIntervalSince(now))))
                            .font(.system(size: 11, weight: .medium)).monospacedDigit()
                            .foregroundStyle(RV.Color.inkFaint)
                    }
                }
            } else {
                Text("—").font(.rvCaption).foregroundStyle(RV.Color.inkFaint)
            }
        }
        .opacity(s.passed ? 0.5 : 1)
    }

    private func marker(_ s: TripStop) -> some View {
        let tint: Color = s.isAlight ? RV.Color.live
            : (s.isBoard ? RV.Color.accent : RV.Color.inkMuted)
        return ZStack {
            if !s.passed {
                Circle().strokeBorder(tint, lineWidth: 2.5).frame(width: 11, height: 11)
            } else {
                Circle().fill(RV.Color.inkFaint).frame(width: 7, height: 7)
            }
        }
        .frame(width: 14)
    }
}
