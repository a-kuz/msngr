import SwiftUI

/// The ring around a picture with live stories: one arc per story, clockwise
/// from the top in the order they were published, with a break between two
/// arcs. An arc for a story not yet watched wears the rainbow, a watched one
/// is faint grey. A single story is a closed ring. The view fills the frame it
/// is given and draws the stroke inside it.
struct StoryRing: View {
    /// One flag per story: whether it has been watched.
    let seen: [Bool]
    var lineWidth: CGFloat = 2
    /// The break between two arcs, in points along the ring, caps included.
    var gap: CGFloat = 4

    var body: some View {
        ZStack {
            Arcs(seen: seen, wanted: false, gap: gap, lineWidth: lineWidth)
                .stroke(Theme.storyRainbow, style: style)
            Arcs(seen: seen, wanted: true, gap: gap, lineWidth: lineWidth)
                .stroke(Theme.storyRingSeen, style: style)
        }
        .accessibilityHidden(true)
    }

    private var style: StrokeStyle {
        StrokeStyle(lineWidth: lineWidth, lineCap: .round)
    }

    /// The arcs of the stories whose `seen` flag equals `wanted`.
    private struct Arcs: Shape {
        let seen: [Bool]
        let wanted: Bool
        let gap: CGFloat
        let lineWidth: CGFloat

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let count = seen.count
            guard count > 0 else { return path }
            let radius = min(rect.width, rect.height) / 2 - lineWidth / 2
            let center = CGPoint(x: rect.midX, y: rect.midY)
            if count == 1 {
                if seen[0] == wanted {
                    path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                               width: radius * 2, height: radius * 2))
                }
                return path
            }
            // the round caps reach half the width past each end of an arc, so
            // the break is measured between the caps, not between the ends
            let span = 2 * CGFloat.pi / CGFloat(count)
            let breakAngle = min(span * 0.6, (gap + lineWidth) / radius)
            for (index, flag) in seen.enumerated() where flag == wanted {
                let start = -CGFloat.pi / 2 + span * CGFloat(index) + breakAngle / 2
                let end = start + span - breakAngle
                // each arc is its own subpath: an arc added to a path with a
                // current point is joined to it by a line
                var arc = Path()
                arc.move(to: CGPoint(x: center.x + radius * cos(start),
                                     y: center.y + radius * sin(start)))
                arc.addArc(center: center, radius: radius,
                           startAngle: .radians(start), endAngle: .radians(end),
                           clockwise: false)
                path.addPath(arc)
            }
            return path
        }
    }
}
