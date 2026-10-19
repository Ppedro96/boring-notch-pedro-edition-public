import AppKit
import Combine

@MainActor
final class PedroActivityManager: ObservableObject {
    static let shared = PedroActivityManager()
    @Published private(set) var events: [PedroActivityEvent] = []
    @Published var errorMessage: String?
    private let defaults: UserDefaults
    private var dismissed: [String: String]
    private var rawEvents: [PedroActivityEvent] = []
    private var localEvents: [String: PedroActivityEvent] = [:]
    private var downloads: [String: PedroDownloadReading] = [:]
    private var timer: Timer?
    private var refreshing = false
    private var visibilityCancellable: AnyCancellable?
    private let dismissedKey = "pedroActivityDismissedV1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dismissed = defaults.dictionary(forKey: dismissedKey) as? [String: String] ?? [:]
        localEvents = defaults.data(forKey: "pedroActivityHistoryV1").flatMap {
            try? JSONDecoder().decode([String: PedroActivityEvent].self, from: $0)
        } ?? [:]
        for (id, var event) in localEvents where !event.state.isFinished {
            event.state = .unknown
            event.detail = "Leitura interrompida ao fechar o app"
            event.progress = nil
            localEvents[id] = event
        }
        publish()
        visibilityCancellable = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.publish() }
            }
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            let result = await Task.detached(priority: .utility) {
                (PedroActivityDisk.read(), PedroDownloadScanner.scan(directory:
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)))
            }.value
            rawEvents = result.0
            updateDownloads(result.1)
            refreshing = false
            publish()
        }
    }

    func record(_ event: PedroActivityEvent) {
        guard event.isValid(), localEvents[event.id].map({ $0.updatedAt > event.updatedAt }) != true else { return }
        let isNew = localEvents[event.id] == nil
        localEvents[event.id] = event
        publish()
        if isNew || event.state.isFinished { saveHistory() }
    }

    func dismiss(_ values: [PedroActivityEvent]) {
        for event in values { dismissed[event.id] = event.revision }
        defaults.set(dismissed, forKey: dismissedKey)
        publish()
    }

    func open(_ event: PedroActivityEvent) {
        if let path = event.outputPath, path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else if let url = event.safeURL {
            NSWorkspace.shared.open(url)
        } else if event.isDot {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/ChatGPT.app"))
        }
    }

    private func updateDownloads(_ readings: [PedroDownloadReading]) {
        let next = Dictionary(uniqueKeysWithValues: readings.map { reading in
            var preserved = reading
            if let old = downloads[reading.partial.path] { preserved.originalDestinationDate = old.originalDestinationDate }
            return (reading.partial.path, preserved)
        })
        for (id, old) in downloads where next[id] == nil {
            guard var event = localEvents[id] else { continue }
            let exists = old.confirmedFinished
            event.state = exists ? .completed : .unknown
            event.revision = UUID().uuidString
            event.detail = exists ? "Download concluido" : "Arquivo parcial removido; conclusao nao confirmada"
            event.outputPath = exists ? old.destination.path : nil
            event.updatedAt = Date()
            localEvents[id] = event
            saveHistory()
        }
        for (id, reading) in next {
            let previous = localEvents[id]
            let state: PedroActivityState = Date().timeIntervalSince(reading.modifiedAt) > 300 ? .unknown : .running
            if let old = downloads[id], old.bytes == reading.bytes, previous?.state == state { continue }
            localEvents[id] = PedroActivityEvent(id: id, revision: previous?.state == state ? previous!.revision : UUID().uuidString,
                kind: "download", title: reading.destination.lastPathComponent,
                detail: ByteCountFormatter.string(fromByteCount: reading.bytes, countStyle: .file) +
                    (state == .running ? " recebidos" : " · Sem progresso recente"),
                state: state, updatedAt: Date(), progress: nil, url: nil, outputPath: nil)
        }
        downloads = next
    }

    private func publish() {
        let now = Date()
        var merged: [String: PedroActivityEvent] = [:]
        for event in rawEvents + Array(localEvents.values) where event.isValid(now: now) {
            if merged[event.id].map({ $0.updatedAt > event.updatedAt }) != true { merged[event.id] = event }
        }
        let hideDot = defaults.bool(forKey: "hideDotIntegration")
        let next = merged.values.filter {
            dismissed[$0.id] != $0.revision && !(hideDot && $0.isDot)
        }.sorted {
            if $0.state.isFinished != $1.state.isFinished { return !$0.state.isFinished }
            return $0.updatedAt > $1.updatedAt
        }
        if events != next { events = next }
    }

    private func saveHistory() {
        let kept = localEvents.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(100)
        if let data = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: kept.map { ($0.id, $0) })) {
            defaults.set(data, forKey: "pedroActivityHistoryV1")
        }
    }
}
