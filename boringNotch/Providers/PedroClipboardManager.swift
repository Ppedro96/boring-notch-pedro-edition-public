import AppKit
import Combine
import OSLog

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

    // Installed only by the lifecycle continuity adapter; local fixtures remain independent.
    var onCapture: ((PedroClipboardItem) -> Void)?
    var onPin: ((PedroClipboardItem, Bool) -> Void)?
    var onRemove: ((PedroClipboardItem) -> Void)?
    var onManualCopy: ((PedroClipboardItem) -> Void)?
    private var remoteFingerprint: String?
    private(set) var lastLocalChangeAt: Double = 0
    var contentGeneration = 0
    var currentChangeCount: Int { pasteboard.changeCount }
    private let pasteboard: NSPasteboard
    private let store: PedroClipboardStore
    private var timer: Timer?
    private var lastChangeCount: Int
    private weak var targetApplication: NSRunningApplication?
    private let logger = Logger(subsystem: "theboringteam.boringnotch", category: "PedroAreaScreenshot")

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
        onPin?(item, !item.isPinned)
        history.togglePinned(id: item.id)
        persist()
    }

    func remove(_ item: PedroClipboardItem) {
        onRemove?(item)
        history.remove(id: item.id)
        persist()
    }

    func clearUnpinned() {
        for item in history.items where !item.isPinned { onRemove?(item) }
        history.clearUnpinned()
        persist()
    }

    func choose(_ item: PedroClipboardItem, pasteAutomatically: Bool = true) {
        guard write(item, to: pasteboard) else {
            showFeedback("Não foi possível copiar")
            return
        }
        lastChangeCount = pasteboard.changeCount
        contentGeneration += 1
        lastLocalChangeAt = Date().timeIntervalSince1970
        remoteFingerprint = nil
        onManualCopy?(item)
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
        guard CGPreflightScreenCaptureAccess() else {
            presentCapturePermissionAlert()
            return
        }
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
            let result = try await PedroAreaScreenshot().capture()
            let hasNewImage = pasteboard.changeCount != changeCount && NSImage(pasteboard: pasteboard) != nil
            switch result.outcome(hasNewImage: hasNewImage) {
            case .copied:
                query = ""
                capturePasteboardIfNeeded()
                showFeedback("Print copiado")
                logger.notice("Area capture copied an image to the clipboard")
            case .cancelled:
                logger.info("Area capture cancelled; clipboard preserved")
            case .failed:
                logger.error("Area capture failed: status=\(result.status), diagnostic=\(result.diagnostic, privacy: .public)")
                if !CGPreflightScreenCaptureAccess() {
                    presentCapturePermissionAlert()
                } else {
                    showFeedback("Falha no print", isError: true)
                }
            }
        } catch {
            logger.error("Area capture could not launch: \(error.localizedDescription, privacy: .public)")
            showFeedback("Falha no print", isError: true)
        }
    }

    private func presentCapturePermissionAlert() {
        showFeedback("Autorize a captura", isError: true)
        logger.warning("Area capture blocked: ScreenRecording=false")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Autorize a captura de tela"
        alert.informativeText = "O macOS não autorizou esta versão do Insight Notch. Em Privacidade e Segurança > Gravação de Tela e Áudio do Sistema, permita o Insight Notch e reabra o app. Se ele já estiver ativado, remova a entrada antiga e adicione /Applications/Insight Notch.app novamente."
        alert.addButton(withTitle: "Abrir Ajustes")
        alert.addButton(withTitle: "Cancelar")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func imageURL(for item: PedroClipboardItem) -> URL? {
        store.imageURL(for: item)
    }

    private func capturePasteboardIfNeeded() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        contentGeneration += 1
        lastLocalChangeAt = Date().timeIntervalSince1970
        guard !containsTransientData else { return }

        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let now = Date()

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let fileURL = urls.first(where: \.isFileURL) {
            remoteFingerprint = nil
            history.insert(.file(url: fileURL, sourceBundleIdentifier: source, capturedAt: now))
            persist()
            return
        }

        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = pasteboard.data(forType: .png) ?? bitmap.representation(using: .png, properties: [:]) {
            let fingerprint = PedroClipboardItem.fingerprint(kind: .image, payload: png)
            guard PedroContinuityPolicy.shouldCapture(fingerprint: fingerprint, suppressed: remoteFingerprint) else { return }
            remoteFingerprint = nil
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
            if let item = history.items.first(where: { $0.fingerprint == fingerprint }) { onCapture?(item) }
            return
        }

        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            let item = PedroClipboardItem.text(text, sourceBundleIdentifier: source, capturedAt: now)
            guard PedroContinuityPolicy.shouldCapture(fingerprint: item.fingerprint, suppressed: remoteFingerprint) else { return }
            remoteFingerprint = nil
            history.insert(item)
            onCapture?(item)
            persist()
        }
    }

    private var containsTransientData: Bool {
        PedroContinuityPolicy.isPrivate(types: pasteboard.types?.map(\.rawValue) ?? [])
    }

    /// Remote writes never run the local publication hook or synthesize a paste keystroke.
    func acceptShared(text: String?, png: Data?, capturedAt: Date, pinned: Bool, activate: Bool, persistChanges: Bool = true) {
        let item: PedroClipboardItem
        if let png {
            let name = PedroClipboardItem.fingerprint(kind: .image, payload: png) + ".png"
            guard (try? store.saveImage(png, filename: name)) != nil else { return }
            item = .image(filename: name, pngData: png, sourceBundleIdentifier: nil, capturedAt: capturedAt).settingPinned(pinned)
        } else if let text {
            item = .text(text, sourceBundleIdentifier: nil, capturedAt: capturedAt, isPinned: pinned)
        } else { return }
        history.insert(item)
        if let existing = history.items.first(where: { $0.fingerprint == item.fingerprint }), existing.isPinned != pinned { history.togglePinned(id: existing.id) }
        if activate, write(item, to: pasteboard) { lastChangeCount = pasteboard.changeCount; contentGeneration += 1; remoteFingerprint = item.fingerprint }
        if persistChanges { persist() }
    }
    func saveSharedBatch() { persist() }
    func sharedMetadata(fingerprint: String, pinned: Bool?) {
        guard let item = history.items.first(where: { $0.fingerprint == fingerprint }) else { return }
        if let pinned { if item.isPinned != pinned { history.togglePinned(id: item.id) } }
        else { history.remove(id: item.id) }
        persist()
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
            guard let url = store.imageURL(for: item), let png = try? Data(contentsOf: url) else { return false }
            return pasteboard.setData(png, forType: .png)
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
