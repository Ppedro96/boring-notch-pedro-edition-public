import AppKit

final class PedroTransferCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

enum PedroTransferError: LocalizedError {
    case unsupported, sourceChanged, cancelled
    var errorDescription: String? {
        switch self {
        case .unsupported: "Selecione um arquivo regular, nao uma pasta ou link."
        case .sourceChanged: "O arquivo de origem mudou durante a copia."
        case .cancelled: "Copia cancelada"
        }
    }
}

enum PedroFileCopy {
    static func copy(source: URL, destination: URL, cancellation: PedroTransferCancellation,
                     progress: (Int64, Int64) -> Void) throws -> URL {
        let fm = FileManager.default
        let original = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard original.isRegularFile == true, original.isSymbolicLink != true else { throw PedroTransferError.unsupported }
        let total = Int64(original.fileSize ?? 0)
        let temporary = destination.appendingPathComponent(".notch-" + UUID().uuidString + ".part")
        guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        defer { if fm.fileExists(atPath: temporary.path) { try? fm.removeItem(at: temporary) } }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        var copied: Int64 = 0
        progress(0, total)
        while true {
            if cancellation.isCancelled { throw PedroTransferError.cancelled }
            guard let data = try input.read(upToCount: 4 * 1024 * 1024), !data.isEmpty else { break }
            try output.write(contentsOf: data)
            copied += Int64(data.count)
            progress(copied, total)
        }
        try output.synchronize()
        let final = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard copied == total, final.fileSize == original.fileSize,
              final.contentModificationDate == original.contentModificationDate else { throw PedroTransferError.sourceChanged }
        if cancellation.isCancelled { throw PedroTransferError.cancelled }
        var target = destination.appendingPathComponent(source.lastPathComponent)
        var counter = 1
        while fm.fileExists(atPath: target.path) {
            let name = source.deletingPathExtension().lastPathComponent + " (\(counter))"
            target = destination.appendingPathComponent(source.pathExtension.isEmpty ? name : name + "." + source.pathExtension)
            counter += 1
        }
        try fm.moveItem(at: temporary, to: target)
        return target
    }
}

@MainActor
final class PedroTransferService: ObservableObject {
    static let shared = PedroTransferService()
    @Published private(set) var activeIDs = Set<String>()
    @Published private(set) var choosingFiles = false
    private var cancellations: [String: PedroTransferCancellation] = [:]

    func chooseFiles() {
        guard !choosingFiles else { return }
        choosingFiles = true
        defer { choosingFiles = false }
        NSApp.activate(ignoringOtherApps: true)
        let source = NSOpenPanel()
        source.title = "Arquivos para copiar"
        source.allowsMultipleSelection = true
        source.canChooseDirectories = false
        guard source.runModal() == .OK else { return }
        let destination = NSOpenPanel()
        destination.title = "Pasta de destino"
        destination.canChooseFiles = false
        destination.canChooseDirectories = true
        destination.canCreateDirectories = true
        guard destination.runModal() == .OK, let folder = destination.url else { return }
        for url in source.urls { start(source: url, destination: folder) }
    }

    func cancel(_ id: String) { cancellations[id]?.cancel() }

    func start(source: URL, destination: URL) {
        let id = "copy-" + UUID().uuidString
        let cancellation = PedroTransferCancellation()
        cancellations[id] = cancellation
        activeIDs.insert(id)
        let started = Date()
        let initial = PedroActivityEvent(id: id, revision: "running", kind: "transfer", title: source.lastPathComponent,
            detail: destination.lastPathComponent, state: .running, updatedAt: started, progress: 0, url: nil, outputPath: nil)
        PedroActivityManager.shared.record(initial)
        Task {
            let result: Result<URL, Error> = await Task.detached(priority: .utility) {
                var lastReport = Date.distantPast
                return Result {
                    try PedroFileCopy.copy(source: source, destination: destination, cancellation: cancellation) { done, total in
                        let now = Date()
                        guard now.timeIntervalSince(lastReport) >= 0.3 else { return }
                        lastReport = now
                        let elapsed = max(0.1, now.timeIntervalSince(started))
                        let speed = Double(done) / elapsed
                        let remaining = speed > 0 ? max(0, Int(Double(total - done) / speed)) : 0
                        var event = initial
                        event.updatedAt = now
                        event.progress = total > 0 ? min(99, 100 * Double(done) / Double(total)) : nil
                        event.detail = ByteCountFormatter.string(fromByteCount: done, countStyle: .file) + " / " +
                            ByteCountFormatter.string(fromByteCount: total, countStyle: .file) +
                            (speed > 0 ? " · \(remaining)s restantes" : "")
                        let update = event
                        Task { @MainActor in PedroActivityManager.shared.record(update) }
                    }
                }
            }.value
            var event = initial
            event.revision = "finished"
            event.updatedAt = Date()
            switch result {
            case .success(let url):
                event.state = .completed; event.progress = 100
                event.outputPath = url.path; event.detail = "Copiado para " + destination.lastPathComponent
            case .failure(let error):
                event.state = cancellation.isCancelled ? .cancelled : .failed
                event.progress = nil; event.detail = error.localizedDescription
            }
            PedroActivityManager.shared.record(event)
            activeIDs.remove(id)
            cancellations.removeValue(forKey: id)
        }
    }
}
