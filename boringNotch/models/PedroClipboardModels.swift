import CryptoKit
import Foundation

enum PedroClipboardKind: String, Codable, CaseIterable {
    case text
    case link
    case image
    case file
}

struct PedroClipboardItem: Codable, Identifiable, Equatable {
    let id: UUID
    let kind: PedroClipboardKind
    let displayText: String
    let payloadText: String?
    let filePath: String?
    let imageFilename: String?
    let sourceBundleIdentifier: String?
    let capturedAt: Date
    let lastUsedAt: Date?
    let isPinned: Bool
    let fingerprint: String

    init(
        id: UUID = UUID(),
        kind: PedroClipboardKind,
        displayText: String,
        payloadText: String? = nil,
        filePath: String? = nil,
        imageFilename: String? = nil,
        sourceBundleIdentifier: String? = nil,
        capturedAt: Date = Date(),
        lastUsedAt: Date? = nil,
        isPinned: Bool = false,
        fingerprint: String
    ) {
        self.id = id
        self.kind = kind
        self.displayText = displayText
        self.payloadText = payloadText
        self.filePath = filePath
        self.imageFilename = imageFilename
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.capturedAt = capturedAt
        self.lastUsedAt = lastUsedAt
        self.isPinned = isPinned
        self.fingerprint = fingerprint
    }

    static func text(
        _ text: String,
        sourceBundleIdentifier: String?,
        capturedAt: Date = Date(),
        isPinned: Bool = false
    ) -> PedroClipboardItem {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: PedroClipboardKind = URL(string: trimmed).flatMap(\.scheme) == nil ? .text : .link
        return PedroClipboardItem(
            kind: kind,
            displayText: trimmed,
            payloadText: text,
            sourceBundleIdentifier: sourceBundleIdentifier,
            capturedAt: capturedAt,
            isPinned: isPinned,
            fingerprint: fingerprint(kind: kind, payload: Data(text.utf8))
        )
    }

    static func image(
        filename: String,
        pngData: Data,
        sourceBundleIdentifier: String?,
        capturedAt: Date = Date()
    ) -> PedroClipboardItem {
        PedroClipboardItem(
            kind: .image,
            displayText: "Imagem copiada",
            imageFilename: filename,
            sourceBundleIdentifier: sourceBundleIdentifier,
            capturedAt: capturedAt,
            fingerprint: fingerprint(kind: .image, payload: pngData)
        )
    }

    static func file(
        url: URL,
        sourceBundleIdentifier: String?,
        capturedAt: Date = Date()
    ) -> PedroClipboardItem {
        PedroClipboardItem(
            kind: .file,
            displayText: url.lastPathComponent,
            filePath: url.path,
            sourceBundleIdentifier: sourceBundleIdentifier,
            capturedAt: capturedAt,
            fingerprint: fingerprint(kind: .file, payload: Data(url.standardizedFileURL.path.utf8))
        )
    }

    static func fingerprint(kind: PedroClipboardKind, payload: Data) -> String {
        let digest = SHA256.hash(data: Data(kind.rawValue.utf8) + payload)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func settingPinned(_ pinned: Bool) -> PedroClipboardItem {
        PedroClipboardItem(
            id: id,
            kind: kind,
            displayText: displayText,
            payloadText: payloadText,
            filePath: filePath,
            imageFilename: imageFilename,
            sourceBundleIdentifier: sourceBundleIdentifier,
            capturedAt: capturedAt,
            lastUsedAt: lastUsedAt,
            isPinned: pinned,
            fingerprint: fingerprint
        )
    }

    func refreshed(from newer: PedroClipboardItem) -> PedroClipboardItem {
        PedroClipboardItem(
            id: id,
            kind: newer.kind,
            displayText: newer.displayText,
            payloadText: newer.payloadText,
            filePath: newer.filePath,
            imageFilename: newer.imageFilename,
            sourceBundleIdentifier: newer.sourceBundleIdentifier,
            capturedAt: newer.capturedAt,
            lastUsedAt: newer.lastUsedAt,
            isPinned: isPinned || newer.isPinned,
            fingerprint: fingerprint
        )
    }

    func used(at date: Date) -> PedroClipboardItem {
        PedroClipboardItem(
            id: id,
            kind: kind,
            displayText: displayText,
            payloadText: payloadText,
            filePath: filePath,
            imageFilename: imageFilename,
            sourceBundleIdentifier: sourceBundleIdentifier,
            capturedAt: capturedAt,
            lastUsedAt: date,
            isPinned: isPinned,
            fingerprint: fingerprint
        )
    }
}

struct PedroClipboardHistory: Codable, Equatable {
    private(set) var items: [PedroClipboardItem]

    init(items: [PedroClipboardItem] = []) {
        self.items = items
    }

    mutating func insert(
        _ item: PedroClipboardItem,
        now: Date = Date(),
        regularLimit: Int = 100,
        retentionDays: Int = 14
    ) {
        let existing = items.first { $0.fingerprint == item.fingerprint }
        items.removeAll { $0.fingerprint == item.fingerprint }
        items.insert(existing?.refreshed(from: item) ?? item, at: 0)
        prune(now: now, regularLimit: regularLimit, retentionDays: retentionDays)
    }

    mutating func togglePinned(id: UUID, now: Date = Date()) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index] = items[index].settingPinned(!items[index].isPinned)
        sort()
        prune(now: now)
    }

    mutating func markUsed(id: UUID, at date: Date = Date()) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index).used(at: date)
        items.insert(item, at: item.isPinned ? items.prefix(while: \.isPinned).count : 0)
        sort()
    }

    mutating func remove(id: UUID) {
        items.removeAll { $0.id == id }
    }

    mutating func clearUnpinned() {
        items.removeAll { !$0.isPinned }
    }

    mutating func prune(
        now: Date = Date(),
        regularLimit: Int = 100,
        retentionDays: Int = 14
    ) {
        let cutoff = now.addingTimeInterval(-TimeInterval(retentionDays * 24 * 60 * 60))
        var regularCount = 0
        items = items
            .filter { $0.isPinned || $0.capturedAt >= cutoff }
            .filter { item in
                guard !item.isPinned else { return true }
                defer { regularCount += 1 }
                return regularCount < regularLimit
            }
        sort()
    }

    private mutating func sort() {
        items.sort {
            if $0.isPinned != $1.isPinned {
                return $0.isPinned
            }
            return ($0.lastUsedAt ?? $0.capturedAt) > ($1.lastUsedAt ?? $1.capturedAt)
        }
    }
}
