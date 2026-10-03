import AppKit

/// Builds the main window and owns all user actions: compare, navigation
/// between differences, swap, clear and the comparison options.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {

    /// Root view: split view on top, status bar at the bottom.
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
        }
    }

    /// Status bar: message on the left, color legend (with counts after a
    /// comparison) on the right.
    final class StatusBarView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
        }
    }

    /// Colored dots explaining the highlight colors; shows line counts once
    /// a comparison has run.
    final class LegendView: NSView {
        var counts: (removed: Int, added: Int, moved: Int)? {
            didSet { needsDisplay = true }
        }

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()

            let entries: [(NSColor, String, Int?)] = [
                (.systemRed, L10n.legendRemoved, counts?.removed),
                (.systemGreen, L10n.legendAdded, counts?.added),
                (.systemOrange, L10n.legendMoved, counts?.moved),
            ]
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let dot: CGFloat = 8
            var x = bounds.width
            for (color, label, count) in entries.reversed() {
                let text = (count.map { "\($0) " } ?? "") + label
                let size = (text as NSString).size(withAttributes: attributes)
                x -= size.width
                (text as NSString).draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2),
                                        withAttributes: attributes)
                x -= dot + 5
                color.withAlphaComponent(0.85).setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: (bounds.height - dot) / 2, width: dot, height: dot)).fill()
                x -= 16
            }
        }
    }

    private enum ToolbarID {
        static let toolbar = NSToolbar.Identifier("CompareTextToolbar")
        static let previous = NSToolbarItem.Identifier("previous")
        static let next = NSToolbarItem.Identifier("next")
        static let swap = NSToolbarItem.Identifier("swap")
        static let clear = NSToolbarItem.Identifier("clear")
        static let options = NSToolbarItem.Identifier("options")
        static let compare = NSToolbarItem.Identifier("compare")
    }

    let window: NSWindow
    let left = PaneController(title: L10n.leftTitle, placeholderText: L10n.leftPlaceholder)
    let right = PaneController(title: L10n.rightTitle, placeholderText: L10n.rightPlaceholder)
    let scrollSync: ScrollSyncCoordinator

    private let root = RootView()
    private let splitView = GutterSplitView()
    private let statusBar = StatusBarView()
    private let summaryLabel = NSTextField(labelWithString: L10n.hintStart)
    private let legend = LegendView()
    private let compareButton = NSButton(title: L10n.compare, target: nil, action: nil)
    private let movedOverlay = MovedLinksOverlay()
    private var toolbarItems: [NSToolbarItem.Identifier: NSToolbarItem] = [:]

    private static let ignoreWhitespaceDefaultsKey = "ignoreWhitespace"
    private static let scrollTogetherDefaultsKey = "scrollTogether"

    private static let statusBarHeight: CGFloat = 30
    /// Margin between the cards and the window edges.
    private static let outerMargin: CGFloat = 12
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

    /// Exposed for the self-test harness.
    var legendCounts: (removed: Int, added: Int, moved: Int)? { legend.counts }

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
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none

        compareButton.target = self
        compareButton.action = #selector(compare(_:))
        compareButton.bezelStyle = .push
        compareButton.bezelColor = .controlAccentColor
        compareButton.keyEquivalent = "\r"
        compareButton.toolTip = L10n.compare + "  (⌘↩)"

        makeToolbarItems()
        let toolbar = NSToolbar(identifier: ToolbarID.toolbar)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        updateNavigationButtons()

        left.outerInsets = NSEdgeInsets(top: 0, left: Self.outerMargin, bottom: 0, right: 0)
        right.outerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: Self.outerMargin)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(left.box)
        splitView.addArrangedSubview(right.box)

        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        statusBar.addSubview(summaryLabel)
        // Draw-once custom view: topmost in its parent (macOS 26 z-order).
        statusBar.addSubview(legend)

        root.addSubview(splitView)
        root.addSubview(statusBar)
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
        let barHeight = Self.statusBarHeight
        statusBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        splitView.frame = NSRect(x: 0, y: barHeight,
                                 width: bounds.width, height: bounds.height - barHeight)
        movedOverlay.frame = splitView.frame

        let margin = Self.outerMargin + 4
        let legendWidth: CGFloat = 340
        legend.frame = NSRect(x: bounds.width - margin - legendWidth, y: 0,
                              width: legendWidth, height: barHeight)
        summaryLabel.frame = NSRect(x: margin, y: (barHeight - 15) / 2,
                                    width: max(0, legend.frame.minX - margin - 12), height: 15)

        left.layoutBox()
        right.layoutBox()
    }

    // MARK: - Toolbar

    private func makeToolbarItems() {
        func symbolItem(_ id: NSToolbarItem.Identifier, symbol: String, label: String,
                        toolTip: String, action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.label = label
            item.toolTip = toolTip
            item.target = self
            item.action = action
            item.isBordered = true
            item.autovalidates = false
            return item
        }

        toolbarItems[ToolbarID.previous] = symbolItem(
            ToolbarID.previous, symbol: "chevron.up", label: L10n.previousDifference,
            toolTip: L10n.previousDifference + "  (⌘[)", action: #selector(previousDifference(_:)))
        toolbarItems[ToolbarID.next] = symbolItem(
            ToolbarID.next, symbol: "chevron.down", label: L10n.nextDifference,
            toolTip: L10n.nextDifference + "  (⌘])", action: #selector(nextDifference(_:)))
        toolbarItems[ToolbarID.swap] = symbolItem(
            ToolbarID.swap, symbol: "arrow.left.arrow.right", label: L10n.swapTexts,
            toolTip: L10n.swapTexts + "  (⇧⌘T)", action: #selector(swapTexts(_:)))
        toolbarItems[ToolbarID.clear] = symbolItem(
            ToolbarID.clear, symbol: "trash", label: L10n.clearAll,
            toolTip: L10n.clearAll + "  (⇧⌘K)", action: #selector(clearAll(_:)))

        let options = NSMenuToolbarItem(itemIdentifier: ToolbarID.options)
        options.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: L10n.options)
        options.label = L10n.options
        options.toolTip = L10n.options
        options.showsIndicator = true
        let menu = NSMenu()
        let whitespace = menu.addItem(withTitle: L10n.ignoreWhitespace,
                                      action: #selector(toggleWhitespace(_:)), keyEquivalent: "")
        whitespace.target = self
        whitespace.toolTip = L10n.ignoreWhitespaceTooltip
        let scrolling = menu.addItem(withTitle: L10n.scrollTogether,
                                     action: #selector(toggleScrollTogether(_:)), keyEquivalent: "")
        scrolling.target = self
        scrolling.toolTip = L10n.scrollTogetherTooltip
        options.menu = menu
        toolbarItems[ToolbarID.options] = options

        let compare = NSToolbarItem(itemIdentifier: ToolbarID.compare)
        compare.view = compareButton
        compare.label = L10n.compare
        toolbarItems[ToolbarID.compare] = compare
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, ToolbarID.previous, ToolbarID.next, .space,
         ToolbarID.swap, ToolbarID.clear, ToolbarID.options, .space, ToolbarID.compare]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        toolbarItems[itemIdentifier]
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleWhitespace(_:)):
            menuItem.state = ignoresWhitespace ? .on : .off
        case #selector(toggleScrollTogether(_:)):
            menuItem.state = scrollSync.isEnabled ? .on : .off
        case #selector(nextDifference(_:)), #selector(previousDifference(_:)):
            return !hunkAnchors.isEmpty
        default:
            break
        }
        return true
    }

    // MARK: - Status

    private func setSummary(_ text: String) {
        summaryLabel.stringValue = text
    }

    /// Exposed for the self-test harness.
    var summaryText: String { summaryLabel.stringValue }

    func setIgnoresWhitespace(_ on: Bool) {
        ignoresWhitespace = on
        UserDefaults.standard.set(on, forKey: Self.ignoreWhitespaceDefaultsKey)
    }

    @objc func toggleWhitespace(_ sender: Any?) {
        setIgnoresWhitespace(!ignoresWhitespace)
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
        legend.counts = nil
        setSummary(L10n.hintEdited)
    }

    @objc func toggleScrollTogether(_ sender: Any?) {
        setScrollTogether(!scrollSync.isEnabled)
    }

    func setScrollTogether(_ on: Bool) {
        scrollSync.isEnabled = on
        UserDefaults.standard.set(on, forKey: Self.scrollTogetherDefaultsKey)
        if on {
            scrollSync.alignNow(drivenBy: left)
        }
    }

    private func updateNavigationButtons() {
        let enabled = !hunkAnchors.isEmpty
        toolbarItems[ToolbarID.previous]?.isEnabled = enabled
        toolbarItems[ToolbarID.next]?.isEnabled = enabled
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
            legend.counts = (result.leftChanged.count, result.rightChanged.count, result.leftMoved.count)

            scrollSync.activate(matchedLines: result.matchedLines,
                                leftLineCount: left.lineCount, rightLineCount: right.lineCount,
                                leftGeneration: leftGeneration, rightGeneration: rightGeneration)
            movedOverlay.update(pairs: result.movedPairs,
                                leftGeneration: leftGeneration, rightGeneration: rightGeneration)

            if result.identical {
                setSummary(result.onlyWhitespaceDiffers ? L10n.identicalExceptWhitespace : L10n.identical)
                scrollSync.alignNow(drivenBy: left)
            } else {
                setSummary(L10n.summary(movedBlocks: result.movedPairs.count,
                                        hunks: result.hunkAnchors.count))
                // Jump to the first difference, but keep the summary visible.
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
