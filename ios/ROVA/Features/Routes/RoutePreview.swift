import SwiftUI

/// One tap on a journey: every stop this bus calls at, the time at each, and
/// a single button to start following it.
///
/// It pushes onto a navigation stack rather than taking over the screen, so
/// Back always works — nothing here is a trap.
struct RoutePreview: View {
    @EnvironmentObject var engine: JourneyEngine
    let journey: LiveJourney
    var onStart: () -> Void

    @State private var now = Date()
    private let clock = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    private var leg: JourneyLeg? { journey.option.busLegs.first }
    private var stops: [TripStop] { engine.previewStops(for: journey.option) }
    private var isLive: Bool { engine.startableVehicle(for: journey.option) != nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                summary
                StopList(stops: stops, now: now, showGaps: true)
                footnote
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 120)
        }
        .scrollBounceBehavior(.basedOnSize)
        .navigationTitle(leg?.lineCode ?? "Route")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { startBar }
        .onReceive(clock) { now = $0 }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if let l = leg?.lineCode { LineBadge(code: l) }
                Text(leg?.headsign ?? "")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            HStack(spacing: 26) {
                fact(Fmt.duration(journey.totalSeconds), "Door to door")
                fact(Fmt.duration(journey.option.walkSeconds), "Walk")
                fact("\(max(0, stops.count - 1))", "Stops")
                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RV.Color.surface, in: .rect(cornerRadius: 26, style: .continuous))
    }

    private func fact(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(.system(.headline, design: .rounded, weight: .semibold))
                .monospacedDigit()
            Text(l).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
        }
    }

    private var footnote: some View {
        Text(isLive
             ? "Times are predicted from a bus reporting its position now."
             : "No bus on this line is reporting a position. These are timetable times, not confirmed arrivals.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    private var startBar: some View {
        Button(action: onStart) {
            HStack(spacing: 8) {
                Image(systemName: "location.north.fill")
                Text(isLive ? "Start" : "No live bus to follow")
            }
        }
        .buttonStyle(.rvProminent)
        .disabled(!isLive)
        .opacity(isLive ? 1 : 0.45)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

/// The stop sequence, used both before you start and while you ride.
struct StopList: View {
    let stops: [TripStop]
    let now: Date
    var showGaps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(stops) { s in
                HStack(alignment: .center, spacing: 12) {
                    dot(s)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name)
                            .font(s.isBoard || s.isAlight ? .body.weight(.semibold) : .body)
                            .foregroundStyle(s.passed ? Color.secondary : Color.primary)
                            .lineLimit(1)
                        if s.isBoard {
                            Text("you get on").font(.caption2.weight(.semibold))
                                .foregroundStyle(RV.Color.accent)
                        } else if s.isAlight {
                            Text("you get off").font(.caption2.weight(.semibold))
                                .foregroundStyle(RV.Color.live)
                        } else if showGaps, let g = s.secondsFromPrevious, g >= 30 {
                            Text("\(max(1, Int((Double(g) / 60).rounded()))) min")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if let e = s.eta {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(Fmt.clock(e))
                                .font(.subheadline.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(s.passed ? Color.secondary : Color.primary)
                            if !s.passed {
                                Text(Fmt.duration(Int(e.timeIntervalSince(now))))
                                    .font(.caption2).monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("—").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 7)
                .opacity(s.passed ? 0.45 : 1)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(RV.Color.surface, in: .rect(cornerRadius: 26, style: .continuous))
    }

    private func dot(_ s: TripStop) -> some View {
        let tint: Color = s.isAlight ? RV.Color.live : (s.isBoard ? RV.Color.accent : .secondary)
        return ZStack {
            if s.passed {
                Circle().fill(.tertiary).frame(width: 7, height: 7)
            } else {
                Circle().strokeBorder(tint, lineWidth: 2.5).frame(width: 11, height: 11)
            }
        }
        .frame(width: 14)
    }
}
