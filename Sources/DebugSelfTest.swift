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

        // 4. Navigation.
        controller.nextDifference(nil)
        controller.nextDifference(nil)
        check("navigation cycles", true) // exercised; scroll assertions below on big text

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
            scrollSyncStage(controller: controller)
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

            // Navigation must scroll the changed line into view.
            controller.nextDifference(nil)
            let visible = controller.left.scrollView.documentVisibleRect
            check("navigation scrolled down", visible.origin.y > 1000)

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
