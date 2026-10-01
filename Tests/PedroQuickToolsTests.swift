import AppKit

@main
struct PedroQuickToolsTests {
    @MainActor
    static func main() async throws {
        testMoonlightCatalog()
        try testCaptureLinks()
        try testCaptureStore()
        try await testCaptureDraft()
        print("PedroQuickToolsTests passed")
    }

    static func testMoonlightCatalog() {
        var prefs: [String: Any] = [
            "hosts.size": 3,
            "hosts.1.uuid": "paired-id",
            "hosts.1.hostname": "X99-DUAL",
            "hosts.1.srvcert": Data([1]),
            "hosts.1.manualaddress": "192.0.2.10",
            "hosts.1.apps.size": 3,
            "hosts.1.apps.1.name": "Steam Big Picture",
            "hosts.1.apps.2.name": "Desktop",
            "hosts.1.apps.3.name": "Hidden",
            "hosts.1.apps.3.hidden": true,
            "hosts.2.uuid": "unpaired",
            "hosts.2.hostname": "Not paired",
            "hosts.3.uuid": "paired-id",
            "hosts.3.hostname": "Duplicate",
            "hosts.3.srvcert": Data([1])
        ]
        let hosts = PedroMoonlightCatalog.parse(prefs)
        precondition(hosts.count == 1)
        precondition(hosts[0].apps == ["Steam Big Picture", "Desktop"])
        precondition(hosts[0].preferredApp == "Desktop")
        precondition(hosts[0].arguments(app: "Steam Big Picture") == ["stream", "paired-id", "Steam Big Picture"])
        precondition(hosts[0].arguments(app: "unknown") == nil)
        precondition(hosts[0].arguments(app: "Desktop", profile: .light)?.contains("8000") == true)
        precondition(hosts[0].arguments(app: "Desktop", profile: .light)?.prefix(3) == ["stream", "paired-id", "Desktop"])
        precondition(PedroMoonlightCatalog.parse([:]).isEmpty)
        prefs["hosts.1.apps.size"] = -1
        precondition(PedroMoonlightCatalog.parse(prefs)[0].apps.isEmpty)
        prefs["hosts.size"] = -1
        precondition(PedroMoonlightCatalog.parse(prefs).isEmpty)
    }

    static func testCaptureStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PedroCaptureStore(vaultURL: root)
        let draft = PedroCaptureDraft(link: "https://example.com/post?q=1#section",
                                      title: "../../safe\nTitle", body: "First line\n\n- [ ] Task\n[[Link]]")
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let id = UUID()
        let file = try store.save(draft, date: date, id: id)
        precondition(file.deletingLastPathComponent() == store.inboxURL)
        let text = try String(contentsOf: file, encoding: .utf8)
        precondition(text.contains(draft.body) && text.contains("sync: false"))
        precondition(text.contains("# ../../safe Title"))
        precondition(text.contains("status: pendente") && text.contains("projeto: inbox"))
        precondition(text.contains("tipo: link") && text.contains("url: \"https://example.com/post?q=1#section\""))
        precondition(text.contains("<https://example.com/post?q=1#section>"))
        let linkOnly = try store.save(PedroCaptureDraft(link: "https://example.org"))
        let linkText = try String(contentsOf: linkOnly, encoding: .utf8)
        precondition(linkText.contains("# example.org") && !linkText.contains("## Observação"))
        do {
            _ = try store.save(draft, date: date, id: id)
            preconditionFailure("Must not overwrite a note")
        } catch PedroCaptureStore.CaptureError.collision {}
        do {
            _ = try store.save(PedroCaptureDraft(link: "   \n ", body: "Context without a link"))
            preconditionFailure("Must require a source link")
        } catch PedroCaptureStore.CaptureError.empty {}
        let missing = root.appendingPathComponent("missing")
        do {
            _ = try PedroCaptureStore(vaultURL: missing).save(draft)
            preconditionFailure("Must not create a fake vault")
        } catch PedroCaptureStore.CaptureError.missingVault {}
        precondition(!FileManager.default.fileExists(atPath: missing.path))
    }

    static func testCaptureLinks() throws {
        let source = "https://example.org/watch?v=123&list=a%2Fb#t=30"
        let parsed = try PedroCaptureStore.sourceURL(" \n" + source + " \n")
        let http = try PedroCaptureStore.sourceURL("http://example.org")
        precondition(parsed.absoluteString == source)
        precondition(http.scheme == "http")
        let invalid = ["javascript:alert(1)", "file:///tmp/note", "ftp://example.org", "example.org",
                       "https://", "https://example.org/hello world", "https://user:secret@example.org",
                       "https://example.org\nhttps://other.org", "https://exam%0Aple.org"]
        for link in invalid {
            do {
                _ = try PedroCaptureStore.sourceURL(link)
                preconditionFailure("Must reject malformed, credential-bearing or non-web URLs")
            } catch PedroCaptureStore.CaptureError.invalidLink {}
        }
        let legacy = Data(#"{"title":"Draft","body":"Keep my existing text"}"#.utf8)
        let restored = try JSONDecoder().decode(PedroCaptureDraft.self, from: legacy)
        precondition(restored.link.isEmpty && restored.title == "Draft" && restored.body == "Keep my existing text")
    }

    @MainActor
    static func testCaptureDraft() async throws {
        let suite = "PedroQuickToolsTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = PedroCaptureStore(vaultURL: root)
        let manager = PedroCaptureManager(defaults: defaults, store: store)
        manager.draft = PedroCaptureDraft(link: "https://example.com/article", title: "Title", body: "Remember this")
        let restored = PedroCaptureManager(defaults: defaults, store: store)
        precondition(restored.draft == manager.draft)
        await manager.save()
        precondition(manager.draft.isEmpty && manager.recent.count == 1 && !manager.isError)
        precondition(manager.title(for: manager.recent[0]) == "Title")
        precondition(PedroCaptureManager(defaults: defaults, store: store).recent.count == 1)
        let bad = PedroCaptureManager(defaults: defaults,
            store: PedroCaptureStore(vaultURL: root.appendingPathComponent("missing")))
        bad.draft.link = "https://example.org"
        bad.draft.body = "Do not lose this"
        await bad.save()
        precondition(bad.isError && bad.draft.body == "Do not lose this" && !bad.isSaving)
        manager.draft = PedroCaptureDraft(link: "javascript:alert(1)", body: "Keep invalid drafts too")
        await manager.save()
        precondition(manager.isError && manager.recent.count == 1 && manager.draft.body == "Keep invalid drafts too")

        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        clipboard.setString("https://example.net/post#part", forType: .string)
        manager.pasteLink(from: clipboard)
        precondition(manager.draft.link == "https://example.net/post#part" && !manager.isError)
        precondition(manager.draft.body == "Keep invalid drafts too")
        clipboard.clearContents()
        clipboard.setString("Not a link", forType: .string)
        manager.pasteLink(from: clipboard)
        precondition(manager.isError && manager.draft.link == "https://example.net/post#part")
        clipboard.clearContents()
        clipboard.setString("https://private.example", forType: .string)
        clipboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        manager.pasteLink(from: clipboard)
        precondition(manager.isError && manager.draft.link == "https://example.net/post#part")
    }
}
