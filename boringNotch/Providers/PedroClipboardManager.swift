import AppKit
import Combine

extension Notification.Name {
    static let pedroClipboardShouldFocusSearch = Notification.Name("pedroClipboardShouldFocusSearch")
}

@MainActor
final class PedroClipboardManager: ObservableObject {
    static let shared = PedroClipboardManager()

    @Published private(set) var history: PedroClipboardHistory
    @Published var query = ""
    @Published private(set) var feedback: String?
    @Published private(set) var feedbackIsError = false
    @Published private(set) var isCapturingArea = false

    private let pasteboard: NSPasteboard
    private let store: PedroClipboardStore
    private var timer: Timer?
    private var lastChangeCount: Int
    private weak var targetApplication: NSRunningApplication?

    var filteredItems: [PedroClipboardItem] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return history.items }
        return history.items.filter {
            $0.displayText.localizedCaseInsensitiveContains(value)
                || ($0.payloadText?.localizedCaseInsensitiveContains(value) ?? false)
        }
    }

    init(
        pasteboard: NSPasteboard = .general,
        store: PedroClipboardStore = PedroClipboardStore()
    ) {
        self.pasteboard = pasteboard
        self.store = store
        self.history = store.load()
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.capturePasteboardIfNeeded()
            }
        }
        capturePasteboardIfNeeded()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func prepareForPresentation(targetApplication: NSRunningApplication?) {
        self.targetApplication = targetApplication
        query = ""
        feedback = nil
        NotificationCenter.default.post(name: .pedroClipboardShouldFocusSearch, object: nil)
    }

    func togglePinned(_ item: PedroClipboardItem) {
        history.togglePinned(id: item.id)
        persist()
    }

    func remove(_ item: PedroClipboardItem) {
        history.remove(id: item.id)
        persist()
    }

    func clearUnpinned() {
        history.clearUnpinned()
        persist()
    }

    func choose(_ item: PedroClipboardItem, pasteAutomatically: Bool = true) {
        guard write(item, to: pasteboard) else {
            showFeedback("Não foi possível copiar")
            return
        }
        lastChangeCount = pasteboard.changeCount
        history.markUsed(id: item.id)
        persist()

        guard pasteAutomatically, AXIsProcessTrusted(), let targetApplication else {
            showFeedback("Copiado")
            return
        }

        closeFocusedNotchWindow()
        targetApplication.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            Self.postPasteShortcut()
        }
    }

    func cancelPresentation() {
        closeFocusedNotchWindow()
        targetApplication?.activate(options: [.activateIgnoringOtherApps])
    }

    func captureSelectedArea() async {
        guard !isCapturingArea else { return }
        isCapturingArea = true
        let changeCount = pasteboard.changeCount
        let windows = NSApp.windows.compactMap { $0 as? BoringNotchSkyLightWindow }.filter(\.isVisible)
        closeFocusedNotchWindow()
        // Hide every mirrored notch so none covers the selection or appears in the print.
        for window in windows {
            window.allowsKeyboardFocus = false
            window.resignKey()
            window.orderOut(nil)
        }
        defer {
            for window in windows { window.orderFrontRegardless() }
            isCapturingArea = false
        }
        do {
            try await Task.sleep(for: .milliseconds(200))
            let status = try await PedroAreaScreenshot().capture()
            if status == 0, pasteboard.changeCount != changeCount,
               NSImage(pasteboard: pasteboard) != nil {
                query = ""
                capturePasteboardIfNeeded()
                showFeedback("Print copiado")
            }
            // Escape leaves the clipboard untouched. Native capture errors use its own dialog.
        } catch {
            showFeedback("Falha no print", isError: true)
        }
    }

    func imageURL(for item: PedroClipboardItem) -> URL? {
        store.imageURL(for: item)
    }

    private func capturePasteboardIfNeeded() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard !containsTransientData else { return }

        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let now = Date()

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let fileURL = urls.first(where: \.isFileURL) {
            history.insert(.file(url: fileURL, sourceBundleIdentifier: source, capturedAt: now))
            persist()
            return
        }

        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            let fingerprint = PedroClipboardItem.fingerprint(kind: .image, payload: png)
            let filename = "\(fingerprint).png"
            try? store.saveImage(png, filename: filename)
            history.insert(
                .image(
                    filename: filename,
                    pngData: png,
                    sourceBundleIdentifier: source,
                    capturedAt: now
                )
            )
            persist()
            return
        }

        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            history.insert(.text(text, sourceBundleIdentifier: source, capturedAt: now))
            persist()
        }
    }

    private var containsTransientData: Bool {
        let ignored = [
            NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
            NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
            NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
        ]
        return ignored.contains { pasteboard.types?.contains($0) == true }
    }

    private func write(_ item: PedroClipboardItem, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        switch item.kind {
        case .text, .link:
            guard let value = item.payloadText else { return false }
            return pasteboard.setString(value, forType: .string)
        case .file:
            guard let path = item.filePath else { return false }
            return pasteboard.writeObjects([URL(fileURLWithPath: path) as NSURL])
        case .image:
            guard let url = store.imageURL(for: item),
                  let image = NSImage(contentsOf: url)
            else {
                return false
            }
            return pasteboard.writeObjects([image])
        }
    }

    private func closeFocusedNotchWindow() {
        if let window = NSApp.keyWindow as? BoringNotchSkyLightWindow {
            window.allowsKeyboardFocus = false
            window.resignKey()
        }
        NotificationCenter.default.post(name: .pedroClipboardShouldClose, object: nil)
    }

    private func persist() {
        try? store.save(history)
    }

    private func showFeedback(_ value: String, isError: Bool = false) {
        feedback = value
        feedbackIsError = isError
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.feedback == value {
                self?.feedback = nil
            }
        }
    }

    private static func postPasteShortcut() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}

extension Notification.Name {
    static let pedroClipboardShouldClose = Notification.Name("pedroClipboardShouldClose")
}
