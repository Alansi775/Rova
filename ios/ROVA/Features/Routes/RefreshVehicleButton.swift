import SwiftUI

/// Refresh the bus you are following, by hand.
///
/// İETT publishes a new position for a moving vehicle roughly every minute,
/// so the app polls at that cadence and the socket pushes in between. This
/// button exists anyway, because a rider watching a bus approach wants to be
/// able to ask — and "wait and trust it" is not an answer when the thing on
/// screen has not moved for forty seconds.
///
/// What it must not do is imply it made the bus move. Pressing it twice
/// inside İETT's own update interval is supposed to return the same fix, so
/// that case is stated plainly rather than hidden behind a spinner and a
/// re-render of identical numbers. The alternative — looking successful every
/// time — would teach the rider that a fresh-looking screen means a fresh
/// position, which is the exact habit this project exists to break.
struct RefreshVehicleButton: View {
    @EnvironmentObject var engine: JourneyEngine

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                Haptic.tap()
                Task { await engine.refreshTrackedVehicle() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .rotationEffect(.degrees(isWorking ? 360 : 0))
                    .animation(isWorking
                               ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                               : .default,
                               value: isWorking)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(isWorking)
            .accessibilityLabel("Refresh this bus's position")

            if let note {
                Text(note)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(noteTint)
                    .multilineTextAlignment(.trailing)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: engine.manualRefresh)
    }

    private var isWorking: Bool { engine.manualRefresh == .working }

    private var note: String? {
        switch engine.manualRefresh {
        case .idle, .working:            return nil
        case .newer(let seconds):        return "updated · \(seconds)s old"
        // Said in İETT's terms, not ours: nothing is wrong, the source simply
        // has not published again yet.
        case .unchanged:                 return "no newer position yet"
        case .failed(let why):           return why
        }
    }

    private var noteTint: Color {
        switch engine.manualRefresh {
        case .newer:    return RV.Color.live
        case .failed:   return RV.Color.stale
        default:        return RV.Color.inkFaint
        }
    }
}
