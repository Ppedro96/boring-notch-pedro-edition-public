import Foundation

struct PedroClipboardStore {
    let directoryURL: URL

    private var historyURL: URL {
        directoryURL.appendingPathComponent("history.json")
    }

    var imagesDirectoryURL: URL {
        directoryURL.appendingPathComponent("Images", isDirectory: true)
    }

    init(fileManager: FileManager = .default) {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        self.directoryURL = baseURL
            .appendingPathComponent("boringNotch", isDirectory: true)
            .appendingPathComponent("Clipboard", isDirectory: true)
    }

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    func load(fileManager: FileManager = .default) -> PedroClipboardHistory {
        guard let data = try? Data(contentsOf: historyURL),
              var history = try? Self.decoder.decode(PedroClipboardHistory.self, from: data)
        else {
            return PedroClipboardHistory()
        }
        history.prune()
        removeOrphanedImages(for: history, fileManager: fileManager)
        return history
    }

    func save(_ history: PedroClipboardHistory, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: imagesDirectoryURL, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(history)
        try data.write(to: historyURL, options: .atomic)
        removeOrphanedImages(for: history, fileManager: fileManager)
    }

    func saveImage(_ data: Data, filename: String, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: imagesDirectoryURL, withIntermediateDirectories: true)
        try data.write(to: imagesDirectoryURL.appendingPathComponent(filename), options: .atomic)
    }

    func imageURL(for item: PedroClipboardItem) -> URL? {
        guard let filename = item.imageFilename else { return nil }
        return imagesDirectoryURL.appendingPathComponent(filename)
    }

    private func removeOrphanedImages(for history: PedroClipboardHistory, fileManager: FileManager) {
        let retained = Set(history.items.compactMap(\.imageFilename))
        guard let files = try? fileManager.contentsOfDirectory(
            at: imagesDirectoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for file in files where !retained.contains(file.lastPathComponent) {
            try? fileManager.removeItem(at: file)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
