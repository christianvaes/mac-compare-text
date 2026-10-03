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

    /// At most this many connector ribbons are drawn.
    private static let maxLinks = 200

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

    /// Vertical extent of a block at a pane's inner edge, clamped to the
    /// visible content area. clampedTo: -1 fully above, 1 fully below, 0 (at
    /// least partially) visible.
    private struct BlockEdge {
        var top: CGFloat
        var bottom: CGFloat
        var clampedTo: Int
    }

    private func blockEdge(pane: PaneController, lines: Range<Int>) -> BlockEdge {
        let content = convert(pane.scrollView.bounds, from: pane.scrollView)
        let contentTop = content.minY
        let contentBottom = content.maxY
        let rawTop = contentTop + pane.viewportY(forLine: lines.lowerBound)
        let rawBottom = contentTop + pane.viewportY(forLine: lines.upperBound)
        var clamped = 0
        if rawBottom <= contentTop { clamped = -1 }
        if rawTop >= contentBottom { clamped = 1 }
        return BlockEdge(
            top: min(max(rawTop, contentTop), contentBottom),
            bottom: min(max(rawBottom, contentTop), contentBottom),
            clampedTo: clamped
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let left = leftPane, let right = rightPane,
              !pairs.isEmpty,
              left.generation == generations.left,
              right.generation == generations.right else { return }

        // Ribbons run between the facing edges of the two cards.
        let gutterLeft = convert(left.card.bounds, from: left.card).maxX
        let gutterRight = convert(right.card.bounds, from: right.card).minX
        let midX = (gutterLeft + gutterRight) / 2

        let fill = NSColor.systemOrange.withAlphaComponent(0.2)
        let stroke = NSColor.systemOrange.withAlphaComponent(0.55)

        for pair in pairs.prefix(Self.maxLinks) {
            let leftEdge = blockEdge(pane: left, lines: pair.left)
            let rightEdge = blockEdge(pane: right, lines: pair.right)
            // Both blocks scrolled past the same edge: nothing to connect.
            if leftEdge.clampedTo != 0, leftEdge.clampedTo == rightEdge.clampedTo { continue }

            // Ribbon spanning the gutter: the block's full height on the
            // left flowing into its full height on the right.
            let ribbon = NSBezierPath()
            ribbon.move(to: CGPoint(x: gutterLeft, y: leftEdge.top))
            ribbon.curve(to: CGPoint(x: gutterRight, y: rightEdge.top),
                         controlPoint1: CGPoint(x: midX, y: leftEdge.top),
                         controlPoint2: CGPoint(x: midX, y: rightEdge.top))
            ribbon.line(to: CGPoint(x: gutterRight, y: max(rightEdge.bottom, rightEdge.top + 2)))
            ribbon.curve(to: CGPoint(x: gutterLeft, y: max(leftEdge.bottom, leftEdge.top + 2)),
                         controlPoint1: CGPoint(x: midX, y: max(rightEdge.bottom, rightEdge.top + 2)),
                         controlPoint2: CGPoint(x: midX, y: max(leftEdge.bottom, leftEdge.top + 2)))
            ribbon.close()
            fill.setFill()
            ribbon.fill()

            for (fromY, toY) in [(leftEdge.top, rightEdge.top),
                                 (max(leftEdge.bottom, leftEdge.top + 2), max(rightEdge.bottom, rightEdge.top + 2))] {
                let edge = NSBezierPath()
                edge.lineWidth = 1
                edge.move(to: CGPoint(x: gutterLeft, y: fromY))
                edge.curve(to: CGPoint(x: gutterRight, y: toY),
                           controlPoint1: CGPoint(x: midX, y: fromY),
                           controlPoint2: CGPoint(x: midX, y: toY))
                stroke.setStroke()
                edge.stroke()
            }
        }
    }
}
