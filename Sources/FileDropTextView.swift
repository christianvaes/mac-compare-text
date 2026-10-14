import AppKit

/// Plain-text view that loads dropped files instead of inserting their
/// paths. Dropping text keeps the standard behavior.
///
/// The file URLs come from the drag pasteboard: macOS extends the app's
/// sandbox to exactly those files for the drop, so no file-access
/// entitlement is needed. A path typed or built by the app gets no such
/// grant and stays unreadable.
@MainActor
final class FileDropTextView: NSTextView {
    /// Called with the URLs of the files dropped on the view.
    var onFileDrop: (([URL]) -> Void)?

    private func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        return urls ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onFileDrop != nil && !fileURLs(sender).isEmpty ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onFileDrop != nil && !fileURLs(sender).isEmpty ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard let onFileDrop, !urls.isEmpty else { return super.performDragOperation(sender) }
        onFileDrop(urls)
        return true
    }
}
