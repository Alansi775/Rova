import SwiftUI

/// Where you are on the route.
///
/// Deliberately the same visual language as the blue dot a phone uses for
/// "you are here", because that is what it means: not a bus somewhere on the
/// line, but your position along the ride, between the stop behind you and
/// the one ahead.
///
/// The pulse is slow and small on purpose. It says "this is live" without
/// demanding attention from someone who is on a bus and mostly not looking.
struct TripProgressDot: View {
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(RV.Color.accent.opacity(0.18))
                .frame(width: 34, height: 34)
                .scaleEffect(pulsing ? 1.0 : 0.72)
                .opacity(pulsing ? 0.35 : 0.85)
            Circle()
                .fill(.white)
                .frame(width: 20, height: 20)
                .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
            Circle()
                .fill(RV.Color.accent)
                .frame(width: 13, height: 13)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
        .accessibilityLabel("Your position along the route")
    }
}
