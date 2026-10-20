import AppKit

/// Keeps both panes scrolled to corresponding content after a comparison.
///
/// The comparison pads the shorter side of every difference (see
/// MainWindowController.alignPanes), so matched lines sit at the same height
/// in both documents and following is plain: the same vertical offset. No
/// deltas, no drift, clamping is always safe. An edit bumps a pane's
/// generation, which silently deactivates the sync until the next comparison.
@MainActor
final class ScrollSyncCoordinator: NSObject {
    private let left: PaneController
    private let right: PaneController

    private var isAligned = false
    private var alignedGenerations = (left: -1, right: -1)
    private var isSyncing = false
    private var lastDriverOrigin: [ObjectIdentifier: CGPoint] = [:]

    /// User toggle ("Scroll together"); persisted by MainWindowController.
    var isEnabled = true
    /// Also follow horizontal scrolling (when lines don't wrap).
    var syncsHorizontally = false

    private var isActive: Bool {
        isEnabled && isAligned
            && left.generation == alignedGenerations.left
            && right.generation == alignedGenerations.right
    }

    init(left: PaneController, right: PaneController) {
        self.left = left
        self.right = right
        super.init()
        for pane in [left, right] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(paneScrolled),
                name: NSView.boundsDidChangeNotification,
                object: pane.scrollView.contentView
            )
        }
    }

    func activate(leftGeneration: Int, rightGeneration: Int) {
        isAligned = true
        alignedGenerations = (leftGeneration, rightGeneration)
        lastDriverOrigin = [:]
    }

    func invalidate() {
        isAligned = false
    }

    /// Runs programmatic scrolling (e.g. difference navigation) without the
    /// sync fighting it.
    func performWithoutSync(_ body: () -> Void) {
        isSyncing = true
        body()
        isSyncing = false
    }

    /// One-shot alignment of the other pane to the given pane.
    func alignNow(drivenBy pane: PaneController) {
        guard isActive else { return }
        follow(pane, horizontalOffset: syncsHorizontally ? pane.scrollView.documentVisibleRect.origin.x : nil)
    }

    /// Scrolls the other pane to the driver's offset.
    private func follow(_ driver: PaneController, horizontalOffset: CGFloat?) {
        let target = driver === left ? right : left
        isSyncing = true
        target.scroll(toDocumentY: driver.scrollView.documentVisibleRect.minY, horizontalOffset: horizontalOffset)
        isSyncing = false
    }

    @objc private func paneScrolled(_ notification: Notification) {
        guard !isSyncing, isActive else { return }
        guard let clipView = notification.object as? NSClipView else { return }

        let driver: PaneController
        if clipView === left.scrollView.contentView {
            driver = left
        } else if clipView === right.scrollView.contentView {
            driver = right
        } else {
            return
        }

        // Bounds notifications also fire for pure size changes (find bar,
        // live resize); skip when the origin didn't move.
        let origin = driver.scrollView.documentVisibleRect.origin
        let driverID = ObjectIdentifier(driver)
        if lastDriverOrigin[driverID] == origin { return }
        lastDriverOrigin[driverID] = origin

        follow(driver, horizontalOffset: syncsHorizontally ? origin.x : nil)
    }
}
