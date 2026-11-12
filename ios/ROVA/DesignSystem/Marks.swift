import SwiftUI

/// The ROVA mark.
///
/// A journey reduced to its two certainties: where you are, and where you are
/// going — a solid node, a line of travel, an open node. No bus, no map pin,
/// no illustration. It is drawn in code so it is exact at any size and can
/// animate.
///
/// The line is offset rather than straight: a journey bends.
struct ROVAMark: View {
    var size: CGFloat = 64
    /// 0 … 1 — drives the travelling fill used on the splash. Negative means
    /// "finished", which is how it is drawn everywhere else.
    var phase: Double = -1
    var tint: Color = .primary

    var body: some View {
        Canvas { ctx, canvasSize in
            let rect = CGRect(origin: .zero, size: canvasSize)
            let s = min(rect.width, rect.height)
            let lw = s * 0.115
            let inset = s * 0.26

            let start = CGPoint(x: rect.midX - s * 0.145, y: rect.maxY - inset)
            let bend  = CGPoint(x: rect.midX - s * 0.145, y: rect.midY + s * 0.02)
            let end   = CGPoint(x: rect.midX + s * 0.145, y: rect.minY + inset)

            var track = Path()
            track.move(to: start)
            track.addLine(to: CGPoint(x: bend.x, y: bend.y + s * 0.08))
            track.addQuadCurve(to: CGPoint(x: bend.x + s * 0.09, y: bend.y - s * 0.05),
                               control: CGPoint(x: bend.x, y: bend.y - s * 0.02))
            track.addLine(to: end)

            // The route, drawn faint then filled up to `phase`.
            let done = phase < 0 ? 1.0 : max(0, min(1, phase))
            ctx.stroke(track, with: .color(tint.opacity(phase < 0 ? 1 : 0.16)),
                       style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
            if phase >= 0 {
                ctx.stroke(track.trimmedPath(from: 0, to: done),
                           with: .color(tint),
                           style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
            }

            // Origin: solid. Destination: open. Certainty at both ends.
            let r = s * 0.115
            ctx.fill(Path(ellipseIn: CGRect(x: start.x - r, y: start.y - r,
                                            width: r * 2, height: r * 2)),
                     with: .color(tint))
            let ro = s * 0.135
            ctx.stroke(Path(ellipseIn: CGRect(x: end.x - ro, y: end.y - ro,
                                              width: ro * 2, height: ro * 2)),
                       with: .color(tint.opacity(phase < 0 || done > 0.92 ? 1 : 0.22)),
                       lineWidth: lw * 0.78)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// ROVA, set the way the mark is drawn: tight, even, unmistakable.
struct ROVAWordmark: View {
    var size: CGFloat = 20
    var tint: Color = .primary
    var body: some View {
        Text("ROVA")
            .font(.system(size: size, weight: .bold, design: .default))
            .tracking(size * 0.26)
            .foregroundStyle(tint)
            .accessibilityLabel("ROVA")
    }
}
