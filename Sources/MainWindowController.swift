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
    let left = PaneController(title: "\(L10n.leftTitle)   —   \(L10n.leftLegend)",
                              placeholderText: L10n.leftPlaceholder)
    let right = PaneController(title: "\(L10n.rightTitle)   —   \(L10n.rightLegend)",
                               placeholderText: L10n.rightPlaceholder)

    private let root = RootView()
    private let splitView = NSSplitView()
    private let bar = BarView()
    private let summaryLabel = NSTextField(labelWithString: L10n.hintStart)
    private let compareButton = NSButton(title: L10n.compare, target: nil, action: nil)
    private let clearButton = NSButton(title: L10n.clearButton, target: nil, action: nil)
    private let swapButton = NSButton(title: L10n.swapButton, target: nil, action: nil)
    private let previousButton = NSButton(title: "◀", target: nil, action: nil)
    private let nextButton = NSButton(title: "▶", target: nil, action: nil)

    private static let barHeight: CGFloat = 46
    private static let removedLineColor = NSColor.systemRed.withAlphaComponent(0.18)
    private static let removedInlineColor = NSColor.systemRed.withAlphaComponent(0.42)
    private static let addedLineColor = NSColor.systemGreen.withAlphaComponent(0.18)
    private static let addedInlineColor = NSColor.systemGreen.withAlphaComponent(0.42)

    private var comparing = false
    private(set) var hunkAnchors: [(left: Int, right: Int)] = []
    private var currentHunk = -1

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        super.init()

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

        bar.addSubview(summaryLabel)
        bar.addSubview(previousButton)
        bar.addSubview(nextButton)
        bar.addSubview(swapButton)
        bar.addSubview(clearButton)
        bar.addSubview(compareButton)

        root.addSubview(splitView)
        root.addSubview(bar)
        root.onLayout = { [weak self] in self?.layoutRoot() }

        window.contentView = root
        layoutRoot()
        splitView.setPosition(root.bounds.width / 2, ofDividerAt: 0)

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

        for button in [compareButton, clearButton, swapButton, previousButton, nextButton] {
            button.sizeToFit()
        }
        let buttonY = (Self.barHeight - compareButton.frame.height) / 2
        var x = bounds.width - 12
        for button in [compareButton, clearButton, swapButton, nextButton, previousButton] {
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

    private func textsEdited() {
        hunkAnchors = []
        currentHunk = -1
        updateNavigationButtons()
        setSummary(L10n.hintEdited)
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

        comparing = true
        compareButton.isEnabled = false
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DiffEngine.compare(left: leftText, right: rightText)
            }.value

            comparing = false
            compareButton.isEnabled = true
            defer { completion?() }
            // Text was edited while the diff ran; the result no longer applies.
            guard left.generation == leftGeneration, right.generation == rightGeneration else { return }

            left.applyHighlights(lines: result.leftChanged, inline: result.leftInline,
                                 lineColor: Self.removedLineColor, inlineColor: Self.removedInlineColor)
            right.applyHighlights(lines: result.rightChanged, inline: result.rightInline,
                                  lineColor: Self.addedLineColor, inlineColor: Self.addedInlineColor)

            hunkAnchors = result.hunkAnchors
            currentHunk = -1
            updateNavigationButtons()

            if result.identical {
                setSummary(L10n.identical)
            } else {
                setSummary(L10n.summary(removed: result.leftChanged.count,
                                        added: result.rightChanged.count,
                                        hunks: result.hunkAnchors.count))
                nextDifference(nil)
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
        let anchor = hunkAnchors[currentHunk]
        left.scrollToLine(anchor.left)
        right.scrollToLine(anchor.right)
        setSummary(L10n.differencePosition(currentHunk + 1, of: hunkAnchors.count))
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
