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
