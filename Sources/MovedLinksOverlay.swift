import AppKit

/// Transparent overlay spanning both panes that draws a connecting curve
/// between the old and new location of each moved block. Redraws on scroll
/// of either pane; passes all mouse events through.
///
/// Must be the topmost sibling in its superview (macOS 26 overdraws lower
/// siblings that share a backing layer).
@MainActor
final class MovedLinksOverlay: NSView {
    private weak var leftPane: PaneController?
    private weak var rightPane: PaneController?
    private var pairs: [MovedBlock] = []
    private var generations = (left: -1, right: -1)

    /// At most this many connecting lines are drawn.
    private static let maxLinks = 200
    /// Approximate half line height, to aim at the middle of the first line.
    private static let lineMidOffset: CGFloat = 8

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(left: PaneController, right: PaneController) {
        leftPane = left
        rightPane = right
        for pane in [left, right] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(paneScrolled),
                name: NSView.boundsDidChangeNotification,
                object: pane.scrollView.contentView
            )
        }
    }

    func update(pairs: [MovedBlock], leftGeneration: Int, rightGeneration: Int) {
        self.pairs = pairs
        generations = (leftGeneration, rightGeneration)
        needsDisplay = true
    }

    func clear() {
        pairs = []
        needsDisplay = true
    }

    @objc private func paneScrolled(_ notification: Notification) {
        if !pairs.isEmpty {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let left = leftPane, let right = rightPane,
              !pairs.isEmpty,
              left.generation == generations.left,
              right.generation == generations.right else { return }

        let leftFrame = convert(left.box.bounds, from: left.box)
        let rightFrame = convert(right.box.bounds, from: right.box)

        // Endpoint at a pane's inner edge for the middle of a block's first
        // line, clamped to the content area; clampedTo reports the direction.
        func endpoint(pane: PaneController, frame: CGRect, line: Int, x: CGFloat)
            -> (point: CGPoint, clampedTo: Int) {
            let top = frame.minY + PaneController.headerHeight
            let bottom = frame.maxY
            var y = top + pane.viewportY(forLine: line) + Self.lineMidOffset
            var clamped = 0
            if y < top { y = top; clamped = -1 }
            if y > bottom { y = bottom; clamped = 1 }
            return (CGPoint(x: x, y: y), clamped)
        }

        let stroke = NSColor.systemOrange.withAlphaComponent(0.8)
        stroke.setStroke()
        stroke.setFill()

        for pair in pairs.prefix(Self.maxLinks) {
            let start = endpoint(pane: left, frame: leftFrame,
                                 line: pair.left.lowerBound, x: leftFrame.maxX - 1)
            let end = endpoint(pane: right, frame: rightFrame,
                               line: pair.right.lowerBound, x: rightFrame.minX + 1)
            // Both endpoints clamped past the same edge: nothing visible.
            if start.clampedTo != 0, start.clampedTo == end.clampedTo { continue }

            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.move(to: start.point)
            let midX = (start.point.x + end.point.x) / 2
            path.curve(to: end.point,
                       controlPoint1: CGPoint(x: midX, y: start.point.y),
                       controlPoint2: CGPoint(x: midX, y: end.point.y))
            path.stroke()

            for tip in [start, end] where tip.clampedTo == 0 {
                let dot = NSRect(x: tip.point.x - 2.5, y: tip.point.y - 2.5, width: 5, height: 5)
                NSBezierPath(ovalIn: dot).fill()
            }
        }
    }
}
