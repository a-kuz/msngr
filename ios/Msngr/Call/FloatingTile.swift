import SwiftUI

/// A tile that floats over the app: it is dragged anywhere inside its
/// container, released to the nearer side, and pinched to change its size. The
/// minimized call and the self-view of a video call both ride on it.
struct FloatingTile<Content: View>: View {
    /// The corner the tile stands in before it is first dragged.
    var start: UnitPoint = .topTrailing
    /// The inset the tile keeps from the edges it snaps to.
    var margin: CGFloat = 12
    /// Whether a pinch changes the size.
    var resizable: Bool = true
    @ViewBuilder var content: () -> Content

    /// How far a pinch may take the tile from the size it asks for.
    private static var minScale: CGFloat { 0.7 }
    private static var maxScale: CGFloat { 1.8 }

    @State private var center: CGPoint?
    @State private var contentSize: CGSize = .zero
    @State private var scale: CGFloat = 1
    @GestureState private var drag: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let live = Self.clamped(scale * pinch)
            let size = CGSize(width: contentSize.width * live,
                              height: contentSize.height * live)
            let bounds = geo.frame(in: .local)
            let home = home(in: bounds, size: size)
            let base = center ?? home
            let placed = clamp(CGPoint(x: base.x + drag.width, y: base.y + drag.height),
                               in: bounds, size: size)
            content()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { contentSize = $0 }
                .scaleEffect(live)
                .position(placed)
                // ahead of the content's own gestures: the tile carries a button,
                // and a button claims every touch inside it. The threshold keeps
                // the tap for the button and takes only a real drag
                .highPriorityGesture(
                    DragGesture(minimumDistance: 8)
                        .updating($drag) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            let moved = CGPoint(x: base.x + value.translation.width,
                                                y: base.y + value.translation.height)
                            withAnimation(Theme.spring) {
                                center = snap(moved, in: bounds, size: size)
                            }
                        }
                )
                .highPriorityGesture(
                    MagnifyGesture()
                        .updating($pinch) { value, state, _ in
                            state = resizable ? value.magnification : 1
                        }
                        .onEnded { value in
                            guard resizable else { return }
                            let grown = Self.clamped(scale * value.magnification)
                            let size = CGSize(width: contentSize.width * grown,
                                              height: contentSize.height * grown)
                            withAnimation(Theme.spring) {
                                scale = grown
                                center = clamp(base, in: bounds, size: size)
                            }
                        }
                )
        }
    }

    private static func clamped(_ scale: CGFloat) -> CGFloat {
        FloatingTilePlacement.clamped(scale)
    }

    private func home(in bounds: CGRect, size: CGSize) -> CGPoint {
        FloatingTilePlacement.home(start: start, margin: margin, in: bounds, size: size)
    }

    private func clamp(_ point: CGPoint, in bounds: CGRect, size: CGSize) -> CGPoint {
        FloatingTilePlacement.clamp(point, margin: margin, in: bounds, size: size)
    }

    private func snap(_ point: CGPoint, in bounds: CGRect, size: CGSize) -> CGPoint {
        FloatingTilePlacement.snap(point, margin: margin, in: bounds, size: size)
    }
}

/// Where a floating tile stands: the arithmetic of its corner, its bounds and
/// the side it is released to, apart from the view that draws it.
enum FloatingTilePlacement {
    /// How far a pinch may take the tile from the size it asks for.
    static let minScale: CGFloat = 0.7
    static let maxScale: CGFloat = 1.8

    static func clamped(_ scale: CGFloat) -> CGFloat {
        min(maxScale, max(minScale, scale))
    }

    /// Where the tile stands before it is dragged: its starting corner, inset
    /// by the margin.
    static func home(start: UnitPoint, margin: CGFloat,
                     in bounds: CGRect, size: CGSize) -> CGPoint {
        let x = bounds.minX + margin + size.width / 2
            + (bounds.width - size.width - margin * 2) * start.x
        let y = bounds.minY + margin + size.height / 2
            + (bounds.height - size.height - margin * 2) * start.y
        return CGPoint(x: x, y: y)
    }

    static func clamp(_ point: CGPoint, margin: CGFloat,
                      in bounds: CGRect, size: CGSize) -> CGPoint {
        let x = min(max(point.x, bounds.minX + margin + size.width / 2),
                    bounds.maxX - margin - size.width / 2)
        let y = min(max(point.y, bounds.minY + margin + size.height / 2),
                    bounds.maxY - margin - size.height / 2)
        return CGPoint(x: x, y: y)
    }

    /// A released tile goes to the side it is nearer to and keeps the height it
    /// was left at, the way every floating call window behaves.
    static func snap(_ point: CGPoint, margin: CGFloat,
                     in bounds: CGRect, size: CGSize) -> CGPoint {
        let inside = clamp(point, margin: margin, in: bounds, size: size)
        let left = bounds.minX + margin + size.width / 2
        let right = bounds.maxX - margin - size.width / 2
        return CGPoint(x: inside.x < bounds.midX ? left : right, y: inside.y)
    }
}
