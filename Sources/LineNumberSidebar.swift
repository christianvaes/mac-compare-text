import AppKit

/// Line-number sidebar drawn as a plain NSView next to the scroll view.
///
/// Deliberately NOT an NSRulerView: rulers hook into NSScrollView tiling,
/// which on macOS 26 proved to interfere with TextKit 2 viewport rendering
/// (text views stopped rendering entirely). This view only reads layout
/// positions from NSTextLayoutManager and draws digits; it cannot affect the
/// text view. TextKit 1 APIs (textView.layoutManager) must never be used
/// anywhere in this app — they downgrade the view to a compatibility mode
/// that renders nothing.
final class LineNumberSidebar: NSView {
    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    private var lineStarts: [Int] = [0]

    /// Called when the number of digits (and thus the desired width) changes.
    var onThicknessChange: (() -> Void)?
    private(set) var desiredThickness: CGFloat = 38

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        super.init(frame: .zero)
        invalidateLineIndex()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var lineCount: Int { lineStarts.count }

    /// Character range of a 0-based line, including its trailing newline.
    func characterRange(ofLine line: Int) -> NSRange? {
        guard let textView, line >= 0, line < lineStarts.count else { return nil }
        let length = (textView.string as NSString).length
        let start = lineStarts[line]
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : length
        return NSRange(location: start, length: end - start)
    }

    /// Rebuild the line index. O(n) over the text; called on every edit.
    func invalidateLineIndex() {
        guard let textView else { return }
        let ns = textView.string as NSString
        var starts: [Int] = [0]
        var search = 0
        while search < ns.length {
            let found = ns.range(of: "\n", range: NSRange(location: search, length: ns.length - search))
            if found.location == NSNotFound { break }
            starts.append(found.location + 1)
            search = found.location + 1
        }
        lineStarts = starts

        let digits = max(3, String(lineStarts.count).count)
        let thickness = CGFloat(digits) * 8 + 14
        if thickness != desiredThickness {
            desiredThickness = thickness
            onThicknessChange?()
        }
        needsDisplay = true
    }

    func lineIndex(forCharacter location: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The current difference: its lines get a marker bar and highlighted
    /// numbers. An empty range draws a marker line where lines were added on
    /// the other side.
    var currentRange: Range<Int>? {
        didSet { if currentRange != oldValue { needsDisplay = true } }
    }

    /// Fixed blue rather than the accent color, which can be orange (the
    /// color for moved lines) or another diff color.
    static let markerColor = NSColor.systemBlue

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, let scrollView,
              let layoutManager = textView.textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage else { return }

        (textView.backgroundColor).setFill()
        dirtyRect.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        let currentAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold),
            .foregroundColor: Self.markerColor,
        ]

        let visible = scrollView.documentVisibleRect
        // Where the text starts: the inset, plus any space above the first
        // line that keeps the panes side by side.
        let textTop = textView.textContainerOrigin.y
        var markerTop: CGFloat?
        var markerBottom: CGFloat?
        var insertionY: CGFloat?

        func drawNumber(_ line: Int, fragmentFrame frame: CGRect) {
            let y = frame.minY + textTop - visible.origin.y
            if let range = currentRange, range.isEmpty, range.lowerBound == line { insertionY = y }
            guard y + frame.height >= 0, y <= bounds.height else { return }
            let isCurrent = currentRange?.contains(line) == true
            if isCurrent {
                markerTop = min(markerTop ?? y, y)
                markerBottom = max(markerBottom ?? y + frame.height, y + frame.height)
            }
            let label = "\(line + 1)" as NSString
            let style = isCurrent ? currentAttributes : attributes
            let size = label.size(withAttributes: style)
            let point = NSPoint(
                x: bounds.width - size.width - 6,
                y: y + (min(frame.height, 18) - size.height) / 2
            )
            label.draw(at: point, withAttributes: style)
        }

        let topPoint = CGPoint(x: 0, y: max(0, visible.origin.y - textTop))
        let startFragment = layoutManager.textLayoutFragment(for: topPoint)
        let docStart = contentStorage.documentRange.location
        var lastLine = -1
        var lastFrame: CGRect = .zero

        layoutManager.enumerateTextLayoutFragments(
            from: startFragment?.rangeInElement.location,
            options: [.ensuresLayout]
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + textTop - visible.origin.y > bounds.height { return false }
            let offset = contentStorage.offset(from: docStart, to: fragment.rangeInElement.location)
            let line = lineIndex(forCharacter: offset)
            drawNumber(line, fragmentFrame: frame)
            lastLine = line
            lastFrame = frame
            return true
        }

        // Trailing empty line (text ends in "\n") has no fragment; draw its
        // number below the last one. Empty document: draw "1".
        let textLength = (textView.string as NSString).length
        if textLength == 0 {
            drawNumber(0, fragmentFrame: CGRect(x: 0, y: 0, width: 10, height: 16))
        } else if lastLine == lineStarts.count - 2, lineStarts[lineStarts.count - 1] == textLength {
            drawNumber(lineStarts.count - 1,
                       fragmentFrame: CGRect(x: 0, y: lastFrame.maxY, width: 10, height: lastFrame.height))
        }
        // Added at the very end on the other side: below the last line.
        if let range = currentRange, range.isEmpty, range.lowerBound >= lineStarts.count, lastLine >= 0 {
            insertionY = lastFrame.maxY + textTop - visible.origin.y
        }

        Self.markerColor.setFill()
        if let top = markerTop, let bottom = markerBottom {
            let clippedTop = max(0, top + 1)
            let clippedBottom = min(bounds.height, bottom - 1)
            if clippedBottom > clippedTop {
                NSBezierPath(roundedRect: NSRect(x: 2, y: clippedTop, width: 3, height: clippedBottom - clippedTop),
                             xRadius: 1.5, yRadius: 1.5).fill()
            }
        }
        if let y = insertionY, y >= -2, y <= bounds.height + 2 {
            NSBezierPath(roundedRect: NSRect(x: 2, y: y - 1.5, width: bounds.width - 6, height: 3),
                         xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
