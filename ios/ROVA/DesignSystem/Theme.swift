import SwiftUI

// MARK: - Colour system

enum RV {
    enum Color {
        /// Ink, not a brand colour. ROVA is black on white and white on black;
        /// the only colour in the app carries meaning.
        static let accent      = SwiftUI.Color.primary

        /// The four status colours, and nothing else. These are Apple's own
        /// system colours so they match the platform in both appearances and
        /// stay legible with accessibility settings on.
        static let live        = SwiftUI.Color.green
        static let warn        = SwiftUI.Color.orange
        /// No signal is grey, never red. A bus that has stopped reporting is
        /// unknown, not dangerous, and a red marker on a map reads as an
        /// alarm — it made the whole screen feel like something was broken.
        static let stale       = SwiftUI.Color(uiColor: .systemGray)
        static let scheduled   = SwiftUI.Color.secondary

        static let canvas      = SwiftUI.Color(.systemBackground)
        static let surface     = SwiftUI.Color(uiColor: .secondarySystemBackground)
        static let raised      = SwiftUI.Color(uiColor: .tertiarySystemBackground)
        static let hairline    = SwiftUI.Color.primary.opacity(0.08)

        static let ink         = SwiftUI.Color.primary
        static let inkMuted    = SwiftUI.Color.secondary
        static let inkFaint    = SwiftUI.Color.primary.opacity(0.38)

        /// The colour to write *on top of* `ink`. Always the opposite of the
        /// text colour, never a fixed white: a prominent button is filled with
        /// `.primary`, which is white in dark mode, so a white label vanished
        /// into it and the button read as empty. This flips with the
        /// appearance, so the contrast is always maximal.
        static let onInk       = SwiftUI.Color(uiColor: .systemBackground)
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s:  CGFloat = 8
        static let m:  CGFloat = 12
        static let l:  CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let s:  CGFloat = 14
        static let m:  CGFloat = 20
        static let l:  CGFloat = 28
        static let pill: CGFloat = 999
    }
}

// MARK: - Typography

extension Font {
    /// Big numeric readout (ETA minutes).
    static func rvNumeral(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
    }
    static let rvTitle      = Font.system(size: 26, weight: .bold, design: .default)
    static let rvHeadline   = Font.system(size: 17, weight: .semibold)
    static let rvBody       = Font.system(size: 15, weight: .regular)
    static let rvCallout    = Font.system(size: 14, weight: .medium)
    static let rvCaption    = Font.system(size: 12, weight: .medium)
    /// Wide-tracked all-caps label.
    static let rvOverline   = Font.system(size: 11, weight: .semibold)
}

extension View {
    func rvOverlineStyle() -> some View {
        self.font(.rvOverline).tracking(1.1).textCase(.uppercase)
            .foregroundStyle(RV.Color.inkFaint)
    }
}

// MARK: - Surfaces

struct RVCard<Content: View>: View {
    var padding: CGFloat = RV.Space.l
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RV.Color.raised, in: RoundedRectangle(cornerRadius: RV.Radius.l, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: RV.Radius.l, style: .continuous)
                    .strokeBorder(RV.Color.hairline, lineWidth: 0.5)
            )
    }
}

/// The line-number badge used everywhere a bus line is named.
struct LineBadge: View {
    let code: String
    var tint: Color = RV.Color.accent
    var compact = false
    var body: some View {
        Text(code)
            .font(.system(size: compact ? 12 : 14, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 7 : 9)
            .padding(.vertical, compact ? 3 : 5)
            .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .fixedSize()
    }
}

/// Small key/value column used inside route cards.
struct MetricColumn: View {
    let value: String
    let label: String
    var tint: Color = RV.Color.ink
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                .foregroundStyle(tint)
            Text(label).rvOverlineStyle()
        }
    }
}

// MARK: - Haptics

enum Haptic {
    static func tap()     { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func select()  { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warn()    { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}


// MARK: - Buttons

/// The one prominent button in ROVA: ink fill, inverse label, Liquid Glass.
///
/// It exists because every prominent button was tinted with `.primary` and
/// left to pick its own label colour, which in dark mode meant white on white.
/// Setting the label colour explicitly is the whole point — do not replace
/// this with `.glassProminent` alone.
struct RVProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.rvHeadline)
            .foregroundStyle(RV.Color.onInk)
            .padding(.horizontal, RV.Space.l)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(RV.Color.ink.opacity(configuration.isPressed ? 0.78 : 1),
                        in: .rect(cornerRadius: RV.Radius.m, style: .continuous))
            .contentShape(.rect(cornerRadius: RV.Radius.m, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The quieter sibling: glass, ink label. Used where a button must not shout.
struct RVSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.rvHeadline)
            .foregroundStyle(RV.Color.ink)
            .padding(.horizontal, RV.Space.l)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: .rect(cornerRadius: RV.Radius.m, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == RVProminentButtonStyle {
    static var rvProminent: RVProminentButtonStyle { .init() }
}
extension ButtonStyle where Self == RVSecondaryButtonStyle {
    static var rvSecondary: RVSecondaryButtonStyle { .init() }
}
