import AppKit

/// A file writer must advertise a file, never its local path as plain text.
enum ShelfFileDragWriter {
    static func make(url: URL) -> (any NSPasteboardWriting)? {
        guard url.isFileURL else { return nil }
        return url as NSURL
    }
}
