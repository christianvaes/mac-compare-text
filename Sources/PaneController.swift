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

    /// Caption above the card: title on the left, line count on the right.
    final class HeaderView: NSView {
        var title: String = ""
        var detail: String = "" { didSet { needsDisplay = true } }

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let titleSize = (title as NSString).size(withAttributes: titleAttributes)
            (title as NSString).draw(at: NSPoint(x: 4, y: (bounds.height - titleSize.height) / 2 + 2),
                                     withAttributes: titleAttributes)

            guard !detail.isEmpty else { return }
            let detailAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            let detailSize = (detail as NSString).size(withAttributes: detailAttributes)
            (detail as NSString).draw(
                at: NSPoint(x: bounds.width - detailSize.width - 4,
                            y: (bounds.height - detailSize.height) / 2 + 2),
                withAttributes: detailAttributes
            )
        }
    }

    /// Rounded, bordered surface that holds the line numbers and the text.
    final class CardView: NSView {
        static let cornerRadius: CGFloat = 9

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.cornerRadius = Self.cornerRadius
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = true
            layer?.borderWidth = 1
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override var wantsUpdateLayer: Bool { true }

        // Dynamic colors resolve against the current appearance here, so the
        // card follows light/dark switches.
        override func updateLayer() {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
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
    let card = CardView()
    /// Margin between the card and the pane edges (window edge side).
    var outerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    let scrollView: NSScrollView
    let textView: NSTextView
    let sidebar: LineNumberSidebar
    private let placeholder = PlaceholderView()
    let overview = OverviewBar()

    /// Bumped on every edit; used to discard stale diff results.
    private(set) var generation = 0
    var onEdit: (() -> Void)?
    /// Called with the URLs of files dropped on the text.
    var onFilesDropped: (([URL]) -> Void)?
    /// Called after text was pasted or dropped into the pane.
    var onPaste: (() -> Void)?
    /// Called with the line clicked in the overview strip.
    var onOverviewClick: ((Int) -> Void)?

    private let defaultTitle: String
    /// The file the text was loaded from, valid while the text is unedited.
    private var loadedFile: (name: String, generation: Int)?

    /// Whether the overview scrollbar sits at the card's leading edge. The
    /// left pane mirrors the right one, so both scrollbars are on the outside
    /// and the moved-block ribbons in the middle touch the text directly.
    private let overviewOnLeadingEdge: Bool

    init(title: String, placeholderText: String, overviewOnLeadingEdge: Bool = false) {
        self.overviewOnLeadingEdge = overviewOnLeadingEdge
        // The subclass is created by the standard TextKit 2 setup, so the
        // text view itself is configured exactly as before.
        scrollView = FileDropTextView.scrollableTextView()
        textView = scrollView.documentView as! FileDropTextView
        sidebar = LineNumberSidebar(textView: textView, scrollView: scrollView)
        defaultTitle = title
        super.init()
        (textView as? FileDropTextView)?.onFileDrop = { [weak self] urls in
            self?.onFilesDropped?(urls)
        }
        (textView as? FileDropTextView)?.onPaste = { [weak self] in
            self?.onPaste?()
        }

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
        textView.textContainerInset = Self.textInset

        box.controller = self
        header.title = title
        placeholder.text = placeholderText
        // Draw-once views (header, placeholder) must be the topmost subview
        // of their parent: lower siblings sharing a backing layer get
        // overdrawn on macOS 26.
        card.addSubview(sidebar)
        card.addSubview(scrollView)
        card.addSubview(overview)
        card.addSubview(placeholder)
        overview.onClick = { [weak self] line in self?.onOverviewClick?(line) }
        overview.onScroll = { [weak self] progress in
            guard let self else { return }
            self.scroll(toDocumentY: progress * max(0, self.documentHeight - self.scrollView.contentView.bounds.height))
        }
        // The overview strip is the vertical scrollbar; see OverviewBar.
        scrollView.hasVerticalScroller = false
        box.addSubview(card)
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
        // The thumb also changes when the text grows or shrinks.
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrolled),
            name: NSView.frameDidChangeNotification,
            object: textView
        )
    }

    func layoutBox() {
        let bounds = box.bounds
        defer {
            if scrollView.contentSize.width != lastTextWidth {
                lastTextWidth = scrollView.contentSize.width
                onTextWidthChange?()
            }
        }
        let cardFrame = NSRect(
            x: outerInsets.left,
            y: outerInsets.bottom,
            width: max(0, bounds.width - outerInsets.left - outerInsets.right),
            height: max(0, bounds.height - Self.headerHeight - outerInsets.bottom)
        )
        card.frame = cardFrame
        header.frame = NSRect(x: cardFrame.minX, y: cardFrame.maxY,
                              width: cardFrame.width, height: Self.headerHeight)

        let contentHeight = cardFrame.height
        let sidebarWidth = sidebar.desiredThickness
        let overviewWidth = OverviewBar.width
        // [overview][numbers][text] on the left pane, [numbers][text][overview]
        // on the right one.
        let sidebarX = overviewOnLeadingEdge ? overviewWidth : 0
        let textX = sidebarX + sidebarWidth
        let textWidth = max(0, cardFrame.width - sidebarWidth - overviewWidth)
        sidebar.frame = NSRect(x: sidebarX, y: 0, width: sidebarWidth, height: contentHeight)
        scrollView.frame = NSRect(x: textX, y: 0, width: textWidth, height: contentHeight)
        overview.frame = NSRect(x: overviewOnLeadingEdge ? 0 : max(0, cardFrame.width - overviewWidth), y: 0,
                                width: overviewWidth, height: contentHeight)
        placeholder.frame = NSRect(x: textX, y: contentHeight - 30, width: textWidth, height: 30)
        sidebar.needsDisplay = true
        header.needsDisplay = true
        updateOverviewViewport()
    }

    @objc private func scrolled(_ notification: Notification) {
        sidebar.needsDisplay = true
        updateOverviewViewport()
    }

    private func updateOverviewViewport() {
        let height = documentHeight
        guard height > 0 else { overview.visibleSpan = nil; return }
        let visible = scrollView.documentVisibleRect
        overview.visibleSpan = min(1, visible.minY / height)...min(1, max(visible.minY, visible.maxY) / height)
    }

    /// Lines as fractions of the document height, for the overview strip.
    private func span(ofLines lines: Range<Int>) -> ClosedRange<CGFloat> {
        let height = max(1, documentHeight)
        let top = documentY(atPosition: Double(lines.lowerBound)) / height
        return top...max(top, documentY(atPosition: Double(lines.upperBound)) / height)
    }

    /// Places the overview marks where their lines are now; call after
    /// heights changed (padding, wrapping).
    func refreshOverviewPositions() {
        overview.marks = overview.marks.map { mark in
            var mark = mark
            mark.span = span(ofLines: mark.lines)
            return mark
        }
        overview.currentSpan = overview.currentRange.map(span(ofLines:))
        updateOverviewViewport()
    }

    // MARK: - Text access

    var text: String { textView.string }
    var lineCount: Int { sidebar.lineCount }

    /// Programmatic replacement (swap, clear, tests). Runs the same
    /// bookkeeping as a user edit; `fileName` labels the pane until the
    /// text is edited.
    func setText(_ newText: String, fileName: String? = nil) {
        textView.string = newText
        textDidChangeCommon()
        markLoaded(from: fileName)
    }

    /// Replaces the whole text like a paste over a full selection: one undo
    /// step brings the previous text back (and redo the new one).
    ///
    /// The undo is registered here rather than by the text view: undoing a
    /// direct text-storage replacement through the text view does not report
    /// a text change, which would leave line numbers and highlights stale.
    func replaceAllUndoably(with newText: String, fileName: String?) {
        // Typing just before stays its own undo step.
        textView.breakUndoCoalescing()
        let previousText = textView.string
        let previousName = currentFileName
        let undoManager = textView.undoManager
        undoManager?.registerUndo(withTarget: self) { pane in
            MainActor.assumeIsolated {
                pane.replaceAllUndoably(with: previousText, fileName: previousName)
            }
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: textView.font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ]
        let full = NSRange(location: 0, length: (previousText as NSString).length)
        undoManager?.disableUndoRegistration()
        textView.textStorage?.replaceCharacters(in: full, with: NSAttributedString(string: newText, attributes: attributes))
        undoManager?.enableUndoRegistration()
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        markLoaded(from: fileName)
    }

    /// The name of the file the text came from, if it is still unedited.
    var currentFileName: String? {
        guard let loadedFile, loadedFile.generation == generation else { return nil }
        return loadedFile.name
    }

    private func markLoaded(from fileName: String?) {
        loadedFile = fileName.map { ($0, generation) }
        updateTitle()
    }

    private func updateTitle() {
        header.title = currentFileName ?? defaultTitle
        header.needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        textDidChangeCommon()
    }

    private func textDidChangeCommon() {
        generation += 1
        sidebar.invalidateLineIndex()
        clearHighlights()
        placeholder.isHidden = !textView.string.isEmpty
        header.detail = textView.string.isEmpty ? "" : L10n.lineCount(sidebar.lineCount)
        sidebar.currentRange = nil
        updateTitle()
        onEdit?()
    }

    // MARK: - Highlights

    func clearHighlights() {
        clearPadding()
        overview.marks = []
        overview.currentRange = nil
        overview.currentSpan = nil
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
    }

    /// Line-level color for every changed line, stronger inline color for the
    /// character ranges that differ within paired lines; moved lines get the
    /// moved color, plus inline emphasis where the block was edited.
    func applyHighlights(lines: Set<Int>, inline: [Int: [NSRange]], lineColor: NSColor, inlineColor: NSColor,
                         movedLines: Set<Int> = [], movedColor: NSColor? = nil) {
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        if storage.length > 0 {
            storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
        }
        if let movedColor {
            for line in movedLines {
                guard let range = sidebar.characterRange(ofLine: line), range.length > 0 else { continue }
                storage.addAttribute(.backgroundColor, value: movedColor, range: range)
                // A block can move and be edited on the way: emphasize the
                // edits within the moved line.
                for sub in inline[line] ?? [] {
                    let absolute = NSRange(location: range.location + sub.location, length: sub.length)
                    if NSMaxRange(absolute) <= NSMaxRange(range) {
                        storage.addAttribute(.backgroundColor, value: inlineColor, range: absolute)
                    }
                }
            }
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

        let strong = { (color: NSColor) in color.withAlphaComponent(0.85) }
        var marks = OverviewBar.marks(for: movedLines, color: strong(movedColor ?? .systemOrange))
        marks += OverviewBar.marks(for: lines, color: strong(lineColor))
        overview.marks = marks
        refreshOverviewPositions()
    }

    // MARK: - Navigation

    func scrollToLine(_ line: Int) {
        guard let range = sidebar.characterRange(ofLine: line) else { return }
        textView.scrollRangeToVisible(NSRange(location: range.location, length: 0))
        sidebar.needsDisplay = true
    }

    /// Marks the lines of the current difference (nil clears the marker).
    func setCurrentDifference(_ range: Range<Int>?) {
        sidebar.currentRange = range
        overview.currentRange = range
        overview.currentSpan = range.map(span(ofLines:))
    }

    /// Scrolls so the line sits a third down the viewport, or as close as
    /// the document allows. Unlike scrolling it merely into view, this
    /// moves on every call, so stepping through differences that are all
    /// on screen visibly goes from one to the next.
    func reveal(line: Int) {
        guard sidebar.lineCount > 0 else { return }
        let target = min(max(0, line), sidebar.lineCount - 1)
        var lineTop = textView.frame.height
        if let frame = layoutFragmentFrame(ofLine: target) {
            lineTop = frame.minY + textView.textContainerOrigin.y
        }
        let clipHeight = scrollView.contentView.bounds.height
        let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clipHeight)
        let targetY = min(max(0, lineTop - clipHeight / 3), maxY)
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.documentVisibleRect.origin.x, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        sidebar.needsDisplay = true
    }

    // MARK: - Position mapping (synchronized scrolling, moved-block links)

    /// Logical position (0-based line + fraction within it) at the top of
    /// the visible viewport. nil when layout cannot resolve it (empty doc).
    func topVerticalPosition() -> Double? {
        verticalPosition(atViewportY: 0)
    }

    /// Logical position at a height within the viewport (0 = its top).
    func verticalPosition(atViewportY viewportY: CGFloat) -> Double? {
        guard let layoutManager = textView.textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage else { return nil }
        let visibleY = scrollView.documentVisibleRect.origin.y + viewportY
        let yInText = max(0, visibleY - textView.textContainerOrigin.y)
        guard let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: yInText)) else { return nil }
        let offset = contentStorage.offset(from: contentStorage.documentRange.location,
                                           to: fragment.rangeInElement.location)
        let line = sidebar.lineIndex(forCharacter: offset)
        let frame = fragment.layoutFragmentFrame
        let fraction = frame.height > 0 ? Double((yInText - frame.minY) / frame.height) : 0
        return Double(line) + max(0, min(1, fraction))
    }

    /// Height of the whole document (text plus insets).
    var documentHeight: CGFloat { textView.frame.height }

    /// Height in the document of a logical position (line + fraction within
    /// it): 0 is the very top, `lineCount` the very bottom.
    func documentY(atPosition position: Double) -> CGFloat {
        guard position > 0 else { return 0 }
        guard position < Double(sidebar.lineCount) else { return documentHeight }
        let line = Int(position)
        guard let frame = layoutFragmentFrame(ofLine: line) else { return documentHeight }
        let fraction = CGFloat(min(max(position - Double(line), 0), 1))
        return frame.minY + fraction * frame.height + textView.textContainerOrigin.y
    }

    /// Scrolls so the given logical position sits at the top of the viewport,
    /// clamped to the document. Only this pane moves; callers guard loops.
    func scroll(toVerticalPosition position: Double, horizontalOffset: CGFloat? = nil) {
        guard sidebar.lineCount > 0 else { return }
        scroll(toDocumentY: documentY(atPosition: position), horizontalOffset: horizontalOffset)
    }

    /// Scrolls so the given document height is at the top of the viewport,
    /// clamped to the document.
    func scroll(toDocumentY y: CGFloat, horizontalOffset: CGFloat? = nil) {
        let clipHeight = scrollView.contentView.bounds.height
        let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clipHeight)
        let targetY = min(max(0, y), maxY)
        var targetX = scrollView.documentVisibleRect.origin.x
        if let horizontalOffset {
            let maxX = max(0, (scrollView.documentView?.frame.width ?? 0) - scrollView.contentView.bounds.width)
            targetX = min(max(0, horizontalOffset), maxX)
        }
        scrollView.contentView.scroll(to: NSPoint(x: targetX, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Long lines wrap at the pane's width (the default) or run on past it
    /// with a horizontal scroller.
    func setWrapsLines(_ wraps: Bool) {
        guard let container = textView.textContainer else { return }
        let unlimited = CGFloat.greatestFiniteMagnitude
        scrollView.hasHorizontalScroller = !wraps
        textView.isHorizontallyResizable = !wraps
        textView.autoresizingMask = wraps ? [.width] : []
        container.widthTracksTextView = wraps
        if wraps {
            let width = scrollView.contentSize.width
            container.containerSize = NSSize(width: width, height: unlimited)
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollView.documentVisibleRect.origin.y))
        } else {
            textView.maxSize = NSSize(width: unlimited, height: unlimited)
            container.containerSize = NSSize(width: unlimited, height: unlimited)
        }
        if let layoutManager = textView.textLayoutManager {
            layoutManager.invalidateLayout(for: layoutManager.documentRange)
            layoutManager.textViewportLayoutController.layoutViewport()
        }
        textView.sizeToFit()
        scrollView.reflectScrolledClipView(scrollView.contentView)
        sidebar.needsDisplay = true
        updateOverviewViewport()
    }

    /// Y of the top of a line, measured from the top of the visible viewport
    /// (negative or beyond the viewport height when scrolled out of view).
    func viewportY(forLine line: Int) -> CGFloat {
        let visibleY = scrollView.documentVisibleRect.origin.y
        guard let frame = layoutFragmentFrame(ofLine: line) else {
            return textView.frame.height - visibleY
        }
        return frame.minY + textView.textContainerOrigin.y - visibleY
    }

    // MARK: - Alignment padding

    /// Empty space after a line (or above the first one) that keeps the two
    /// texts side by side: opposite a block that is longer on the other side,
    /// as in WinMerge. It is a paragraph-spacing attribute, so the characters
    /// never change; it goes with the highlights on the next edit.
    private var paddedParagraphs: [NSRange] = []
    private static let textInset = NSSize(width: 4, height: 6)
    /// The text view's own minimum height, before any alignment.
    private lazy var baseMinimumHeight: CGFloat = textView.minSize.height

    /// Called when the width available to the text changes (lines rewrap).
    var onTextWidthChange: (() -> Void)?
    private var lastTextWidth: CGFloat = -1

    /// Height of a run of lines as laid out now, padding included.
    func height(ofLines lines: Range<Int>) -> CGFloat {
        guard !lines.isEmpty, let first = sidebar.characterRange(ofLine: lines.lowerBound),
              let layoutManager = textView.textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
              let start = contentStorage.location(contentStorage.documentRange.location,
                                                  offsetBy: first.location) else { return 0 }
        let endOffset = sidebar.characterRange(ofLine: lines.upperBound)?.location
            ?? (textView.string as NSString).length + 1
        var height: CGFloat = 0
        layoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let offset = contentStorage.offset(from: contentStorage.documentRange.location,
                                               to: fragment.rangeInElement.location)
            guard offset < endOffset else { return false }
            height += fragment.layoutFragmentFrame.height
            return true
        }
        return height
    }

    /// Replaces the padding: `after[line]` points of space below that line,
    /// `top` points above the first line.
    func setPadding(after: [Int: CGFloat], top: CGFloat) {
        clearPadding()
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        var spacing: [Int: CGFloat] = [:]
        for (line, points) in after where points > 0.5 { spacing[line, default: 0] += points }
        // Space above the first line: paragraph spacing is ignored there, so
        // the inset grows instead (which also adds the space at the bottom,
        // below the end of the text, where it does no harm).
        if top > 0.5 { textView.textContainerInset = NSSize(width: Self.textInset.width, height: Self.textInset.height + top) }
        guard !spacing.isEmpty else { return }
        let text = storage.string as NSString
        let base = textView.defaultParagraphStyle ?? .default
        storage.beginEditing()
        for (line, space) in spacing {
            guard let range = sidebar.characterRange(ofLine: line) else { continue }
            let paragraph = text.paragraphRange(for: NSRange(location: min(range.location, text.length), length: 0))
            guard paragraph.length > 0 else { continue }
            let style = base.mutableCopy() as! NSMutableParagraphStyle
            style.paragraphSpacing = space
            storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
            paddedParagraphs.append(paragraph)
        }
        storage.endEditing()
    }

    /// Makes the document at least this tall (empty space below the text),
    /// so both panes can scroll to the same end.
    func setMinimumDocumentHeight(_ height: CGFloat) {
        textView.minSize = NSSize(width: textView.minSize.width, height: max(baseMinimumHeight, height))
        textView.sizeToFit()
    }

    func clearPadding() {
        if textView.textContainerInset != Self.textInset { textView.textContainerInset = Self.textInset }
        if textView.minSize.height != baseMinimumHeight {
            textView.minSize = NSSize(width: textView.minSize.width, height: baseMinimumHeight)
        }
        guard !paddedParagraphs.isEmpty, let storage = textView.textStorage else { return }
        let base = textView.defaultParagraphStyle ?? .default
        storage.beginEditing()
        for range in paddedParagraphs where NSMaxRange(range) <= storage.length {
            storage.addAttribute(.paragraphStyle, value: base, range: range)
        }
        storage.endEditing()
        paddedParagraphs = []
    }

    /// Lays out (at most) one fragment to resolve the frame of a line.
    /// nil for the trailing empty line after a final newline.
    private func layoutFragmentFrame(ofLine line: Int) -> CGRect? {
        guard let range = sidebar.characterRange(ofLine: line),
              let layoutManager = textView.textLayoutManager,
              let contentStorage = layoutManager.textContentManager as? NSTextContentStorage,
              let location = contentStorage.location(contentStorage.documentRange.location,
                                                     offsetBy: range.location) else { return nil }
        var frame: CGRect?
        layoutManager.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { fragment in
            frame = fragment.layoutFragmentFrame
            return false
        }
        return frame
    }
}
