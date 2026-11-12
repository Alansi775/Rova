import SwiftUI

/// What you get when you tap a bus on the map: which bus this is, how fast it
/// is going, how fresh its GPS is, and when it reaches your stop.
///
/// Deliberately four short facts and nothing else — the sheet below already
/// carries the journey.
struct VehicleCallout: View {
    @EnvironmentObject var engine: JourneyEngine
    let display: VehicleDisplay
    var onClose: () -> Void

    private var state: DataState { .forFix(age: display.fixAge) }
    private var speedText: String {
        // No speed field exists in the feed: it is measured between two
        // consecutive fixes, so a bus just picked up has none yet.
        guard let kmh = display.speedKmh else { return "Measuring" }
        if kmh < 3 { return "Stopped" }
        return "\(Int(kmh.rounded())) km/h"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RV.Space.m) {
            HStack(spacing: RV.Space.s) {
                LineBadge(code: display.vehicle.lineCode, compact: true)
                Text(display.doorNo)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(RV.Color.ink)
                Spacer(minLength: 0)
                // Ask İETT again, now. Without this the only way to get a
                // newer fix was to wait out the poll interval — and when the
                // marker looked wrong there was nothing to do about it.
                Button {
                    Haptic.tap()
                    Task { await engine.refresh(force: true) }
                } label: {
                    Group {
                        if engine.isRefreshing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(RV.Color.inkMuted)
                        }
                    }
                    .frame(width: 28, height: 28)
                    .glassEffect(.regular, in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(engine.isRefreshing)
                .accessibilityLabel("Refresh live positions now")
                Button(action: { Haptic.tap(); onClose() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(RV.Color.inkMuted)
                        .frame(width: 28, height: 28)
                        .glassEffect(.regular, in: .circle)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: RV.Space.xl) {
                fact(speedText, "Speed")
                if let eta = engine.eta(forVehicle: display.doorNo) {
                    // A bus standing still gets no countdown here either.
                    if eta.stalledSeconds != nil {
                        fact("—", "Not moving", tint: RV.Color.stale)
                    } else {
                        fact(eta.predictedMinutes < 0.75 ? "Now"
                                : "\(Fmt.minutesShort(eta.predictedMinutes)) min",
                             "To your stop", tint: eta.confidence.tint)
                    }
                } else if let m = display.metresToBoard {
                    fact(Fmt.distance(m), "To your stop")
                }
                if let n = engine.stopsAway(forVehicle: display.doorNo) {
                    fact("\(n)", n == 1 ? "Stop away" : "Stops away")
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: RV.Space.s) {
                Circle().fill(state.tint).frame(width: 7, height: 7)
                Text("GPS \(Fmt.age(display.fixAge))")
                    .font(.rvCaption).monospacedDigit()
                    .foregroundStyle(RV.Color.inkMuted)
                if let next = engine.nextStopName(forVehicle: display.doorNo) {
                    Text("· heading to \(next)")
                        .font(.rvCaption).foregroundStyle(RV.Color.inkMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            if let leg = engine.focusedJourney?.option.busLegs.first,
               let board = leg.boardStop?.name, let alight = leg.alightStop?.name {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(RV.Color.live)
                    Text("Picks you up at \(board), drops you at \(alight)")
                        .font(.rvCaption).foregroundStyle(RV.Color.ink)
                        .lineLimit(2)
                }
            }

            if engine.tripDoorNo != display.doorNo {
                StartButton(doorNo: display.doorNo)
            }

            Button {
                Haptic.success()
                if engine.onBoardDoorNo == display.doorNo { engine.getOff() }
                else { engine.board(display.doorNo) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: engine.onBoardDoorNo == display.doorNo
                          ? "figure.wave" : "figure.seated.side")
                        .font(.system(size: 12, weight: .bold))
                    Text(engine.onBoardDoorNo == display.doorNo
                         ? "I have got off" : "I am on this bus")
                        .font(.rvCallout)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(engine.onBoardDoorNo == display.doorNo
                                 ? RV.Color.inkMuted : RV.Color.accent)
                .padding(.horizontal, RV.Space.m).padding(.vertical, RV.Space.s)
                .background((engine.onBoardDoorNo == display.doorNo
                             ? RV.Color.inkMuted : RV.Color.accent).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: RV.Radius.s, style: .continuous))
            }
            .buttonStyle(.plain)

            if let stalled = engine.eta(forVehicle: display.doorNo)?.stalledSeconds {
                Text("Standing still for \(Fmt.duration(Int(stalled))). "
                     + "Still reporting, so it has not been lost.")
                    .font(.rvCaption).foregroundStyle(RV.Color.inkMuted)
            }
            if let at = engine.lastRefresh {
                Text("Updated \(Fmt.age(Date().timeIntervalSince(at))) ago")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(RV.Color.inkFaint)
            }

            if display.isEstimatedBetweenFixes {
                Text("Position estimated between GPS reports")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(RV.Color.inkFaint)
            }
        }
        .padding(RV.Space.l)
        .glassEffect(.regular, in: .rect(cornerRadius: RV.Radius.l, style: .continuous))
    }

    private func fact(_ value: String, _ label: String, tint: Color = RV.Color.ink) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(label).rvOverlineStyle()
        }
    }
}
