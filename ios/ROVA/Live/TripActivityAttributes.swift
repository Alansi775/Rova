import Foundation
import ActivityKit

/// What the Lock Screen shows while you are on a bus.
///
/// Shared between the app, which starts and updates the Activity, and the
/// widget extension, which draws it. ActivityKit carries the state across; no
/// App Group and no shared database is involved, which matters because App
/// Groups require a paid developer membership and this app is deliberately
/// signed by a personal team.
///
/// Everything here is already-measured truth handed over for display. The
/// widget computes nothing and predicts nothing: if the app cannot say where
/// the bus is, the Activity says so rather than showing a stale number that
/// looks current because it is on the Lock Screen.
struct TripActivityAttributes: ActivityAttributes {
    /// Fixed for the whole trip.
    let lineCode: String
    let alightStopName: String
    let vehicleDoorNo: String

    struct ContentState: Codable, Hashable {
        /// The stop the bus is heading for.
        let nextStopName: String
        /// Stops still to go before getting off. 0 means now.
        let stopsRemaining: Int
        /// Predicted arrival at the alighting stop, when one can be made.
        let arrivalAtAlight: Date?
        /// How far between the last stop and the next, 0...1.
        let fraction: Double
        /// False when the latest fix is too old to place the bus. The Lock
        /// Screen then says the signal was lost instead of quietly freezing
        /// on the last good number, which would read as live.
        let isLive: Bool

        var headline: String {
            guard isLive else { return "Signal lost" }
            switch stopsRemaining {
            case 0:  return "Get off here"
            case 1:  return "Get off next"
            default: return "\(stopsRemaining) stops to go"
            }
        }
    }
}
