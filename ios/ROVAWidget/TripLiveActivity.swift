import SwiftUI
import WidgetKit
import ActivityKit

/// The trip, on the Lock Screen and in the Dynamic Island.
///
/// Built for someone holding a phone on a moving bus: the two things that
/// matter are how many stops are left and where to get off, so those are the
/// largest things on it. Nothing animates on a timer — every value comes from
/// a measured update the app pushed, so a still Lock Screen means a still bus,
/// not a sleeping app.
struct TripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            lockScreen(context)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.lineCode)
                            .font(.system(size: 17, weight: .heavy, design: .rounded))
                        Text(context.state.isLive ? "live" : "no signal")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let at = context.state.arrivalAtAlight, context.state.isLive {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(at, style: .timer)
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .multilineTextAlignment(.trailing)
                            Text("to \(context.attributes.alightStopName)")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.headline)
                            .font(.system(size: 15, weight: .semibold))
                        if context.state.isLive {
                            Text("Next: \(context.state.nextStopName)")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .lineLimit(1)
                            ProgressView(value: min(1, max(0, context.state.fraction)))
                                .tint(.white)
                        }
                    }
                }
            } compactLeading: {
                Text(context.attributes.lineCode)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
            } compactTrailing: {
                Text(context.state.isLive ? "\(context.state.stopsRemaining)" : "–")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
            } minimal: {
                Text(context.state.isLive ? "\(context.state.stopsRemaining)" : "–")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private func lockScreen(_ context: ActivityViewContext<TripActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(context.attributes.lineCode)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.white.opacity(0.18), in: .capsule)
                Spacer(minLength: 0)
                if context.state.isLive, let at = context.state.arrivalAtAlight {
                    Text(at, style: .timer)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .frame(maxWidth: 70, alignment: .trailing)
                }
            }

            Text(context.state.headline)
                .font(.system(size: 26, weight: .bold))
                .lineLimit(1).minimumScaleFactor(0.7)

            if context.state.isLive {
                Text("Next: \(context.state.nextStopName)  ·  off at \(context.attributes.alightStopName)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressView(value: min(1, max(0, context.state.fraction)))
                    .tint(.white)
            } else {
                // Said plainly rather than shown as a frozen countdown. A
                // number that stopped updating looks exactly like a number
                // that is correct.
                Text("No GPS update from \(context.attributes.vehicleDoorNo) recently.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@main
struct ROVAWidgetBundle: WidgetBundle {
    var body: some Widget { TripLiveActivity() }
}
