import CoreGraphics

enum IslandPlacement {
    static let bottomMargin: CGFloat = 18

    static func origin(in visibleFrame: CGRect, size: CGSize) -> CGPoint {
        CGPoint(
            x: visibleFrame.origin.x + (visibleFrame.size.width - size.width) / 2,
            y: visibleFrame.origin.y + bottomMargin
        )
    }

    /// AppKit screen frames and `NSEvent.mouseLocation` share a bottom-left origin.
    static func frame(containing point: CGPoint, in frames: [CGRect]) -> CGRect? {
        frames.first { $0.contains(point) }
    }
}
