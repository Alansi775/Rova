import Foundation
import SwiftUI

enum Fmt {
    static let istanbul = TimeZone(identifier: "Europe/Istanbul")!

    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeZone = istanbul
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    /// "7 min", "1 h 05", "now"
    static func duration(_ seconds: Int) -> String {
        if seconds < 45 { return "now" }
        let m = Int((Double(seconds) / 60).rounded())
        if m < 60 { return "\(m) min" }
        return "\(m / 60) h \(String(format: "%02d", m % 60))"
    }

    static func minutesShort(_ minutes: Double) -> String {
        if minutes < 0.75 { return "now" }
        return "\(Int(minutes.rounded()))"
    }

    static func distance(_ metres: Double) -> String {
        metres < 950 ? "\(Int((metres / 10).rounded() * 10)) m"
                     : String(format: "%.1f km", metres / 1000)
    }

    static func age(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s ago" }
        return "\(s / 3600)h ago"
    }
}

extension DataState {
    var tint: Color {
        switch self {
        case .liveGPS:         return RV.Color.live
        case .recentlyUpdated: return RV.Color.warn
        case .delayedData:     return RV.Color.stale
        case .scheduledOnly:   return RV.Color.scheduled
        case .liveUnavailable: return RV.Color.scheduled
        }
    }
    var symbol: String {
        switch self {
        case .liveGPS:         return "dot.radiowaves.up.forward"
        case .recentlyUpdated: return "clock.arrow.circlepath"
        case .delayedData:     return "exclamationmark.triangle"
        case .scheduledOnly:   return "calendar"
        case .liveUnavailable: return "antenna.radiowaves.left.and.right.slash"
        }
    }
}

extension Confidence {
    var label: String {
        switch self {
        case .high: return "High confidence"
        case .medium: return "Medium confidence"
        case .low: return "Low confidence"
        case .none: return "No estimate"
        }
    }
    var tint: Color {
        switch self {
        case .high: return RV.Color.live
        case .medium: return RV.Color.warn
        case .low, .none: return RV.Color.stale
        }
    }
}

/// Small pill showing how fresh the underlying data is. Never says "live"
/// unless the GPS fix really is fresh.
struct StatePill: View {
    let state: DataState
    var compact = false
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: state.symbol).font(.system(size: compact ? 9 : 10, weight: .bold))
            Text(compact ? shortLabel : state.label)
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
        }
        .foregroundStyle(state.tint)
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 3 : 4)
        .background(state.tint.opacity(0.14), in: Capsule())
    }
    private var shortLabel: String {
        switch state {
        case .liveGPS: return "LIVE"
        case .recentlyUpdated: return "RECENT"
        case .delayedData: return "DELAYED"
        case .scheduledOnly: return "SCHEDULE"
        case .liveUnavailable: return "NO SIGNAL"
        }
    }
}
