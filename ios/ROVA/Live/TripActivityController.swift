import Foundation
import ActivityKit

/// Starts, updates and ends the Lock Screen Activity for a trip.
///
/// Updates are pushed only when something a rider would notice has changed —
/// the next stop, the number of stops left, whether the signal is live, or a
/// meaningful move along the gap between two stops. ActivityKit budgets
/// updates, and an Activity refreshed on a timer would burn that budget
/// redrawing numbers that did not change.
///
/// Nothing here predicts. It forwards what the engine measured, including
/// "the fix is too old to place the bus", which the Lock Screen states rather
/// than hiding behind the last good number.
/// Not `@MainActor`: an `Activity` handle is not `Sendable`, so keeping it on
/// one actor and awaiting its async methods from another is precisely the
/// crossing Swift 6 rejects. An actor of its own keeps the handle in a single
/// isolation domain for its whole life.
actor TripActivityController {
    static let shared = TripActivityController()

    /// `nonisolated(unsafe)` because `Activity` is not `Sendable`, yet its
    /// `update` and `end` are nonisolated and async: held as isolated state,
    /// every call to them crosses an isolation boundary and Swift 6 rejects
    /// it. ActivityKit's own handle is documented as safe to use from any
    /// context, and this property is only ever touched inside this actor, so
    /// the unsafety is in the annotation rather than in the behaviour.
    private nonisolated(unsafe) var activity: Activity<TripActivityAttributes>?
    private var lastState: TripActivityAttributes.ContentState?

    /// Fraction must move by this much before an update is worth spending.
    private let fractionStep = 0.12

    var isRunning: Bool { activity != nil }

    func start(lineCode: String, alightStopName: String, doorNo: String,
               state: TripActivityAttributes.ContentState) async {
        guard activity == nil else { await update(state); return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = TripActivityAttributes(lineCode: lineCode,
                                                alightStopName: alightStopName,
                                                vehicleDoorNo: doorNo)
        activity = try? Activity.request(
            attributes: attributes,
            content: .init(state: state, staleDate: Date().addingTimeInterval(15 * 60)),
            pushType: nil)
        lastState = state
    }

    func update(_ state: TripActivityAttributes.ContentState) async {
        guard let activity else { return }
        guard worthUpdating(state) else { return }
        lastState = state
        await activity.update(ActivityContent(
            state: state, staleDate: Date().addingTimeInterval(15 * 60)))
    }

    /// End it, leaving nothing behind on the Lock Screen.
    func end() async {
        guard let activity else { return }
        lastState = nil
        self.activity = nil
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    private func worthUpdating(_ s: TripActivityAttributes.ContentState) -> Bool {
        guard let last = lastState else { return true }
        if last.stopsRemaining != s.stopsRemaining { return true }
        if last.nextStopName != s.nextStopName { return true }
        if last.isLive != s.isLive { return true }
        if abs(last.fraction - s.fraction) >= fractionStep { return true }
        // The arrival time drifting by a minute is worth showing; a few
        // seconds of jitter is not.
        if let a = last.arrivalAtAlight, let b = s.arrivalAtAlight,
           abs(a.timeIntervalSince(b)) >= 60 { return true }
        if (last.arrivalAtAlight == nil) != (s.arrivalAtAlight == nil) { return true }
        return false
    }
}
