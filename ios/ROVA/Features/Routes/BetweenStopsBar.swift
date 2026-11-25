import SwiftUI

/// "You are here" — between two stops, not at either of them.
///
/// The stop list could only ever say which stops had been passed, so a rider
/// halfway down a long gap saw nothing moving and no way to tell whether the
/// bus was about to arrive or had just pulled out. This fills the gap in the
/// list with the gap on the road.
///
/// The fill is driven by measured distance along the published route, so it
/// advances because the bus moved. It is not a timer: nothing here animates
/// forward on its own while the bus sits in traffic.
struct BetweenStopsBar: View {
    let fraction: Double
    let nextStopName: String
    let eta: Date?
    let now: Date

    var body: some View {
        HStack(spacing: RV.Space.m) {
            // Aligned with the stop markers in the rows above and below.
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(RV.Color.inkFaint.opacity(0.22))
                    .frame(width: 4)
                GeometryReader { geo in
                    Capsule()
                        .fill(RV.Color.accent)
                        .frame(width: 4, height: geo.size.height * clamped)
                }
                .frame(width: 4)
            }
            .frame(width: 18, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text("You are here")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(RV.Color.accent)
                Text("Next: \(nextStopName)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(RV.Color.inkMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let eta {
                let seconds = Int(eta.timeIntervalSince(now))
                if seconds > 0 {
                    Text(Fmt.duration(seconds))
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(RV.Color.inkMuted)
                }
            }
        }
        .padding(.vertical, 2)
        .animation(.easeInOut(duration: 0.8), value: fraction)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "You are \(Int(clamped * 100)) percent of the way to \(nextStopName)")
    }

    private var clamped: Double { min(1, max(0, fraction)) }
}
