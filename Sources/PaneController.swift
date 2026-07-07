import AppKit

/// Owns one editor pane: header, line-number sidebar, placeholder and a
/// plain-text NSTextView, assembled with manual frame layout.
///
/// No NSRulerView and no SwiftUI hosting — both interfered with TextKit 2
/// rendering on macOS 26 (text views stopped drawing entirely). Header and
/// placeholder are custom-drawn views for the same reason.
///
/// Diff highlights are applied as background-color attributes on the text
/// storage; they never change the characters and are wiped on the next edit.
@MainActor
final class PaneController: NSObject, NSTextViewDelegate {

    /// Pane container: lays out header, sidebar and scroll view manually.
    /// Note: NSSplitView manages its arranged subviews' layers, so this view
    /// must not draw anything itself — all drawing happens in subviews.
    final class PaneBox: NSView {
        weak var controller: PaneController?

        override func resizeSubviews(withOldSize oldSize: NSSize) {
            controller?.layoutBox()
        }
    }

    /// Header strip above the text area; draws its own background, hairline
    /// and title.
    final class HeaderView: NSView {
        var title: String = ""

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let label = title as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: 10, y: (bounds.height - size.height) / 2),
                       withAttributes: attributes)
        }
    }

    /// Grey hint shown while the pane is empty; lets all mouse events through.
    final class PlaceholderView: NSView {
        var text: String = ""

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            (text as NSString).draw(at: NSPoint(x: 9, y: 6), withAttributes: attributes)
        }
    }

    static let headerHeight: CGFloat = 30

    let box = PaneBox()
    let header = HeaderView()
    let scrollView: NSScrollView
    let textView: NSTextView
    let sidebar: LineNumberSidebar
    private let placeholder = PlaceholderView()

    /// Bumped on every edit; used to discard stale diff results.
    private(set) var generation = 0
    var onEdit: (() -> Void)?

    init(title: String, placeholderText: String) {
        scrollView = NSTextView.scrollableTextView()
        textView = scrollView.documentView as! NSTextView
        sidebar = LineNumberSidebar(textView: textView, scrollView: scrollView)
        super.init()

        assert(textView.textLayoutManager != nil, "text view must stay on TextKit 2")

        // Plain text only: pasted rich text, images and links are stripped,
        // and nothing is sent to system text services (spelling, substitution).
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFontPanel = false

        textView.delegate = self
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 6)

        box.controller = self
        header.title = title
        placeholder.text = placeholderText
        // The header must be the topmost subview: lower siblings sharing the
        // pane's backing layer get overdrawn on macOS 26.
        box.addSubview(sidebar)
        box.addSubview(scrollView)
        box.addSubview(placeholder)
        box.addSubview(header)

        sidebar.onThicknessChange = { [weak self] in self?.layoutBox() }

        // Redraw the sidebar when the pane scrolls.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    func layoutBox() {
        let bounds = box.bounds
        let contentHeight = max(0, bounds.height - Self.headerHeight)
        let sidebarWidth = sidebar.desiredThickness
        header.frame = NSRect(x: 0, y: contentHeight, width: bounds.width, height: Self.headerHeight)
        sidebar.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: contentHeight)
        scrollView.frame = NSRect(x: sidebarWidth, y: 0,
                                  width: max(0, bounds.width - sidebarWidth),
                                  height: contentHeight)
        placeholder.frame = NSRect(x: sidebarWidth, y: contentHeight - 30,
                                   width: max(0, bounds.width - sidebarWidth), height: 30)
        sidebar.needsDisplay = true
        header.needsDisplay = true
    }

    @objc private func scrolled(_ notification: Notification) {
        sidebar.needsDisplay = true
    }

    // MARK: - Text access

    var text: String { textView.string }
    var lineCount: Int { sidebar.lineCount }

    /// Programmatic replacement (swap, clear, tests). Runs the same
    /// bookkeeping as a user edit.
    func setText(_ newText: String) {
        textView.string = newText
        textDidChangeCommon()
    }

    func textDidChange(_ notification: Notification) {
        textDidChangeCommon()
    }

    private func textDidChangeCommon() {
        generation += 1
        sidebar.invalidateLineIndex()
        clearHighlights()
        placeholder.isHidden = !textView.string.isEmpty
        onEdit?()
    }

    // MARK: - Highlights

    func clearHighlights() {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
    }

    /// Line-level color for every changed line, stronger inline color for the
    /// character ranges that differ within paired lines.
    func applyHighlights(lines: Set<Int>, inline: [Int: [NSRange]], lineColor: NSColor, inlineColor: NSColor) {
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        if storage.length > 0 {
            storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
        }
        for line in lines {
            guard let lineRange = sidebar.characterRange(ofLine: line) else { continue }
            if lineRange.length > 0 {
                storage.addAttribute(.backgroundColor, value: lineColor, range: lineRange)
            }
            for sub in inline[line] ?? [] {
                let absolute = NSRange(location: lineRange.location + sub.location, length: sub.length)
                if NSMaxRange(absolute) <= NSMaxRange(lineRange) {
                    storage.addAttribute(.backgroundColor, value: inlineColor, range: absolute)
                }
            }
        }
        storage.endEditing()
    }

    // MARK: - Navigation

    func scrollToLine(_ line: Int) {
        guard let range = sidebar.characterRange(ofLine: line) else { return }
        textView.scrollRangeToVisible(NSRange(location: range.location, length: 0))
        sidebar.needsDisplay = true
    }
}
