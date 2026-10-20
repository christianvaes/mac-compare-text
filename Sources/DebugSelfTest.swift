#if SELFTEST
import AppKit

/// End-to-end test harness, only active when COMPARETEXT_SELFTEST=1 is set.
/// Drives the real UI, verifies highlight attributes, renders the composited
/// layer tree to PNGs (dark and light) for visual inspection, then exits.
/// In normal use this code never runs.
@MainActor
enum DebugSelfTest {
    private static var out = ""
    private static var failures = 0

    private static func check(_ name: String, _ condition: Bool) {
        out += (condition ? "PASS: " : "FAIL: ") + name + "\n"
        if !condition { failures += 1 }
    }

    static func runIfRequested(controller: MainWindowController) {
        guard ProcessInfo.processInfo.environment["COMPARETEXT_SELFTEST"] == "1" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            run(controller: controller)
        }
    }

    private static func run(controller: MainWindowController) {
        let left = controller.left
        let right = controller.right
        let window = controller.window

        // 1. Environment sanity.
        out += "leftBox frame=\(left.box.frame) bounds=\(left.box.bounds)\n"
        out += "sidebar=\(left.sidebar.frame) scroll=\(left.scrollView.frame)\n"
        out += "header frame=\(left.header.frame) hidden=\(left.header.isHidden) inWindow=\(left.header.window != nil) layer=\(left.header.layer != nil)\n"
        renderWindow(window, suffix: "initial")
        check("textkit2 active", left.textView.textLayoutManager != nil)
        check("menu has edit + compare", (NSApp.mainMenu?.items.count ?? 0) >= 3)
        check("editable", left.textView.isEditable && right.textView.isEditable)
        check("window visible", window.isVisible)
        check("panes equal width", abs(left.box.frame.width - right.box.frame.width) <= 1)
        checkOneSurfaceAroundCards(controller: controller)

        // Toolbar: visible, all items present, every symbol resolves.
        let toolbarItems = window.toolbar?.items ?? []
        let named = toolbarItems.filter { $0.itemIdentifier.rawValue != "NSToolbarFlexibleSpaceItem"
            && $0.itemIdentifier.rawValue != "NSToolbarSpaceItem" }
        check("toolbar visible", window.toolbar?.isVisible == true)
        check("toolbar has 7 items", named.count == 7)
        check("toolbar symbols resolve", named.allSatisfy { $0.image != nil || $0.view != nil })
        out += "toolbar items: \(named.map(\.itemIdentifier.rawValue))\n"

        // 2. Cross-app paste into the left pane (pasteboard set by the test runner).
        window.makeFirstResponder(left.textView)
        left.textView.paste(nil)
        check("paste arrived", left.text.contains("PLAKTEST"))

        // 3. Realistic comparison through the real code path.
        left.setText("""
        regel een
        foo bar baz
        regel drie
        wordt verwijderd
        regel vijf
        """)
        right.setText("""
        regel een
        foo QUX baz
        regel drie
        regel vijf
        nieuwe regel
        """)

        controller.compareNow {
            verifyComparison(controller: controller)
        }
    }

    private static func verifyComparison(controller: MainWindowController) {
        let left = controller.left
        let right = controller.right

        // Expected: line 1 changed pair (inline QUX), line 3 removed left,
        // line 4 added right => 3 hunks.
        check("hunks == 3", controller.hunkAnchors.count == 3)
        check("left highlight lines", highlightedLines(left) == [1, 3])
        check("right highlight lines", highlightedLines(right) == [1, 4])

        // Inline emphasis: a stronger red on "bar" in the left line 1.
        let strongLeft = strongHighlightRanges(left)
        check("inline emphasis present", strongLeft.contains { range in
            let lineStart = (left.text as NSString).range(of: "foo bar baz").location
            return range.location == lineStart + 4 && range.length >= 3
        })

        // 4. Navigation: all three differences are on screen at once, so the
        // marker has to show which one is current at every step.
        check("marker: first difference after compare",
              left.sidebar.currentRange == 1..<2 && right.sidebar.currentRange == 1..<2)
        controller.nextDifference(nil)
        check("marker: removed line, insertion point on the right",
              left.sidebar.currentRange == 3..<4 && right.sidebar.currentRange == 3..<3)
        check("marker: summary says what happened", controller.summaryText.contains(L10n.linesRemoved(1)))
        controller.nextDifference(nil)
        check("marker: added line, insertion point at the end on the left",
              left.sidebar.currentRange == 5..<5 && right.sidebar.currentRange == 4..<5)
        check("marker: summary for an added line", controller.summaryText.contains(L10n.linesAdded(1)))
        controller.nextDifference(nil)
        check("marker: wraps around to the first", left.sidebar.currentRange == 1..<2)
        check("marker: summary for a changed line", controller.summaryText.contains(L10n.linesChanged(1)))
        controller.previousDifference(nil)
        check("marker: previous goes back to the last", right.sidebar.currentRange == 4..<5)
        renderWindow(controller.window, suffix: "marker")

        // 4b. Window resize: manual layout must follow.
        let originalFrame = controller.window.frame
        controller.window.setFrame(NSRect(x: originalFrame.minX, y: originalFrame.minY,
                                          width: 1000, height: 600), display: true)
        controller.window.layoutIfNeeded()
        let box = left.box
        check("resize: header on top", abs(left.header.frame.maxY - box.bounds.height) < 0.5)
        check("resize: panes fill height",
              abs(left.scrollView.frame.height - (box.bounds.height - PaneController.headerHeight)) < 0.5)
        controller.window.setFrame(originalFrame, display: true)
        controller.window.layoutIfNeeded()

        // 4c. About panel: opens, shows build date, renders.
        AppDelegate.shared.showAbout(nil)
        let aboutPanel = AppDelegate.shared.aboutWindow
        check("about panel opened", aboutPanel?.isVisible == true)
        check("build date stamped", (Bundle.main.object(forInfoDictionaryKey: "BuildDate") as? String)?.isEmpty == false)
        if let panel = aboutPanel, let content = panel.contentView,
           let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            panel.displayIfNeeded()
            content.cacheDisplay(in: content.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                let path = NSTemporaryDirectory() + "comparetext-about.png"
                try? png.write(to: URL(fileURLWithPath: path))
                out += "about render: \(path)\n"
            }
            panel.close()
        }

        // 5. Renders: dark and light.
        renderWindow(controller.window, suffix: "dark")
        controller.window.appearance = NSAppearance(named: .aqua)
        controller.window.displayIfNeeded()
        renderWindow(controller.window, suffix: "light")
        controller.window.appearance = nil

        // 6. Swap. (Swap kicks off its own async compare; give it time to
        // settle before the next stage.)
        let beforeLeft = left.text
        controller.swapTexts(nil)
        check("swap exchanged", right.text == beforeLeft && left.text.contains("QUX"))

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            identicalStage(controller: controller)
        }
    }

    private static func identicalStage(controller: MainWindowController) {
        // 7. Identical case.
        controller.left.setText("zelfde\ntekst")
        controller.right.setText("zelfde\ntekst")
        controller.compareNow {
            check("identical no hunks", controller.hunkAnchors.isEmpty)
            whitespaceStage(controller: controller)
        }
    }

    private static func whitespaceStage(controller: MainWindowController) {
        // 7b. Whitespace toggle: indent-shifted text with extra blank lines is
        // "identical" by default; strict mode shows the differences.
        controller.left.setText("regel een\n  regel twee\nregel drie")
        controller.right.setText("    regel een\n\n      regel twee\n\n    regel drie")
        controller.setIgnoresWhitespace(true)
        controller.compareNow {
            check("whitespace-only: no hunks", controller.hunkAnchors.isEmpty)
            check("whitespace-only: summary mentions it", controller.summaryText == L10n.identicalExceptWhitespace)

            controller.setIgnoresWhitespace(false)
            controller.compareNow {
                check("strict: differences shown", !controller.hunkAnchors.isEmpty)
                controller.setIgnoresWhitespace(true)
                movedStage(controller: controller)
            }
        }
    }

    private static func movedStage(controller: MainWindowController) {
        // 7c. Moved block: orange in both panes, counted in the summary,
        // connecting line drawn by the overlay (verified visually via the
        // rendered PNGs).
        controller.left.setText("verplaats blok regel 1\nverplaats blok regel 2\nvaste regel hier\nvaste regel twee\nvaste regel drie")
        controller.right.setText("vaste regel hier\nvaste regel twee\nvaste regel drie\nverplaats blok regel 1\nverplaats blok regel 2")
        controller.compareNow {
            check("moved: one pair", controller.movedPairs.count == 1)
            check("moved: highlighted in both panes",
                  highlightedLines(controller.left) == [0, 1] && highlightedLines(controller.right) == [3, 4])
            check("moved: no strong inline", strongHighlightRanges(controller.left).isEmpty)
            check("moved: summary mentions it", controller.summaryText.contains("verplaatst") || controller.summaryText.contains("moved"))
            check("moved: legend counts", controller.legendCounts?.moved == 2)
            renderWindow(controller.window, suffix: "moved")
            demoStage(controller: controller)
        }
    }

    /// Optional stage: render a comparison of caller-supplied texts (base64
    /// in the environment), for visual inspection of real-world cases.
    private static func demoStage(controller: MainWindowController) {
        let env = ProcessInfo.processInfo.environment
        guard let leftB64 = env["COMPARETEXT_DEMO_LEFT_B64"],
              let rightB64 = env["COMPARETEXT_DEMO_RIGHT_B64"],
              let leftData = Data(base64Encoded: leftB64),
              let rightData = Data(base64Encoded: rightB64),
              let leftText = String(data: leftData, encoding: .utf8),
              let rightText = String(data: rightData, encoding: .utf8) else {
            scrollSyncStage(controller: controller)
            return
        }
        controller.left.setText(leftText)
        controller.right.setText(rightText)
        controller.compareNow {
            out += "demo movedPairs=\(controller.movedPairs.count)\n"
            renderWindow(controller.window, suffix: "demo")
            renderFullWindow(controller.window, suffix: "demo-full")
            // Second shot: both sides of the last moved block in view.
            if let block = controller.movedPairs.last {
                controller.scrollSync.performWithoutSync {
                    controller.left.scroll(toVerticalPosition: Double(max(0, block.left.lowerBound - 2)))
                    controller.right.scroll(toVerticalPosition: Double(max(0, block.right.lowerBound - 2)))
                }
                renderWindow(controller.window, suffix: "demo-moved")
            }
            scrollSyncStage(controller: controller)
        }
    }

    /// The margins, the gutter, the header band and the status bar must all
    /// let the window background through (nothing painted there), so the
    /// frame around the cards is one surface; the cards themselves are
    /// opaque.
    private static func checkOneSurfaceAroundCards(controller: MainWindowController) {
        guard let content = controller.window.contentView, let layer = content.layer,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(content.bounds.width),
                                         pixelsHigh: Int(content.bounds.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            check("one surface: render", false)
            return
        }
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        layer.render(in: ctx.cgContext)
        // The layer render has the view's bottom-left origin at row 0.
        func alpha(at point: NSPoint) -> CGFloat {
            rep.colorAt(x: Int(point.x), y: Int(point.y))?.alphaComponent ?? -1
        }
        let bounds = content.bounds
        let leftCard = content.convert(controller.left.card.bounds, from: controller.left.card)
        let rightCard = content.convert(controller.right.card.bounds, from: controller.right.card)
        let probes: [(String, NSPoint)] = [
            ("left margin", NSPoint(x: leftCard.minX / 2, y: bounds.midY)),
            ("right margin", NSPoint(x: (rightCard.maxX + bounds.maxX) / 2, y: bounds.midY)),
            ("gutter", NSPoint(x: (leftCard.maxX + rightCard.minX) / 2, y: bounds.midY)),
            ("status bar", NSPoint(x: bounds.midX, y: 3)),
            ("header band", NSPoint(x: leftCard.midX, y: leftCard.maxY + 3)),
        ]
        for (name, point) in probes {
            check("one surface: \(name) shows window background", alpha(at: point) == 0)
        }
        check("one surface: card is opaque", alpha(at: NSPoint(x: leftCard.midX, y: leftCard.midY)) > 0.9)
    }

    /// Renders the whole window frame including titlebar and toolbar.
    private static func renderFullWindow(_ window: NSWindow, suffix: String) {
        guard let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            let path = NSTemporaryDirectory() + "comparetext-\(suffix).png"
            try? png.write(to: URL(fileURLWithPath: path))
            out += "render \(suffix): \(path)\n"
        }
    }

    private static func scrollSyncStage(controller: MainWindowController) {
        // 7d. Synchronized scrolling: left 400 lines; right has 200 extra
        // lines inserted after line 99, so left line i>=100 maps to i+200.
        let leftLines = (0..<400).map { "sync regel \($0)" }
        var rightLines = Array(leftLines[0..<100])
        rightLines += (0..<200).map { "extra regel \($0)" }
        rightLines += leftLines[100...]
        controller.left.setText(leftLines.joined(separator: "\n"))
        controller.right.setText(rightLines.joined(separator: "\n"))
        controller.setScrollTogether(true)
        controller.compareNow {
            controller.left.scroll(toVerticalPosition: 300)
            var rightPosition = controller.right.topVerticalPosition() ?? -1
            check("sync: right follows mapped position", abs(rightPosition - 500) <= 1.5)

            controller.left.scroll(toVerticalPosition: 0)
            rightPosition = controller.right.topVerticalPosition() ?? -1
            check("sync: back to top", rightPosition <= 1.5)

            // Toggle off: the other pane stays put.
            controller.setScrollTogether(false)
            controller.left.scroll(toVerticalPosition: 200)
            rightPosition = controller.right.topVerticalPosition() ?? -1
            check("sync off: right stays", rightPosition <= 1.5)

            // Toggle on re-aligns immediately.
            controller.setScrollTogether(true)
            rightPosition = controller.right.topVerticalPosition() ?? -1
            check("sync on: re-aligned", abs(rightPosition - 400) <= 1.5)

            // Edit deactivates sync until the next compare.
            controller.right.textView.insertText("X", replacementRange: NSRange(location: 0, length: 0))
            let before = controller.right.scrollView.documentVisibleRect.origin.y
            controller.left.scroll(toVerticalPosition: 50)
            let after = controller.right.scrollView.documentVisibleRect.origin.y
            check("sync: inactive after edit", abs(before - after) < 0.5)

            fileDropStage(controller: controller)
        }
    }

    private static func fileDropStage(controller: MainWindowController) {
        // 7e. Dropped files. The drag itself (Finder → window) can't be
        // automated here; everything behind it runs on real files.
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("drop-test", isDirectory: true)
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func write(_ name: String, _ data: Data) -> URL {
            let url = dir.appendingPathComponent(name)
            try? data.write(to: url)
            return url
        }
        let v1 = write("config-v1.yaml", Data("alias: test\r\nwaarde: 1\r\n".utf8))
        let v2 = write("config-v2.yaml", Data("alias: test\nwaarde: 2\n".utf8))
        let latin = write("latin1.txt", "café\n".data(using: .isoLatin1)!)
        let binary = write("plaatje.png", Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0x01, 0x02]))
        let big = dir.appendingPathComponent("groot.log")
        fm.createFile(atPath: big.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: big) {
            try? handle.truncate(atOffset: UInt64(TextFileLoader.maxBytes + 1))
            try? handle.close()
        }

        check("drop: text view handles file drops", controller.left.textView is FileDropTextView)

        let pasted = "geplakte tekst die niet verloren mag gaan"
        controller.left.setText(pasted)
        controller.filesDropped([v1], on: .left)
        check("drop: content loaded, line endings normalized", controller.left.text == "alias: test\nwaarde: 1\n")
        check("drop: header shows file name", controller.left.currentFileName == "config-v1.yaml")
        check("drop: summary names the file", controller.summaryText.contains("config-v1.yaml"))

        controller.filesDropped([latin], on: .right)
        check("drop: latin-1 decoded", controller.right.text == "café\n")
        let before = controller.right.text
        controller.filesDropped([binary], on: .right)
        check("drop: binary refused", controller.right.text == before && controller.summaryText.contains("plaatje.png"))
        controller.filesDropped([big], on: .right)
        check("drop: over 50 MB refused", controller.right.text == before && controller.summaryText.contains("groot.log"))
        controller.filesDropped([dir], on: .right)
        check("drop: folder refused", controller.right.text == before)

        // A file outside the app's container that was not dropped must stay
        // unreadable: the sandbox only opens what the user drags in.
        if let outside = ProcessInfo.processInfo.environment["COMPARETEXT_OUTSIDE_FILE"] {
            check("drop: sandbox blocks files that were not dropped",
                  TextFileLoader.load(URL(fileURLWithPath: outside)) == .failure(.unreadable))
        }

        // Undo needs the event's undo group closed: next run loop pass.
        DispatchQueue.main.async {
            controller.left.textView.undoManager?.undo()
            check("drop: undo brings the pasted text back", controller.left.text == pasted)
            check("drop: undo updates line numbers", controller.left.lineCount == 1)
            check("drop: title back to default after undo", controller.left.currentFileName == nil)
            controller.left.textView.undoManager?.redo()
            check("drop: redo loads the file again",
                  controller.left.text == "alias: test\nwaarde: 1\n" && controller.left.lineCount == 3
                  && controller.left.currentFileName == "config-v1.yaml")
            typingUndoCheck(controller: controller, then: {

            // Two files at once: name order, compared right away.
            controller.filesDropped([v2, v1], on: .right)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                check("drop two: v1 left, v2 right",
                      controller.left.currentFileName == "config-v1.yaml"
                      && controller.right.currentFileName == "config-v2.yaml")
                check("drop two: compared", controller.hunkAnchors.count == 1)
                try? fm.removeItem(at: dir)
                featuresStage(controller: controller)
            }
            })
        }
    }

    /// Undo of ordinary typing must also reach the pane's bookkeeping.
    private static func typingUndoCheck(controller: MainWindowController, then next: @escaping () -> Void) {
        let pane = controller.right
        pane.setText("een\ntwee")
        DispatchQueue.main.async {
            controller.window.makeFirstResponder(pane.textView)
            pane.textView.setSelectedRange(NSRange(location: (pane.text as NSString).length, length: 0))
            pane.textView.insertText("\ndrie", replacementRange: pane.textView.selectedRange())
            check("typing: line added", pane.lineCount == 3)
            DispatchQueue.main.async {
                let before = pane.generation
                pane.textView.undoManager?.undo()
                check("typing: undo restores text", pane.text == "een\ntwee")
                check("typing: undo updates line numbers", pane.lineCount == 2 && pane.generation > before)
                next()
            }
        }
    }

    /// 7f. Auto-compare, ignore case, copy as text, overview strip, wrapping.
    private static func featuresStage(controller: MainWindowController) {
        let left = controller.left, right = controller.right
        // Auto-compare after paste, not after typing.
        left.setText("een\ntwee\ndrie")
        right.setText("")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("een\nTWEE\ndrie", forType: .string)
        controller.window.makeFirstResponder(right.textView)
        right.textView.paste(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            check("auto: paste compares", controller.hunks.count == 1)
            right.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                check("auto: typing does not compare", controller.hunks.isEmpty
                      && controller.summaryText == L10n.hintEdited)
                caseAndCopyStage(controller: controller)
            }
        }
    }

    private static func caseAndCopyStage(controller: MainWindowController) {
        let left = controller.left, right = controller.right
        left.setText("Hallo Wereld\ntweede regel")
        right.setText("hallo wereld\ntweede regel")
        controller.setIgnoresCase(true)
        controller.compareNow {
            check("case: identical when ignoring case", controller.hunks.isEmpty
                  && controller.summaryText == L10n.identicalExceptIgnored)
            controller.setIgnoresCase(false)
            controller.compareNow {
                check("case: different when not ignoring", controller.hunks.count == 1)
                controller.copyDifferences(nil)
                let copied = NSPasteboard.general.string(forType: .string) ?? ""
                // Same as `diff -u --label Origineel --label Nieuw` on these texts.
                let expected = "--- \(L10n.leftTitle)\n+++ \(L10n.rightTitle)\n@@ -1,2 +1,2 @@\n"
                    + "-Hallo Wereld\n+hallo wereld\n tweede regel\n"
                check("copy: unified diff on the clipboard", copied == expected)
                check("copy: status says so", controller.summaryText == L10n.differencesCopied(1))
                left.setText("zelfde")
                right.setText("zelfde")
                controller.compareNow {
                    controller.copyDifferences(nil)
                    check("copy: nothing to copy", controller.summaryText == L10n.nothingToCopy)
                    overviewStage(controller: controller)
                }
            }
        }
    }

    private static func overviewStage(controller: MainWindowController) {
        let left = controller.left
        controller.left.setText("a\nb\nc\nd\ne\nf\ng\nh")
        controller.right.setText("a\nX\nc\nd\ne\nf\nY\nh")
        controller.compareNow {
            check("overview: marks at the differences", left.overview.marks.map(\.lines) == [1..<2, 6..<7])
            check("overview: current difference shown", left.overview.currentRange == 1..<2)
            // Click near the second difference.
            let bar = left.overview
            bar.click(atY: bar.bounds.height * 6.5 / 8)
            check("overview: click jumps to nearest difference", left.sidebar.currentRange == 6..<7)
            // The strip really paints the marks: red at the first mark.
            if let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) {
                bar.cacheDisplay(in: bar.bounds, to: rep)
                let scale = CGFloat(rep.pixelsHigh) / bar.bounds.height
                let color = rep.colorAt(x: rep.pixelsWide / 2, y: Int(bar.bounds.height * 1.5 / 8 * scale))?
                    .usingColorSpace(.sRGB)
                check("overview: mark is drawn in red", (color?.redComponent ?? 0) > 0.6
                      && (color?.greenComponent ?? 1) < 0.5)
            }
            wrapStage(controller: controller)
        }
    }

    private static func wrapStage(controller: MainWindowController) {
        let left = controller.left, right = controller.right
        let long = String(repeating: "lang woord ", count: 60) + "\nkort"
        left.setText(long)
        right.setText(long)
        controller.compareNow {
            @MainActor func lineHeight(_ pane: PaneController) -> CGFloat {
                pane.viewportY(forLine: 1) - pane.viewportY(forLine: 0)
            }
            check("wrap: long line wraps by default", lineHeight(left) > 40)
            controller.setWrapsLines(false)
            check("wrap off: long line on one row", lineHeight(left) < 25)
            check("wrap off: text wider than the pane",
                  left.textView.frame.width > left.scrollView.contentSize.width + 100
                  && left.scrollView.hasHorizontalScroller)
            left.scrollView.contentView.scroll(to: NSPoint(x: 200, y: 0))
            left.scrollView.reflectScrolledClipView(left.scrollView.contentView)
            check("wrap off: other side scrolls along horizontally",
                  abs(right.scrollView.documentVisibleRect.origin.x - 200) < 1)
            controller.setWrapsLines(true)
            check("wrap on: wraps again", lineHeight(left) > 40
                  && abs(left.textView.frame.width - left.scrollView.contentSize.width) < 1
                  && !left.scrollView.hasHorizontalScroller)
            bigTextStage(controller: controller)
        }
    }

    private static func bigTextStage(controller: MainWindowController) {
        // 8. Large text through the full UI path.
        var lines = (0..<20_000).map { "grote tekst regel \($0)" }
        let a = lines.joined(separator: "\n")
        lines[10_000] = "GEWIJZIGDE REGEL"
        let b = lines.joined(separator: "\n")

        let start = Date()
        controller.left.setText(a)
        controller.right.setText(b)
        controller.compareNow {
            let elapsed = Date().timeIntervalSince(start)
            out += String(format: "big text UI roundtrip (20k regels): %.2fs\n", elapsed)
            out += "big text hunks=\(controller.hunkAnchors.count) lines=\(controller.left.lineCount)/\(controller.right.lineCount)\n"
            check("big text fast enough", elapsed < 5.0)
            check("big text one hunk", controller.hunkAnchors.count == 1)

            // Navigation must scroll the changed line into view, a third down.
            controller.nextDifference(nil)
            let visible = controller.left.scrollView.documentVisibleRect
            check("navigation scrolled down", visible.origin.y > 1000)
            let third = visible.height / 3
            check("navigation: difference a third down on both sides",
                  abs(controller.left.viewportY(forLine: 10_000) - third) < 20
                  && abs(controller.right.viewportY(forLine: 10_000) - third) < 20)
            check("navigation: marker on the changed line", controller.left.sidebar.currentRange == 10_000..<10_001)

            // Editing clears the marker: it no longer matches the text.
            controller.left.textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
            check("marker: cleared on edit", controller.left.sidebar.currentRange == nil)

            // 9. Clear.
            controller.clearAll(nil)
            check("cleared", controller.left.text.isEmpty && controller.right.text.isEmpty)

            finish()
        }
    }

    private static func renderWindow(_ window: NSWindow, suffix: String) {
        guard let content = window.contentView, let layer = content.layer else {
            check("render \(suffix)", false)
            return
        }
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let size = layer.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                         pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            check("render \(suffix)", false)
            return
        }
        ctx.cgContext.scaleBy(x: 2, y: 2)
        layer.render(in: ctx.cgContext)
        if let png = rep.representation(using: .png, properties: [:]) {
            let path = NSTemporaryDirectory() + "comparetext-\(suffix).png"
            try? png.write(to: URL(fileURLWithPath: path))
            out += "render \(suffix): \(path)\n"
        }

        // Second capture through the drawRect machinery, which handles view
        // flipping exactly like on-screen drawing (layer.render can shift
        // unflipped custom views).
        if let cacheRep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: cacheRep)
            if let png = cacheRep.representation(using: .png, properties: [:]) {
                let path = NSTemporaryDirectory() + "comparetext-cache-\(suffix).png"
                try? png.write(to: URL(fileURLWithPath: path))
                out += "cache \(suffix): \(path)\n"
            }
        }
    }

    /// 0-based line numbers that carry any background-color highlight.
    private static func highlightedLines(_ pane: PaneController) -> Set<Int> {
        var lines = Set<Int>()
        guard let storage = pane.textView.textStorage else { return lines }
        let ns = pane.textView.string as NSString
        storage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            var line = 0
            var index = 0
            while index < range.location {
                let found = ns.range(of: "\n", range: NSRange(location: index, length: ns.length - index))
                if found.location == NSNotFound || found.location >= range.location { break }
                line += 1
                index = found.location + 1
            }
            lines.insert(line)
            // Adjacent same-color ranges merge; count every covered line
            // (the range's own trailing newline doesn't start a new one).
            if range.length > 1 {
                let interior = ns.substring(with: NSRange(location: range.location, length: range.length - 1))
                for scalar in interior.unicodeScalars where scalar == "\n" {
                    line += 1
                    lines.insert(line)
                }
            }
        }
        return lines
    }

    /// Ranges highlighted with the stronger (inline) alpha.
    private static func strongHighlightRanges(_ pane: PaneController) -> [NSRange] {
        var result: [NSRange] = []
        guard let storage = pane.textView.textStorage else { return result }
        storage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let color = value as? NSColor, color.alphaComponent > 0.3 {
                result.append(range)
            }
        }
        return result
    }

    private static func finish() {
        out += failures == 0 ? "ALL UI TESTS PASSED\n" : "\(failures) FAILURES\n"
        print("=== SELFTEST ===\n" + out + "=== END SELFTEST ===")
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
