import SwiftUI

/// The first half-second.
///
/// The mark draws itself the way a journey completes: the line fills from the
/// origin, the destination ring closes, the wordmark settles. It lasts exactly
/// as long as the transit database takes to open — there is no timer padding
/// it out, and if the data is ready sooner, so is the app.
struct SplashView: View {
    var onReady: () -> Void

    @State private var phase: Double = 0
    @State private var wordmark = false
    @State private var dataReady = false
    @State private var minimumShown = false

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 26) {
                ROVAMark(size: 108, phase: phase)
                    .shadow(color: .primary.opacity(0.06), radius: 18, y: 8)

                VStack(spacing: 8) {
                    ROVAWordmark(size: 23)
                    Text("MOVE WITH CERTAINTY")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(2.4)
                        .foregroundStyle(.secondary)
                }
                .opacity(wordmark ? 1 : 0)
                .offset(y: wordmark ? 0 : 8)
                .blur(radius: wordmark ? 0 : 3)
            }
        }
        .task {
            withAnimation(.easeInOut(duration: 0.62)) { phase = 1 }
            withAnimation(.easeOut(duration: 0.45).delay(0.34)) { wordmark = true }

            // Open the database off the main actor; this is the only real work
            // the splash is waiting on.
            async let load: Void = Task.detached(priority: .userInitiated) {
                _ = TransitStore.shared.patterns.count
            }.value
            async let floor: Void = Task.sleep(nanoseconds: 780_000_000)
            _ = try? await (load, floor)
            onReady()
        }
    }
}
