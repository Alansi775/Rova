import Foundation
import UserNotifications

/// Local notifications for the journey ROVA is actively tracking.
///
/// iOS does not allow an app to hold a socket open or poll GPS indefinitely in
/// the background, so ROVA does not pretend to. While the app is in the
/// foreground (or briefly after backgrounding) it schedules short-fuse local
/// notifications from the *current* live estimate, and cancels them the moment
/// the estimate changes or the GPS fix goes stale. Nothing is ever fired from
/// a stale fix.
@MainActor
final class NotificationCenterService: ObservableObject {
    static let shared = NotificationCenterService()

    @Published private(set) var authorized = false

    private let center = UNUserNotificationCenter.current()
    private enum ID {
        static let leaveNow = "rova.leave"
        static let approaching = "rova.approaching"
        static let stale = "rova.stale"
        static let getReady = "rova.getready"
        static let getOffNext = "rova.getoffnext"
    }

    /// Which alight warnings have already been delivered this trip, so a bus
    /// that creeps back and forth across a stop boundary cannot buzz the
    /// rider's pocket over and over.
    private var firedThisTrip: Set<String> = []

    /// Tell the rider to get ready, and then to get off.
    ///
    /// Fired from observed progress along the route, never from a countdown:
    /// a timer says "two minutes" whether or not the bus moved, and a rider
    /// standing up at the wrong stop because of a stale estimate is exactly
    /// the failure this project exists to avoid. Two stops out means two stops
    /// out, measured.
    ///
    /// Delivered immediately rather than scheduled, because the condition is
    /// already true when it is detected.
    func updateAlightWarnings(stopsRemaining: Int, nextStopName: String,
                              alightStopName: String, lineCode: String) {
        if stopsRemaining == 2, firedThisTrip.insert(ID.getReady).inserted {
            deliver(id: ID.getReady,
                    title: "Two stops to go",
                    body: "Get ready — you get off at \(alightStopName) after next.")
        }
        if stopsRemaining <= 1, firedThisTrip.insert(ID.getOffNext).inserted {
            deliver(id: ID.getOffNext,
                    title: "Get off at the next stop",
                    body: "\(alightStopName) is next on \(lineCode).")
        }
    }

    /// Called when a trip starts or ends, so the next trip warns again.
    func resetTripWarnings() {
        firedThisTrip.removeAll()
        center.removePendingNotificationRequests(
            withIdentifiers: [ID.getReady, ID.getOffNext])
    }

    private func deliver(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        // No trigger: the thing being announced is true now.
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.authorized = granted }
        }
    }

    /// Re-plan all notifications for the journey currently being tracked.
    func schedule(for journey: LiveJourney, leadMinutes: Int) {
        clear()
        guard authorized, let eta = journey.eta else { return }

        // Never notify from data we no longer trust.
        guard case .liveGPS = eta.state else {
            if case .recentlyUpdated = eta.state {} else { return }
            return
        }
        guard eta.confidence != .low else { return }

        let walkSeconds = journey.option.legs.first(where: { $0.kind == .walk })?.seconds ?? 0
        let arrivalIn = eta.predictedMinutes * 60
        let line = journey.option.busLegs.first?.lineCode ?? "Your bus"
        let stop = journey.option.busLegs.first?.boardStop?.name ?? "your stop"

        // "Leave now" — fires when the remaining time equals the walk time.
        let leaveIn = arrivalIn - Double(walkSeconds)
        if leaveIn > 20 {
            add(id: ID.leaveNow, after: leaveIn,
                title: "Time to leave",
                body: "\(line) reaches \(stop) in about \(Int(eta.predictedMinutes.rounded())) min — it is a \(Fmt.duration(walkSeconds)) walk.")
        }

        // "Approaching" — the configurable reminder.
        let lead = Double(leadMinutes) * 60
        if arrivalIn > lead + 20 {
            add(id: ID.approaching, after: arrivalIn - lead,
                title: "\(line) is \(leadMinutes) minutes away",
                body: "Arriving at \(stop) around \(Fmt.clock(Date().addingTimeInterval(arrivalIn))).")
        }

        // Warn if the GPS signal is about to be considered stale.
        if let age = eta.lastFixAge, age < 75 {
            add(id: ID.stale, after: max(60, 180 - age),
                title: "Live signal lost",
                body: "ROVA has not had a GPS update for \(line) recently. The countdown is no longer live.")
        }
    }

    func clear() {
        center.removePendingNotificationRequests(
            withIdentifiers: [ID.leaveNow, ID.approaching, ID.stale])
    }

    private func add(id: String, after seconds: TimeInterval, title: String, body: String) {
        guard seconds > 5 else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
