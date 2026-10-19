import AppKit
import Combine
import Foundation

@MainActor final class PedroContinuityProvider: ObservableObject {
    static let shared = PedroContinuityProvider()
    @Published private(set) var enabled = false
    @Published private(set) var state = "disabled"
    @Published private(set) var topics: [String: [PedroContinuityItem]] = [:]
    @Published private(set) var feedback: String?
    @Published private(set) var busy = Set<String>()
    @Published var mediaHost = "local"
    private(set) var peer = "mac"
    private let transport = PedroContinuityTransport()
    private var revisions: [String: Int] = [:]
    // Only provenance identifiers are persisted here, never clipboard content or private paths.
    private var clipboardMap: [String: String] = [:] // portable key -> native fingerprint
    private var committedClipboardKeys = Set<String>()
    private var committedShelfKeys = Set<String>()
    private var activationTime: Double = 0
    private var activationGeneration = 0
    private var ticker: Task<Void, Never>?
    private var feedbackExpiry: Task<Void, Never>?
    private var lastMedia: PedroContinuityPayload = [:]
    private var lastMediaAt = Date.distantPast
    private var publishedEvents: [String: String] = [:]
    private var removedShelf = Set<String>()
    private var publishing = false
    private var watched = false
    private var subscribing = false
    private var consumedCommands = Set<String>()
    var statusLabel: String {
        switch state { case "online": return "Compartilhado"; case "connecting": return "Conectando"; case "disabled": return "Local"; default: return "Offline · cache" }
    }
    var uncachedClipboardItems: [PedroContinuityItem] {
        items("clipboard").filter { item in
            !PedroClipboardManager.shared.history.items.contains { $0.fingerprint == clipboardMap[item.id] }
        }
    }
    func items(_ topic: String) -> [PedroContinuityItem] { topics[topic] ?? [] }
    func start() {
        guard !enabled else { return }
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/pedro-notch")
        let config = base.appendingPathComponent("continuity/config.json")
        guard let data = try? Data(contentsOf: config),
              let values = try? JSONDecoder().decode(PedroContinuityPayload.self, from: data),
              values["enabled"]?.bool == true, let configuredPeer = values["peer"]?.string, !configuredPeer.isEmpty else { return }
        peer = configuredPeer; enabled = true; state = "connecting"
        clipboardMap = UserDefaults.standard.dictionary(forKey: "pedroContinuityClipboardMap") as? [String: String] ?? [:]
        committedClipboardKeys = Set(UserDefaults.standard.stringArray(forKey: "pedroContinuityClipboardKeys") ?? [])
        committedShelfKeys = Set(UserDefaults.standard.stringArray(forKey: "pedroContinuityShelfKeys") ?? [])
        transport.onEvent = { [weak self] data in self?.event(data) }
        transport.start(script: base.appendingPathComponent("continuity-client.py"), config: config)
        installHooks()
        Task { await subscribe() }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                if let self { await self.publishSources() }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
    func stop() { ticker?.cancel(); feedbackExpiry?.cancel(); transport.stop(); enabled = false }
    private func subscribe() async {
        guard !subscribing else { return }; subscribing = true; defer { subscribing = false }
        do { _ = try await transport.request(["op": .string("watch")]); watched = true }
        catch { watched = false }
    }
    func request(_ payload: PedroContinuityPayload, timeout: Double = 60) async throws -> PedroContinuityPayload {
        try await transport.request(payload, timeout: timeout)
    }
    func desk(_ request: [String: String]) async -> Data {
        var inner = request.mapValues { PedroContinuityValue.string($0) }
        if request["legacyLocal"] == "true" { inner["legacyLocal"] = .bool(true) }
        do {
            let result = try await transport.request(["op": .string("desk_local"), "request": .object(inner)], timeout: ["submit", "result", "retrieve", "download", "fetch"].contains(request["command"] ?? "") ? 3600 : 60)
            return try JSONEncoder().encode(result["result"] ?? .null)
        } catch { return (try? JSONEncoder().encode(["ok": PedroContinuityValue.bool(false), "error": .string(error.localizedDescription)])) ?? Data() }
    }
    private func event(_ data: Data) {
        guard let frame = try? JSONDecoder().decode(PedroContinuityPayload.self, from: data) else { return }
        switch frame["event"]?.string {
        case "connection":
            state = frame["state"]?.string ?? "offline"
            if state == "online" { Task { if !watched { await subscribe() } } }
            // Each native watch survives SSH reconnect; a bridge crash needs a new watch.
            if state == "offline" { watched = false }
        case "snapshot":
            guard let snapshot = try? JSONDecoder().decode(PedroContinuitySnapshot.self, from: data),
                  snapshot.revision >= (revisions[snapshot.topic] ?? 0) else { return }
            let previous = items(snapshot.topic)
            revisions[snapshot.topic] = snapshot.revision; topics[snapshot.topic] = snapshot.items
            if snapshot.topic == "shelf", snapshot.cached == false {
                let current = Set(snapshot.items.map(\.id))
                for key in committedShelfKeys.subtracting(current) { ShelfStateViewModel.shared.removeShared(id: key) }
                committedShelfKeys = current
                UserDefaults.standard.set(Array(current), forKey: "pedroContinuityShelfKeys")
            }
            if snapshot.topic == "clipboard" { receiveClipboard(snapshot, previous: previous) }
        case "command": Task { await consumeCommand(frame) }
        case "mutation_error": show("Alteração compartilhada rejeitada; conteúdo local preservado")
        default: break
        }
    }
    func show(_ text: String) {
        feedback = String(text.prefix(160)); feedbackExpiry?.cancel()
        feedbackExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5)); guard !Task.isCancelled else { return }; self?.feedback = nil
        }
    }
    @discardableResult private func mutate(_ op: String = "put", topic: String, key: String, payload: PedroContinuityPayload = [:], revision: Int? = nil) async throws -> PedroContinuityPayload {
        var request: PedroContinuityPayload = ["op": .string(op), "topic": .string(topic), "key": .string(key),
            "mutationId": .string(UUID().uuidString), "expectedRevision": .number(Double(revision ?? revisions[topic] ?? 0))]
        if op != "delete" { request["payload"] = .object(payload) }
        let reply = try await transport.request(request)
        if reply["queued"]?.bool == true { show("Guardado para sincronizar") }
        return reply
    }
    func remove(topic: String, key: String) {
        guard enabled else { return }
        if topic == "shelf" { removedShelf.insert(key) }
        Task { do { try await mutate("delete", topic: topic, key: key) } catch { show(error.localizedDescription) } }
    }
    func pin(_ item: PedroContinuityItem) {
        Task { do { try await mutate("patch", topic: "clipboard", key: item.id, payload: ["pinned": .bool(!item.flag("pinned"))]) } catch { show(error.localizedDescription) } }
    }
    func stage(_ url: URL) async throws -> PedroContinuityValue {
        let result = try await transport.request(["op": .string("stage_file"), "path": .string(url.path)], timeout: 3600)
        guard let blob = result["blob"] else { throw PedroContinuityTransport.Failure.rejected("Arquivo não verificado") }; return blob
    }
    func fetch(_ blob: PedroContinuityValue) async throws -> URL {
        let result = try await transport.request(["op": .string("fetch_blob"), "blob": blob], timeout: 3600)
        guard let path = result["path"]?.string, path.hasPrefix("/") else { throw PedroContinuityTransport.Failure.rejected("Cópia local indisponível") }
        return URL(fileURLWithPath: path)
    }
    private func installHooks() {
        let clipboard = PedroClipboardManager.shared
        clipboard.onCapture = { [weak self] item in self?.publishClipboard(item) }
        clipboard.onManualCopy = { [weak self] item in
            guard let self, !self.items("clipboard").contains(where: { self.clipboardMap[$0.id] == item.fingerprint }) else { return }
            self.publishClipboard(item, recaptured: true)
        }
        clipboard.onPin = { [weak self] item, pinned in
            guard let self, let key = self.clipboardMap.first(where: { $0.value == item.fingerprint })?.key else { return }
            Task { do { try await self.mutate("patch", topic: "clipboard", key: key, payload: ["pinned": .bool(pinned)]) } catch { self.show(error.localizedDescription) } }
        }
        clipboard.onRemove = { [weak self] item in
            guard let self, let key = self.clipboardMap.first(where: { $0.value == item.fingerprint })?.key else { return }
            self.remove(topic: "clipboard", key: key)
        }
        PedroCaptureManager.shared.onSaved = { [weak self] draft, url in self?.publishCapture(draft, url: url) }
    }
    func publishClipboard(_ item: PedroClipboardItem, recaptured: Bool = false) {
        guard enabled, item.kind != .file else { return }
        let capturedAt = recaptured ? Date().timeIntervalSince1970 : item.capturedAt.timeIntervalSince1970
        activationTime = max(activationTime, capturedAt); activationGeneration += 1
        let revision = revisions["clipboard"] ?? 0
        Task {
            do {
                var payload: PedroContinuityPayload = ["kind": .string(item.kind.rawValue), "label": .string(String(item.displayText.prefix(256))), "pinned": .bool(item.isPinned), "capturedAt": .number(capturedAt)]
                let key: String
                if item.kind == .image {
                    guard let url = PedroClipboardManager.shared.imageURL(for: item) else { return }
                    let blob = try await stage(url); payload["blob"] = blob; key = blob.object["sha256"]?.string ?? ""
                } else {
                    guard let text = item.payloadText, text.utf8.count <= 262144 else { return }
                    payload["text"] = .string(text); key = PedroContinuityPolicy.digest(Data(text.utf8))
                }
                clipboardMap[key] = item.fingerprint
                try await mutate(topic: "clipboard", key: key, payload: payload, revision: revision)
            } catch { show(error.localizedDescription) }
        }
    }
    private func receiveClipboard(_ snapshot: PedroContinuitySnapshot, previous: [PedroContinuityItem]) {
        let manager = PedroClipboardManager.shared
        let keys = Set(snapshot.items.map(\.id))
        if snapshot.cached == false {
            for key in committedClipboardKeys.subtracting(keys) {
                if let fingerprint = clipboardMap[key] { manager.sharedMetadata(fingerprint: fingerprint, pinned: nil) }
                clipboardMap.removeValue(forKey: key)
            }
            committedClipboardKeys = keys
        }
        for item in snapshot.items {
            if item.text("kind") != "image" {
                let local = PedroClipboardItem.text(item.text("text"), sourceBundleIdentifier: nil)
                clipboardMap[item.id] = local.fingerprint
                manager.acceptShared(text: item.text("text"), png: nil, capturedAt: Date(timeIntervalSince1970: item.number("capturedAt")), pinned: item.flag("pinned"), activate: false, persistChanges: false)
            } else if let fingerprint = clipboardMap[item.id] { manager.sharedMetadata(fingerprint: fingerprint, pinned: item.flag("pinned")) }
        }
        manager.saveSharedBatch()
        UserDefaults.standard.set(clipboardMap, forKey: "pedroContinuityClipboardMap")
        UserDefaults.standard.set(Array(committedClipboardKeys), forKey: "pedroContinuityClipboardKeys")
        let candidate = snapshot.items.filter { item in
            PedroContinuityPolicy.canActivate(item, snapshot: snapshot, previous: previous.first(where: { $0.id == item.id }), peer: peer, now: Date().timeIntervalSince1970)
        }.max { $0.number("capturedAt") < $1.number("capturedAt") }
        guard let item = candidate, item.number("capturedAt") > max(activationTime, manager.lastLocalChangeAt) else { return }
        activationTime = item.number("capturedAt"); activationGeneration += 1
        let generation = activationGeneration, localGeneration = manager.contentGeneration, count = manager.currentChangeCount
        Task { await copyClipboard(item, automatic: true, generation: generation, localGeneration: localGeneration, count: count) }
    }
    func copyClipboard(_ item: PedroContinuityItem) {
        activationGeneration += 1
        let generation = activationGeneration
        let manager = PedroClipboardManager.shared
        let localGeneration = manager.contentGeneration, count = manager.currentChangeCount
        Task { await copyClipboard(item, automatic: false, generation: generation,
                                   localGeneration: localGeneration, count: count) }
    }
    private func copyClipboard(_ item: PedroContinuityItem, automatic: Bool, generation: Int, localGeneration: Int, count: Int) async {
        busy.insert(item.id); defer { busy.remove(item.id) }
        do {
            var png: Data?
            if let blob = item.payload["blob"] {
                let url = try await fetch(blob)
                png = try await Task.detached { try Data(contentsOf: url) }.value
                guard let png, png.count <= 20 * 1024 * 1024, PedroContinuityPolicy.digest(png) == blob.object["sha256"]?.string else { throw PedroContinuityTransport.Failure.rejected("PNG inválido") }
                clipboardMap[item.id] = PedroClipboardItem.fingerprint(kind: .image, payload: png)
            }
            let manager = PedroClipboardManager.shared
            guard PedroContinuityPolicy.mayFinishClipboard(expectedEvent: generation, event: activationGeneration, expectedLocal: localGeneration, local: manager.contentGeneration, expectedChange: count, change: manager.currentChangeCount) else { return }
            if automatic {
                guard Date().timeIntervalSince1970 - item.number("capturedAt") <= 30,
                      items("clipboard").contains(where: { $0.id == item.id && $0.number("capturedAt") == item.number("capturedAt") }) else { return }
            }
            manager.acceptShared(text: png == nil ? item.text("text") : nil, png: png, capturedAt: Date(timeIntervalSince1970: item.number("capturedAt")), pinned: item.flag("pinned"), activate: true)
            UserDefaults.standard.set(clipboardMap, forKey: "pedroContinuityClipboardMap")
            if !automatic { show("Copiado") }
        } catch { show(error.localizedDescription) }
    }
    func publishShelf(_ item: ShelfItem) {
        guard enabled else { return }
        removedShelf.remove(item.id.uuidString)
        let revision = revisions["shelf"] ?? 0
        busy.insert(item.id.uuidString)
        Task {
            defer { busy.remove(item.id.uuidString) }
            do {
                var payload: PedroContinuityPayload = ["name": .string(String(item.displayName.prefix(512))), "createdAt": .number(Date().timeIntervalSince1970)]
                switch item.kind {
                case .file:
                    guard let url = item.fileURL else { return }
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    payload["kind"] = .string("file"); payload["blob"] = try await stage(url)
                case .text(let value): payload["kind"] = .string("text"); payload["text"] = .string(value)
                case .link(let url): payload["kind"] = .string("link"); payload["url"] = .string(url.absoluteString)
                }
                guard !removedShelf.contains(item.id.uuidString) else { return }
                try await mutate(topic: "shelf", key: item.id.uuidString, payload: payload, revision: revision)
            } catch { show(error.localizedDescription) }
        }
    }
    func openShared(_ item: PedroContinuityItem, topic: String) {
        busy.insert(item.id)
        Task {
            defer { busy.remove(item.id) }
            do {
                if let blob = item.payload["blob"] { NSWorkspace.shared.activateFileViewerSelecting([try await fetch(blob)]) }
                else if !item.text("url").isEmpty, let url = URL(string: item.text("url")), ["http", "https"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
                else if topic == "shelf" { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.text("text"), forType: .string) }
            } catch { show(error.localizedDescription) }
        }
    }
    func publishCapture(_ draft: PedroCaptureDraft, url: URL) {
        guard enabled else { return }
        Task {
            let key = UUID().uuidString
            let payload: PedroContinuityPayload = ["title": .string(draft.displayTitle), "url": .string(draft.sourceURL?.absoluteString ?? draft.link), "note": .string(draft.body), "createdAt": .number(Date().timeIntervalSince1970), "sync": .bool(false)]
            do {
                try await mutate(topic: "links", key: key, payload: payload)
                if state == "online" {
                    let blob = try await stage(url)
                    try await mutate("patch", topic: "links", key: key, payload: ["blob": blob])
                }
            } catch { show("Nota salva localmente · " + error.localizedDescription) }
        }
    }

    func acknowledge(_ alerts: [PedroOpsAlert]) {
        guard enabled else { return }
        for alert in alerts where PedroContinuityPolicy.isSharedAlert(source: alert.source, id: alert.id) {
            Task { do {
                let key = PedroContinuityPolicy.digest(Data((alert.id + "\u{0}" + alert.stateHash).utf8))
                try await mutate(topic: "alerts", key: key, payload: ["alertId": .string(alert.id), "stateHash": .string(alert.stateHash), "dismissed": .bool(true)])
            } catch { show(error.localizedDescription) } }
        }
    }
    func isAcknowledged(_ alert: PedroOpsAlert) -> Bool {
        PedroContinuityPolicy.isSharedAlert(source: alert.source, id: alert.id) && items("alerts").contains { PedroContinuityPolicy.matchesAlert($0, id: alert.id, hash: alert.stateHash) }
    }
    private func publishSources() async {
        guard enabled, state == "online", !publishing else { return }; publishing = true; defer { publishing = false }
        let music = MusicManager.shared
        var media: PedroContinuityPayload = ["host": .string(peer), "title": .string(String(music.songTitle.prefix(512))), "artist": .string(String(music.artistName.prefix(512))), "album": .string(String(music.album.prefix(512))), "playing": .bool(music.isPlaying), "duration": .number(max(0, music.songDuration)), "available": .bool(!music.isPlayerIdle)]
        if media != lastMedia || Date().timeIntervalSince(lastMediaAt) >= 15 {
            lastMedia = media; lastMediaAt = Date(); media["position"] = .number(max(0, music.elapsedTime)); media["updatedAt"] = .number(Date().timeIntervalSince1970)
            do { try await mutate(topic: "media", key: peer, payload: media) } catch { lastMediaAt = .distantPast }
        }
        let events = await Task.detached(priority: .utility) { PedroAgentBridge.activeEvents() }.value
        var seen = Set<String>()
        for event in events {
            let key = PedroContinuityPolicy.taskKey(peer: peer, provider: event.provider.rawValue, session: event.sessionID)
            let taskID = String(key.dropFirst(peer.count + 1))
            guard seen.insert(taskID).inserted, publishedEvents[taskID] != event.eventID else { continue }
            // No prompts, cwd, model, request ids, permission answers or transcript content.
            let status: String
            switch event.kind { case .completed: status = "completed"; case .permissionRequest, .question: status = "waiting"; default: status = "working" }
            do {
                try await mutate(topic: "tasks", key: key, payload: ["taskId": .string(taskID), "host": .string(peer), "agent": .string(event.provider.title), "title": .string(String((event.title ?? event.provider.title).prefix(256))), "status": .string(status), "progress": .number(status == "completed" ? 100 : 0), "summary": .string(status == "waiting" ? "Aguardando no computador de origem" : ""), "updatedAt": .number(event.createdAt.timeIntervalSince1970)])
                publishedEvents[taskID] = event.eventID
            } catch { }
        }
    }
    func sendMedia(_ action: String, position: Double? = nil) {
        guard mediaHost != "local", let target = items("media").first(where: { $0.id == mediaHost }), PedroContinuityPolicy.mediaAvailable(target, now: Date().timeIntervalSince1970) else { show("Mídia remota indisponível"); return }
        let selectedHost = mediaHost
        Task { do {
            _ = try await transport.request(["op": .string("send_command"), "target": .string(selectedHost), "action": .string(action), "arguments": .object(position.map { ["position": .number($0)] } ?? [:])])
        } catch { show(error.localizedDescription) } }
    }
    private func consumeCommand(_ frame: PedroContinuityPayload) async {
        guard frame["target"]?.string == peer, let id = frame["commandId"]?.string,
              (frame["expiresAt"]?.number ?? 0) > Date().timeIntervalSince1970 else { return }
        guard consumedCommands.insert(id).inserted else { return }
        if consumedCommands.count > 1000 { consumedCommands = [id] }
        let music = MusicManager.shared
        let action = frame["action"]?.string ?? ""
        var ok = !music.isPlayerIdle
        if ok {
            switch action {
            case "play": music.play()
            case "pause": music.pause()
            case "toggle": music.playPause()
            case "next": music.nextTrack()
            case "previous": music.previousTrack()
            case "seek": music.seek(to: min(music.songDuration, max(0, frame["arguments"]?.object["position"]?.number ?? 0)))
            case "raise": music.openMusicApp()
            default: ok = false
            }
        }
        _ = try? await transport.request(["op": .string("ack_command"), "commandId": .string(id), "ok": .bool(ok)])
    }
}
