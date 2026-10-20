import AppKit

/// The pane's vertical scrollbar, with the differences on its track: where
/// they are in the whole text, the current one, and a thumb for the part in
/// view. Drag the thumb to scroll, click a mark to go to that difference,
/// click the empty track to scroll there.
///
/// It replaces the system scroller rather than sitting next to it: the two
/// map differently (wrapped heights versus lines), so side by side their
/// thumbs disagree. Positions are proportional to line numbers, so the
/// strip never has to lay out the whole text.
@MainActor
final class OverviewBar: NSView {
    struct Mark: Equatable {
        let lines: Range<Int>
        let color: NSColor
    }

    static let width: CGFloat = 12
    private static let minimumThumbHeight: CGFloat = 18
    /// How close (in points) a click must be to a mark to select it.
    private static let markHitSlop: CGFloat = 4

    var marks: [Mark] = [] { didSet { needsDisplay = true } }
    var lineCount = 1 { didSet { needsDisplay = true } }
    var currentRange: Range<Int>? { didSet { needsDisplay = true } }
    /// The lines in view, as continuous positions (line + fraction).
    var visibleRange: (top: Double, bottom: Double)? { didSet { needsDisplay = true } }
    /// Called with a line of the mark that was clicked.
    var onClick: ((Int) -> Void)?
    /// Called with the line position to scroll to the top of the view
    /// (`lineCount` for the very end).
    var onScroll: ((Double) -> Void)?

    /// Where in the thumb the pointer grabbed it, while dragging.
    private var dragOffset: CGFloat?

    override var isFlipped: Bool { true }

    private func y(_ line: Double) -> CGFloat {
        CGFloat(line / Double(max(1, lineCount))) * bounds.height
    }

    /// The thumb: the lines in view, at least `minimumThumbHeight` tall.
    /// Like a system scroller, its free travel (track minus thumb) maps
    /// linearly onto the scrollable lines, so a taller minimum thumb still
    /// reaches both ends and follows the pointer exactly while dragging.
    var thumbRect: NSRect? {
        guard let visible = visibleRange, bounds.height > 0 else { return nil }
        let height = thumbHeight(visible)
        let maxTop = scrollableLines(visible)
        let top = maxTop > 0 ? CGFloat(min(1, max(0, visible.top / maxTop))) * (bounds.height - height) : 0
        return NSRect(x: 1, y: top, width: bounds.width - 2, height: height)
    }

    /// The thumb, unless the whole text fits and there is nothing to scroll
    /// (then, like the system scroller, it is not shown).
    private var shownThumb: NSRect? {
        guard let thumb = thumbRect, thumb.height < bounds.height - 0.5 else { return nil }
        return thumb
    }

    private func thumbHeight(_ visible: (top: Double, bottom: Double)) -> CGFloat {
        let proportional = CGFloat((visible.bottom - visible.top) / Double(max(1, lineCount))) * bounds.height
        return min(bounds.height, max(Self.minimumThumbHeight, proportional))
    }

    /// The highest top line: everything above the last screenful.
    private func scrollableLines(_ visible: (top: Double, bottom: Double)) -> Double {
        max(0, Double(lineCount) - (visible.bottom - visible.top))
    }

    override func draw(_ dirtyRect: NSRect) {
        if let thumb = shownThumb {
            NSColor.labelColor.withAlphaComponent(dragOffset == nil ? 0.16 : 0.26).setFill()
            NSBezierPath(roundedRect: thumb, xRadius: 3, yRadius: 3).fill()
        }
        for mark in marks {
            let top = y(Double(mark.lines.lowerBound))
            mark.color.setFill()
            NSRect(x: 2, y: top, width: bounds.width - 4,
                   height: max(2, y(Double(mark.lines.upperBound)) - top)).fill()
        }
        if let current = currentRange {
            let top = y(Double(current.lowerBound))
            LineNumberSidebar.markerColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: top - 1, width: bounds.width,
                                             height: max(3, y(Double(current.upperBound)) - top + 2)),
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
        guard let dragOffset, let visible = visibleRange, bounds.height > 0 else { return }
        let travel = bounds.height - thumbHeight(visible)
        guard travel > 0 else { return }
        let fraction = Double(min(1, max(0, (y - dragOffset) / travel)))
        // At the very end, ask for the last line so the pane scrolls fully
        // down (the lines in view differ in height there).
        onScroll?(fraction >= 1 ? Double(lineCount) : fraction * scrollableLines(visible))
    }

    func endDrag() {
        dragOffset = nil
        needsDisplay = true
    }

    /// A line of the mark at (or within a few points of) a position.
    private func markLine(near position: CGFloat) -> Int? {
        let hits = marks.filter { mark in
            let top = y(Double(mark.lines.lowerBound)) - Self.markHitSlop
            let bottom = max(y(Double(mark.lines.upperBound)), top + 2) + Self.markHitSlop
            return position >= top && position <= bottom
        }
        let center = { (mark: Mark) in abs(self.y(Double(mark.lines.lowerBound + mark.lines.upperBound) / 2) - position) }
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
