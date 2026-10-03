import AppKit

/// Builds the main window and owns all user actions: compare, navigation
/// between differences, swap and clear.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {

    /// Root view: split view on top, button bar at the bottom.
    final class RootView: NSView {
        var onLayout: (() -> Void)?
        override func resizeSubviews(withOldSize oldSize: NSSize) { onLayout?() }
    }

    /// Split view with a wide empty gutter as divider; the moved-block
    /// overlay draws its connector ribbons in that gutter.
    final class GutterSplitView: NSSplitView {
        static let gutterWidth: CGFloat = 28

        override var dividerThickness: CGFloat { Self.gutterWidth }

        override func drawDivider(in rect: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            rect.fill()
            // Hairlines on both edges so the gutter reads as its own column
            // instead of an extension of the left pane.
            NSColor.separatorColor.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height).fill()
            NSRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
        }
    }

    /// Bottom bar with its own background and hairline so it reads clearly
    /// in both light and dark mode.
    final class BarView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
    }

    let window: NSWindow
    let left = PaneController(title: "\(L10n.leftTitle)   —   \(L10n.leftLegend) · \(L10n.movedLegend)",
                              placeholderText: L10n.leftPlaceholder)
    let right = PaneController(title: "\(L10n.rightTitle)   —   \(L10n.rightLegend) · \(L10n.movedLegend)",
                               placeholderText: L10n.rightPlaceholder)
    let scrollSync: ScrollSyncCoordinator

    private let root = RootView()
    private let splitView = GutterSplitView()
    private let bar = BarView()
    private let summaryLabel = NSTextField(labelWithString: L10n.hintStart)
    private let compareButton = NSButton(title: L10n.compare, target: nil, action: nil)
    private let clearButton = NSButton(title: L10n.clearButton, target: nil, action: nil)
    private let swapButton = NSButton(title: L10n.swapButton, target: nil, action: nil)
    private let previousButton = NSButton(title: "◀", target: nil, action: nil)
    private let nextButton = NSButton(title: "▶", target: nil, action: nil)
    private let whitespaceCheckbox = NSButton(checkboxWithTitle: L10n.ignoreWhitespace, target: nil, action: nil)
    private let scrollTogetherCheckbox = NSButton(checkboxWithTitle: L10n.scrollTogether, target: nil, action: nil)
    private let movedOverlay = MovedLinksOverlay()

    private static let ignoreWhitespaceDefaultsKey = "ignoreWhitespace"
    private static let scrollTogetherDefaultsKey = "scrollTogether"

    private static let barHeight: CGFloat = 46
    private static let removedLineColor = NSColor.systemRed.withAlphaComponent(0.18)
    private static let removedInlineColor = NSColor.systemRed.withAlphaComponent(0.42)
    private static let addedLineColor = NSColor.systemGreen.withAlphaComponent(0.18)
    private static let addedInlineColor = NSColor.systemGreen.withAlphaComponent(0.42)
    private static let movedLineColor = NSColor.systemOrange.withAlphaComponent(0.18)

    private var comparing = false
    private(set) var hunkAnchors: [(left: Int, right: Int)] = []
    private(set) var movedPairs: [MovedBlock] = []
    private var currentHunk = -1

    /// One toggle drives both options: whitespace and blank lines.
    private(set) var ignoresWhitespace: Bool = {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: MainWindowController.ignoreWhitespaceDefaultsKey) == nil
            ? true
            : defaults.bool(forKey: MainWindowController.ignoreWhitespaceDefaultsKey)
    }()

    private var diffOptions: DiffOptions {
        DiffOptions(ignoreWhitespace: ignoresWhitespace, ignoreBlankLines: ignoresWhitespace)
    }

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        scrollSync = ScrollSyncCoordinator(left: left, right: right)
        super.init()

        let defaults = UserDefaults.standard
        scrollSync.isEnabled = defaults.object(forKey: Self.scrollTogetherDefaultsKey) == nil
            ? true
            : defaults.bool(forKey: Self.scrollTogetherDefaultsKey)

        window.title = L10n.appName
        window.minSize = NSSize(width: 900, height: 500)
        window.delegate = self
        window.center()
        window.tabbingMode = .disallowed

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(left.box)
        splitView.addArrangedSubview(right.box)

        summaryLabel.font = .systemFont(ofSize: 12)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail

        configure(compareButton, action: #selector(compare(_:)))
        compareButton.keyEquivalent = "\r"

        configure(clearButton, action: #selector(clearAll(_:)))
        configure(swapButton, action: #selector(swapTexts(_:)))
        configure(previousButton, action: #selector(previousDifference(_:)))
        previousButton.toolTip = L10n.previousDifference + "  (⌘[)"
        configure(nextButton, action: #selector(nextDifference(_:)))
        nextButton.toolTip = L10n.nextDifference + "  (⌘])"
        updateNavigationButtons()

        whitespaceCheckbox.target = self
        whitespaceCheckbox.action = #selector(toggleWhitespace(_:))
        whitespaceCheckbox.toolTip = L10n.ignoreWhitespaceTooltip
        whitespaceCheckbox.state = ignoresWhitespace ? .on : .off

        scrollTogetherCheckbox.target = self
        scrollTogetherCheckbox.action = #selector(toggleScrollTogether(_:))
        scrollTogetherCheckbox.toolTip = L10n.scrollTogetherTooltip
        scrollTogetherCheckbox.state = scrollSync.isEnabled ? .on : .off

        bar.addSubview(summaryLabel)
        bar.addSubview(scrollTogetherCheckbox)
        bar.addSubview(whitespaceCheckbox)
        bar.addSubview(previousButton)
        bar.addSubview(nextButton)
        bar.addSubview(swapButton)
        bar.addSubview(clearButton)
        bar.addSubview(compareButton)

        root.addSubview(splitView)
        root.addSubview(bar)
        // Topmost, so its drawing is never overdrawn (macOS 26 z-order).
        root.addSubview(movedOverlay)
        movedOverlay.configure(left: left, right: right)
        root.onLayout = { [weak self] in self?.layoutRoot() }

        window.contentView = root
        layoutRoot()
        // The divider position is the left pane's width; subtract the gutter
        // so both panes end up equally wide.
        splitView.setPosition((root.bounds.width - GutterSplitView.gutterWidth) / 2, ofDividerAt: 0)

        left.onEdit = { [weak self] in self?.textsEdited() }
        right.onEdit = { [weak self] in self?.textsEdited() }
    }

    private func configure(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(left.textView)
        // macOS 26 drops layer contents of views whose last draw happened
        // before the window became visible; nudge the whole tree once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            Self.markTreeDirty(self.root)
        }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        if window.occlusionState.contains(.visible) {
            Self.markTreeDirty(root)
        }
    }

    private static func markTreeDirty(_ view: NSView) {
        view.needsDisplay = true
        for subview in view.subviews {
            markTreeDirty(subview)
        }
    }

    private func layoutRoot() {
        let bounds = root.bounds
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.barHeight)
        splitView.frame = NSRect(x: 0, y: Self.barHeight,
                                 width: bounds.width, height: bounds.height - Self.barHeight)
        movedOverlay.frame = splitView.frame

        for button in [compareButton, clearButton, swapButton, previousButton, nextButton,
                       whitespaceCheckbox, scrollTogetherCheckbox] {
            button.sizeToFit()
        }
        let buttonY = (Self.barHeight - compareButton.frame.height) / 2
        var x = bounds.width - 12
        for button in [compareButton, clearButton, swapButton, nextButton, previousButton,
                       whitespaceCheckbox, scrollTogetherCheckbox] {
            x -= button.frame.width
            button.frame.origin = NSPoint(x: x, y: buttonY)
            x -= 8
        }
        summaryLabel.frame = NSRect(x: 12, y: (Self.barHeight - 16) / 2,
                                    width: max(0, x - 20), height: 16)

        left.layoutBox()
        right.layoutBox()
    }

    private func setSummary(_ text: String) {
        summaryLabel.stringValue = text
    }

    /// Exposed for the self-test harness.
    var summaryText: String { summaryLabel.stringValue }

    func setIgnoresWhitespace(_ on: Bool) {
        ignoresWhitespace = on
        whitespaceCheckbox.state = on ? .on : .off
        UserDefaults.standard.set(on, forKey: Self.ignoreWhitespaceDefaultsKey)
    }

    @objc private func toggleWhitespace(_ sender: Any?) {
        setIgnoresWhitespace(whitespaceCheckbox.state == .on)
        if !left.text.isEmpty || !right.text.isEmpty {
            compareNow()
        }
    }

    private func textsEdited() {
        hunkAnchors = []
        movedPairs = []
        currentHunk = -1
        updateNavigationButtons()
        scrollSync.invalidate()
        movedOverlay.clear()
        setSummary(L10n.hintEdited)
    }

    @objc private func toggleScrollTogether(_ sender: Any?) {
        setScrollTogether(scrollTogetherCheckbox.state == .on)
    }

    func setScrollTogether(_ on: Bool) {
        scrollSync.isEnabled = on
        scrollTogetherCheckbox.state = on ? .on : .off
        UserDefaults.standard.set(on, forKey: Self.scrollTogetherDefaultsKey)
        if on {
            scrollSync.alignNow(drivenBy: left)
        }
    }

    private func updateNavigationButtons() {
        let enabled = !hunkAnchors.isEmpty
        previousButton.isEnabled = enabled
        nextButton.isEnabled = enabled
    }

    // MARK: - Actions

    @objc func compare(_ sender: Any?) {
        compareNow()
    }

    /// The completion handler is used by the self-test harness.
    func compareNow(completion: (() -> Void)? = nil) {
        guard !comparing else { completion?(); return }
        let leftText = left.text
        let rightText = right.text
        let leftGeneration = left.generation
        let rightGeneration = right.generation
        let options = diffOptions

        comparing = true
        compareButton.isEnabled = false
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DiffEngine.compare(left: leftText, right: rightText, options: options)
            }.value

            comparing = false
            compareButton.isEnabled = true
            defer { completion?() }
            // Text was edited while the diff ran; the result no longer applies.
            guard left.generation == leftGeneration, right.generation == rightGeneration else { return }

            left.applyHighlights(lines: result.leftChanged, inline: result.leftInline,
                                 lineColor: Self.removedLineColor, inlineColor: Self.removedInlineColor,
                                 movedLines: result.leftMoved, movedColor: Self.movedLineColor)
            right.applyHighlights(lines: result.rightChanged, inline: result.rightInline,
                                  lineColor: Self.addedLineColor, inlineColor: Self.addedInlineColor,
                                  movedLines: result.rightMoved, movedColor: Self.movedLineColor)

            hunkAnchors = result.hunkAnchors
            movedPairs = result.movedPairs
            currentHunk = -1
            updateNavigationButtons()

            scrollSync.activate(matchedLines: result.matchedLines,
                                leftLineCount: left.lineCount, rightLineCount: right.lineCount,
                                leftGeneration: leftGeneration, rightGeneration: rightGeneration)
            movedOverlay.update(pairs: result.movedPairs,
                                leftGeneration: leftGeneration, rightGeneration: rightGeneration)

            if result.identical {
                setSummary(result.onlyWhitespaceDiffers ? L10n.identicalExceptWhitespace : L10n.identical)
                scrollSync.alignNow(drivenBy: left)
            } else {
                setSummary(L10n.summary(removed: result.leftChanged.count,
                                        added: result.rightChanged.count,
                                        movedBlocks: result.movedPairs.count,
                                        hunks: result.hunkAnchors.count))
                // Jump to the first difference, but keep the counts visible.
                currentHunk = 0
                scrollToCurrentHunk(updateSummary: false)
            }
        }
    }

    @objc func nextDifference(_ sender: Any?) {
        guard !hunkAnchors.isEmpty else { return }
        currentHunk = (currentHunk + 1) % hunkAnchors.count
        showCurrentHunk()
    }

    @objc func previousDifference(_ sender: Any?) {
        guard !hunkAnchors.isEmpty else { return }
        currentHunk = currentHunk <= 0 ? hunkAnchors.count - 1 : currentHunk - 1
        showCurrentHunk()
    }

    private func showCurrentHunk() {
        scrollToCurrentHunk(updateSummary: true)
    }

    private func scrollToCurrentHunk(updateSummary: Bool) {
        let anchor = hunkAnchors[currentHunk]
        // For a moved block, show the counterpart location on the right so
        // old and new position sit side by side.
        var rightLine = anchor.right
        if let pair = movedPairs.first(where: { $0.left.contains(anchor.left) }) {
            rightLine = pair.right.lowerBound
        }
        scrollSync.performWithoutSync {
            left.scrollToLine(anchor.left)
            right.scrollToLine(rightLine)
        }
        if updateSummary {
            setSummary(L10n.differencePosition(currentHunk + 1, of: hunkAnchors.count))
        }
    }

    @objc func swapTexts(_ sender: Any?) {
        let leftText = left.text
        left.setText(right.text)
        right.setText(leftText)
        if !left.text.isEmpty || !right.text.isEmpty {
            compareNow()
        }
    }

    @objc func clearAll(_ sender: Any?) {
        left.setText("")
        right.setText("")
        setSummary(L10n.hintStart)
        window.makeFirstResponder(left.textView)
    }
}
