import AppKit

/// Narrow strip at the right edge of a pane: where the differences are in
/// the whole text, the current difference, and the part that is in view.
/// Clicking jumps to the difference nearest to that spot.
///
/// Positions are proportional to line numbers, not to wrapped heights, so
/// the strip never has to lay out the whole text.
@MainActor
final class OverviewBar: NSView {
    struct Mark: Equatable {
        let lines: Range<Int>
        let color: NSColor
    }

    static let width: CGFloat = 10

    var marks: [Mark] = [] { didSet { needsDisplay = true } }
    var lineCount = 1 { didSet { needsDisplay = true } }
    var currentRange: Range<Int>? { didSet { needsDisplay = true } }
    /// The lines in view, as continuous positions (line + fraction).
    var visibleRange: (top: Double, bottom: Double)? { didSet { needsDisplay = true } }
    /// Called with the line under a click.
    var onClick: ((Int) -> Void)?

    override var isFlipped: Bool { true }

    private func y(_ line: Double) -> CGFloat {
        CGFloat(line / Double(max(1, lineCount))) * bounds.height
    }

    override func draw(_ dirtyRect: NSRect) {
        if let visible = visibleRange {
            let top = y(visible.top)
            let rect = NSRect(x: 1, y: top, width: bounds.width - 2, height: max(6, y(visible.bottom) - top))
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
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
        click(atY: convert(event.locationInWindow, from: nil).y)
    }

    /// The line at a vertical position in the strip.
    func click(atY y: CGFloat) {
        let fraction = Double(min(max(0, y), bounds.height) / max(1, bounds.height))
        let line = Int(fraction * Double(lineCount))
        onClick?(min(max(0, line), max(0, lineCount - 1)))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
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
