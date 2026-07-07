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

    private func lineIndex(forCharacter location: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, let scrollView,
              let layoutManager = textView.textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage else { return }

        (textView.backgroundColor).setFill()
        dirtyRect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        let visible = scrollView.documentVisibleRect
        let inset = textView.textContainerInset

        func drawNumber(_ line: Int, fragmentFrame frame: CGRect) {
            let y = frame.minY + inset.height - visible.origin.y
            guard y + frame.height >= 0, y <= bounds.height else { return }
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            let point = NSPoint(
                x: bounds.width - size.width - 6,
                y: y + (min(frame.height, 18) - size.height) / 2
            )
            label.draw(at: point, withAttributes: attributes)
        }

        let topPoint = CGPoint(x: 0, y: max(0, visible.origin.y - inset.height))
        let startFragment = layoutManager.textLayoutFragment(for: topPoint)
        let docStart = contentStorage.documentRange.location
        var lastLine = -1
        var lastFrame: CGRect = .zero

        layoutManager.enumerateTextLayoutFragments(
            from: startFragment?.rangeInElement.location,
            options: [.ensuresLayout]
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + inset.height - visible.origin.y > bounds.height { return false }
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
    }
}
