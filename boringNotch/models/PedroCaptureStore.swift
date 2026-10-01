import Foundation

struct PedroCaptureDraft: Codable, Equatable {
    var link: String
    var title: String
    var body: String
    var isEmpty: Bool { link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var sourceURL: URL? { try? PedroCaptureStore.sourceURL(link) }
    var displayTitle: String {
        let title = title.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? (sourceURL?.host ?? "Link") : title
    }

    init(link: String = "", title: String = "", body: String = "") {
        self.link = link
        self.title = title
        self.body = body
    }

    private enum CodingKeys: String, CodingKey { case link, title, body }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Drafts from the original text capture remain available as context.
        link = try container.decodeIfPresent(String.self, forKey: .link) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
    }
}

struct PedroCaptureStore {
    let vaultURL: URL
    var inboxURL: URL { vaultURL.appendingPathComponent("inbox/notch", isDirectory: true) }

    enum CaptureError: LocalizedError {
        case empty, invalidLink, missingVault, collision
        var errorDescription: String? {
            switch self {
            case .empty: "Adicione um link"
            case .invalidLink: "Link inválido. Use um endereço HTTP ou HTTPS."
            case .missingVault: "Vault indisponível. Rascunho preservado."
            case .collision: "Arquivo já existe. Tente salvar novamente."
            }
        }
    }

    static func sourceURL(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CaptureError.empty }
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              components.user == nil, components.password == nil,
              let url = components.url else { throw CaptureError.invalidLink }
        return url
    }

    func save(_ draft: PedroCaptureDraft, date: Date = Date(), id: UUID = UUID()) throws -> URL {
        let source = try Self.sourceURL(draft.link)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: vaultURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw CaptureError.missingVault }
        try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = formatter.string(from: date)
        let file = inboxURL.appendingPathComponent("\(stamp) - \(id.uuidString).md")
        guard !FileManager.default.fileExists(atPath: file.path) else { throw CaptureError.collision }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let quotedURL = String(decoding: try encoder.encode(source.absoluteString), as: UTF8.self)
        let content = """
        ---
        tipo: link
        status: pendente
        projeto: inbox
        tags: [inbox, para-analisar]
        origem: boring-notch
        url: \(quotedURL)
        data: \(ISO8601DateFormatter().string(from: date))
        sync: false
        ---

        # \(draft.displayTitle)

        ## Link
        <\(source.absoluteString)>

        \(draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "## Observação\n" + draft.body)

        """
        try Data(content.utf8).write(to: file, options: .atomic)
        return file
    }
}
