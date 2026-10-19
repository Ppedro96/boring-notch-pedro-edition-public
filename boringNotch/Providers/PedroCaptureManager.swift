import AppKit
import Combine

@MainActor
final class PedroCaptureManager: ObservableObject {
    static let shared = PedroCaptureManager()
    @Published var draft: PedroCaptureDraft {
        didSet {
            if let data = try? JSONEncoder().encode(draft) { defaults.set(data, forKey: "pedroCaptureDraft") }
            feedback = nil
            isError = false
        }
    }
    @Published private(set) var recent: [URL]
    @Published private(set) var feedback: String?
    @Published private(set) var isError = false
    @Published private(set) var isSaving = false
    var onSaved: ((PedroCaptureDraft, URL) -> Void)?
    private let defaults: UserDefaults
    let store: PedroCaptureStore

    init(defaults: UserDefaults = .standard, store: PedroCaptureStore? = nil) {
        self.defaults = defaults
        if let store {
            self.store = store
        } else if let vaultPath = defaults.string(forKey: "pedro_capture_vault_path"), !vaultPath.isEmpty {
            self.store = PedroCaptureStore(vaultURL: URL(fileURLWithPath: NSString(string: vaultPath).expandingTildeInPath, isDirectory: true))
        } else {
            self.store = PedroCaptureStore(vaultURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/Obsidian Vault", isDirectory: true))
        }
        draft = defaults.data(forKey: "pedroCaptureDraft").flatMap {
            try? JSONDecoder().decode(PedroCaptureDraft.self, from: $0)
        } ?? PedroCaptureDraft()
        recent = (defaults.stringArray(forKey: "pedroCaptureRecent") ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func save() async {
        guard !isSaving else { return }
        isSaving = true
        let snapshot = draft
        let store = store
        defer { isSaving = false }
        do {
            let url = try await Task.detached(priority: .userInitiated) { try store.save(snapshot) }.value
            onSaved?(snapshot, url)
            recent.insert(url, at: 0)
            recent = Array(recent.prefix(15))
            defaults.set(recent.map(\.path), forKey: "pedroCaptureRecent")
            var titles = defaults.dictionary(forKey: "pedroCaptureTitles") as? [String: String] ?? [:]
            titles[url.path] = String(snapshot.displayTitle.prefix(70))
            titles = titles.filter { recent.contains(URL(fileURLWithPath: $0.key)) }
            defaults.set(titles, forKey: "pedroCaptureTitles")
            // Do not erase text typed while the filesystem write was in flight.
            if draft == snapshot { draft = PedroCaptureDraft() }
            isError = false
            feedback = "Link salvo · Pendente de análise"
        } catch {
            isError = true
            feedback = (error as? PedroCaptureStore.CaptureError)?.errorDescription
                ?? "Não foi possível salvar. Rascunho preservado."
        }
    }

    func pasteLink(from pasteboard: NSPasteboard = .general) {
        let protectedTypes = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                              "com.agilebits.onepassword"]
        guard !protectedTypes.contains(where: { pasteboard.types?.contains(NSPasteboard.PasteboardType($0)) == true }),
              let text = pasteboard.string(forType: .URL) ?? pasteboard.string(forType: .string),
              let url = try? PedroCaptureStore.sourceURL(text) else {
            feedback = "Nenhum link válido no clipboard"
            isError = true
            return
        }
        draft.link = url.absoluteString
    }

    func title(for url: URL) -> String {
        let titles = defaults.dictionary(forKey: "pedroCaptureTitles") as? [String: String] ?? [:]
        return titles[url.path] ?? String(url.lastPathComponent.prefix(19))
    }

    func open(_ url: URL) {
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: url.path)]
        guard let uri = components.url, NSWorkspace.shared.open(uri) else {
            feedback = "Não foi possível abrir o Obsidian"
            isError = true
            return
        }
    }

    func openInbox() {
        let url = FileManager.default.fileExists(atPath: store.inboxURL.path) ? store.inboxURL : store.vaultURL
        if !NSWorkspace.shared.open(url) { feedback = "Vault indisponível"; isError = true }
    }
}
