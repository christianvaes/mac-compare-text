import AppKit

/// The pane's vertical scrollbar, with the differences on its track: where
/// they are in the whole text, the current one, and a thumb for the part in
/// view. Drag the thumb to scroll, click a mark to go to that difference,
/// click the empty track to scroll there.
///
/// It replaces the system scroller rather than sitting next to it, and maps
/// like one: positions are fractions of the document height. After a
/// comparison both documents are padded to the same height, so the two
/// strips show the same thumb and matching marks side by side. The left pane
/// has it on its left edge, so the strips sit on the outside and leave the
/// middle to the moved-block ribbons.
@MainActor
final class OverviewBar: NSView {
    struct Mark: Equatable {
        let lines: Range<Int>
        let color: NSColor
        /// Top and bottom as fractions of the document height.
        var span: ClosedRange<CGFloat> = 0...0
    }

    static let width: CGFloat = 12
    private static let minimumThumbHeight: CGFloat = 18
    /// How close (in points) a click must be to a mark to select it.
    private static let markHitSlop: CGFloat = 4

    var marks: [Mark] = [] { didSet { needsDisplay = true } }
    var currentRange: Range<Int>? { didSet { needsDisplay = true } }
    /// Where the current difference is, as fractions of the document height.
    var currentSpan: ClosedRange<CGFloat>? { didSet { needsDisplay = true } }
    /// The part in view, as fractions of the document height.
    var visibleSpan: ClosedRange<CGFloat>? { didSet { needsDisplay = true } }
    /// Called with the first line of the mark that was clicked.
    var onClick: ((Int) -> Void)?
    /// Called with how far to scroll: 0 is the top, 1 the bottom.
    var onScroll: ((CGFloat) -> Void)?

    /// Where in the thumb the pointer grabbed it, while dragging.
    private var dragOffset: CGFloat?

    override var isFlipped: Bool { true }

    private func y(_ fraction: CGFloat) -> CGFloat { fraction * bounds.height }

    /// The thumb: the part in view, at least `minimumThumbHeight` tall. Like
    /// a system scroller, its free travel (track minus thumb) maps linearly
    /// onto the scroll range, so it reaches both ends and follows the pointer
    /// exactly while dragging.
    var thumbRect: NSRect? {
        guard let visible = visibleSpan, bounds.height > 0 else { return nil }
        let height = thumbHeight(visible)
        let scrollable = 1 - (visible.upperBound - visible.lowerBound)
        let progress = scrollable > 0 ? min(1, max(0, visible.lowerBound / scrollable)) : 0
        return NSRect(x: 1, y: progress * (bounds.height - height), width: bounds.width - 2, height: height)
    }

    private func thumbHeight(_ visible: ClosedRange<CGFloat>) -> CGFloat {
        min(bounds.height, max(Self.minimumThumbHeight, (visible.upperBound - visible.lowerBound) * bounds.height))
    }

    /// The thumb, unless the whole text fits and there is nothing to scroll
    /// (then, like the system scroller, it is not shown).
    private var shownThumb: NSRect? {
        guard let thumb = thumbRect, thumb.height < bounds.height - 0.5 else { return nil }
        return thumb
    }

    override func draw(_ dirtyRect: NSRect) {
        if let thumb = shownThumb {
            NSColor.labelColor.withAlphaComponent(dragOffset == nil ? 0.16 : 0.26).setFill()
            NSBezierPath(roundedRect: thumb, xRadius: 3, yRadius: 3).fill()
        }
        for mark in marks {
            let top = y(mark.span.lowerBound)
            mark.color.setFill()
            NSRect(x: 2, y: top, width: bounds.width - 4, height: max(2, y(mark.span.upperBound) - top)).fill()
        }
        if let current = currentSpan {
            let top = y(current.lowerBound)
            LineNumberSidebar.markerColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: top - 1, width: bounds.width,
                                             height: max(3, y(current.upperBound) - top + 2)),
                         xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        press(atY: convert(event.locationInWindow, from: nil).y)
    }

    override func mouseDragged(with event: NSEvent) {
        drag(toY: convert(event.locationInWindow, from: nil).y)
    }

    override func mouseUp(with event: NSEvent) {
        endDrag()
    }

    /// Press on the strip: grab the thumb, select a mark, or scroll the
    /// pressed spot into the middle of the view and keep dragging from there.
    func press(atY y: CGFloat) {
        if let thumb = shownThumb, y >= thumb.minY, y <= thumb.maxY {
            dragOffset = y - thumb.minY
            needsDisplay = true
            return
        }
        if let line = markLine(near: y) {
            onClick?(line)
            return
        }
        guard let thumb = shownThumb else { return }
        dragOffset = thumb.height / 2
        drag(toY: y)
    }

    func drag(toY y: CGFloat) {
        guard let dragOffset, let thumb = thumbRect else { return }
        let travel = bounds.height - thumb.height
        guard travel > 0 else { return }
        onScroll?(min(1, max(0, (y - dragOffset) / travel)))
    }

    func endDrag() {
        dragOffset = nil
        needsDisplay = true
    }

    /// The first line of the mark at (or within a few points of) a position.
    private func markLine(near position: CGFloat) -> Int? {
        let hits = marks.filter { mark in
            let top = y(mark.span.lowerBound) - Self.markHitSlop
            let bottom = max(y(mark.span.upperBound), top + 2) + Self.markHitSlop
            return position >= top && position <= bottom
        }
        let center = { (mark: Mark) in abs(self.y((mark.span.lowerBound + mark.span.upperBound) / 2) - position) }
        return hits.min { center($0) < center($1) }?.lines.lowerBound
    }

    /// Consecutive lines of one kind merged into marks.
    static func marks(for lines: Set<Int>, color: NSColor) -> [Mark] {
        var result: [Mark] = []
        var start: Int?
        var previous = -2
        for line in lines.sorted() {
            if line != previous + 1 {
                if let start { result.append(Mark(lines: start..<(previous + 1), color: color)) }
                start = line
            }
            previous = line
        }
        if let start { result.append(Mark(lines: start..<(previous + 1), color: color)) }
        return result
    }
}
