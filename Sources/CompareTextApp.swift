import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = shared
        app.setActivationPolicy(.regular)
        app.run()
    }

    private(set) var mainController: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        mainController = MainWindowController()
        buildMenu()
        mainController.show()
        NSApp.activate(ignoringOtherApps: true)

        DebugSelfTest.runIfRequested(controller: mainController)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Small custom about window: icon, name, version, build date and a
    /// link to the website. The build date is stamped into Info.plist by
    /// build.sh.
    private(set) var aboutWindow: NSWindow?

    @objc func showAbout(_ sender: Any?) {
        // Rebuild each time so the rasterized text follows the current theme.
        aboutWindow?.close()
        aboutWindow = buildAboutWindow()
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow?.center()
        aboutWindow?.makeKeyAndOrderFront(nil)
        // macOS 26 can drop layer contents of freshly shown views; nudge once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.aboutWindow?.contentView.map(Self.markTreeDirty)
        }
    }

    private func buildAboutWindow() -> NSWindow {
        let width: CGFloat = 300
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = L10n.about
        window.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 320))

        let icon = NSImageView(frame: NSRect(x: (width - 110) / 2, y: 185, width: 110, height: 110))
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(icon)

        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let buildDate = Bundle.main.object(forInfoDictionaryKey: "BuildDate") as? String ?? "—"

        // The text is pre-rendered to a bitmap and shown in an NSImageView:
        // both label fields and live custom drawing proved unreliable in a
        // freshly created window on macOS 26, while image views composite
        // correctly.
        let infoSize = NSSize(width: width - 20, height: 85)
        let info = NSImageView(frame: NSRect(x: 10, y: 95, width: infoSize.width, height: infoSize.height))
        info.image = Self.renderInfoImage(size: infoSize, lines: [
            (L10n.appName, NSFont.systemFont(ofSize: 16, weight: .semibold), .labelColor),
            ("\(L10n.version) \(shortVersion) (build \(buildNumber))", NSFont.systemFont(ofSize: 11), .secondaryLabelColor),
            ("\(L10n.builtOn) \(buildDate)", NSFont.systemFont(ofSize: 11), .secondaryLabelColor),
        ])
        content.addSubview(info)

        let link = NSButton(title: "www.cvaes.nl", target: self, action: #selector(openWebsite(_:)))
        link.isBordered = false
        link.contentTintColor = .linkColor
        link.font = .systemFont(ofSize: 12)
        link.sizeToFit()
        link.frame.origin = NSPoint(x: (width - link.frame.width) / 2, y: 62)
        content.addSubview(link)

        window.contentView = content
        return window
    }

    @objc private func openWebsite(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://www.cvaes.nl")!)
    }

    /// Rasterizes the about text lines (centered, top to bottom) at 2x.
    private static func renderInfoImage(size: NSSize, lines: [(String, NSFont, NSColor)]) -> NSImage? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.scaleBy(x: 2, y: 2)
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            var y = size.height
            for (text, font, color) in lines {
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let label = text as NSString
                let textSize = label.size(withAttributes: attributes)
                y -= textSize.height
                label.draw(at: NSPoint(x: (size.width - textSize.width) / 2, y: y), withAttributes: attributes)
                y -= 6
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        if ProcessInfo.processInfo.environment["COMPARETEXT_SELFTEST"] == "1",
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "comparetext-aboutinfo.png"))
        }

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    private static func markTreeDirty(_ view: NSView) {
        view.needsDisplay = true
        for subview in view.subviews {
            markTreeDirty(subview)
        }
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        let about = NSMenuItem(title: L10n.about, action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.quit,
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(title: L10n.editMenu, action: nil, keyEquivalent: "")
        mainMenu.addItem(editItem)
        let edit = NSMenu(title: L10n.editMenu)
        edit.addItem(withTitle: L10n.undo, action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L10n.redo, action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: L10n.cut, action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L10n.copy, action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L10n.paste, action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L10n.delete, action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: L10n.selectAll, action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = NSMenuItem(title: L10n.find,
                              action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        edit.addItem(find)
        editItem.submenu = edit

        let compareItem = NSMenuItem(title: L10n.compareMenu, action: nil, keyEquivalent: "")
        mainMenu.addItem(compareItem)
        let compare = NSMenu(title: L10n.compareMenu)
        let compareEntry = NSMenuItem(title: L10n.compare,
                                      action: #selector(MainWindowController.compare(_:)), keyEquivalent: "\r")
        compareEntry.keyEquivalentModifierMask = [.command]
        compare.addItem(compareEntry)
        compare.addItem(.separator())
        compare.addItem(withTitle: L10n.nextDifference,
                        action: #selector(MainWindowController.nextDifference(_:)), keyEquivalent: "]")
        compare.addItem(withTitle: L10n.previousDifference,
                        action: #selector(MainWindowController.previousDifference(_:)), keyEquivalent: "[")
        compare.addItem(.separator())
        let swap = NSMenuItem(title: L10n.swapTexts,
                              action: #selector(MainWindowController.swapTexts(_:)), keyEquivalent: "t")
        swap.keyEquivalentModifierMask = [.command, .shift]
        compare.addItem(swap)
        let clear = NSMenuItem(title: L10n.clearAll,
                               action: #selector(MainWindowController.clearAll(_:)), keyEquivalent: "k")
        clear.keyEquivalentModifierMask = [.command, .shift]
        compare.addItem(clear)
        compareItem.submenu = compare

        // The window controller is not in the responder chain; target it
        // directly.
        for item in compare.items where item.action != nil {
            item.target = mainController
        }
        NSApp.mainMenu = mainMenu
    }
}
