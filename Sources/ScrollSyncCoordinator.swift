import AppKit

/// Line alignment between the two texts, built from the LCS-matched pairs of
/// the last comparison. Positions are continuous: line index + fraction.
struct AlignmentMap {
    let pairs: [(left: Int, right: Int)]
    let leftLineCount: Int
    let rightLineCount: Int

    /// Maps a position from one side to the other by interpolating between
    /// the surrounding anchors. Virtual endpoint anchors (0,0) and
    /// (leftCount,rightCount) make empty or fully disjoint texts degrade to
    /// plain proportional mapping without special cases.
    func map(_ position: Double, leftToRight: Bool) -> Double {
        let sourceCount = leftToRight ? leftLineCount : rightLineCount
        let targetCount = leftToRight ? rightLineCount : leftLineCount
        guard sourceCount > 0 else { return 0 }

        var low = (source: 0.0, target: 0.0)
        var high = (source: Double(sourceCount), target: Double(targetCount))

        if !pairs.isEmpty {
            // Last pair with source <= position (both components ascending).
            var lo = 0, hi = pairs.count - 1, found = -1
            while lo <= hi {
                let mid = (lo + hi) / 2
                let source = Double(leftToRight ? pairs[mid].left : pairs[mid].right)
                if source <= position {
                    found = mid
                    lo = mid + 1
                } else {
                    hi = mid - 1
                }
            }
            if found >= 0 {
                let pair = pairs[found]
                low = (Double(leftToRight ? pair.left : pair.right),
                       Double(leftToRight ? pair.right : pair.left))
            }
            if found + 1 < pairs.count {
                let pair = pairs[found + 1]
                high = (Double(leftToRight ? pair.left : pair.right),
                        Double(leftToRight ? pair.right : pair.left))
            }
        }

        let span = high.source - low.source
        let mapped = span <= 0
            ? low.target
            : low.target + (position - low.source) / span * (high.target - low.target)
        return min(max(0, mapped), Double(targetCount))
    }
}

/// Keeps both panes scrolled to corresponding content after a comparison.
///
/// Stateless position mapping (driver top position -> target position) on
/// every scroll notification: no deltas, no drift, clamping is always safe.
/// An edit bumps a pane's generation, which silently deactivates the sync
/// until the next comparison.
@MainActor
final class ScrollSyncCoordinator: NSObject {
    private let left: PaneController
    private let right: PaneController

    private var map: AlignmentMap?
    private var mapGenerations = (left: -1, right: -1)
    private var isSyncing = false
    private var lastDriverY: [ObjectIdentifier: CGFloat] = [:]

    /// User toggle ("Scroll together"); persisted by MainWindowController.
    var isEnabled = true

    private var isActive: Bool {
        isEnabled && map != nil
            && left.generation == mapGenerations.left
            && right.generation == mapGenerations.right
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

    func activate(matchedLines: [(left: Int, right: Int)],
                  leftLineCount: Int, rightLineCount: Int,
                  leftGeneration: Int, rightGeneration: Int) {
        map = AlignmentMap(pairs: matchedLines,
                           leftLineCount: leftLineCount,
                           rightLineCount: rightLineCount)
        mapGenerations = (leftGeneration, rightGeneration)
        lastDriverY = [:]
    }

    func invalidate() {
        map = nil
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
        guard isActive, let map else { return }
        guard let position = pane.topVerticalPosition() else { return }
        let target = pane === left ? right : left
        isSyncing = true
        target.scroll(toVerticalPosition: map.map(position, leftToRight: pane === left))
        isSyncing = false
    }

    @objc private func paneScrolled(_ notification: Notification) {
        guard !isSyncing, isActive, let map else { return }
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
        let originY = driver.scrollView.documentVisibleRect.origin.y
        let driverID = ObjectIdentifier(driver)
        if lastDriverY[driverID] == originY { return }
        lastDriverY[driverID] = originY

        guard let position = driver.topVerticalPosition() else { return }
        let target = driver === left ? right : left
        isSyncing = true
        target.scroll(toVerticalPosition: map.map(position, leftToRight: driver === left))
        isSyncing = false
    }
}
