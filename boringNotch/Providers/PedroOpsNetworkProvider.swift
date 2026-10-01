import AppKit
import Combine
import OSLog

@MainActor
final class PedroOpsNetworkProvider: ObservableObject {
    static let shared = PedroOpsNetworkProvider()

    enum Reading {
        case usage(PedroOpsUsageWindowSummary)
        case ssh(PedroOpsSSHResult)
    }

    @Published private(set) var summaries: [String: PedroOpsUsageWindowSummary]
    @Published private(set) var sshResults: [String: PedroOpsSSHResult] = [:]
    @Published private(set) var pending = Set<String>()
    private var lastAttempt: [String: Date] = [:]
    private var observedAt: [String: Date] = [:]
    private let loader: (String) async -> Reading
    private let now: () -> Date
    private var wakeObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "theboringteam.boringnotch", category: "PedroNetwork")

    init(
        cachedSummaries: [String: PedroOpsUsageWindowSummary]? = nil,
        now: @escaping () -> Date = Date.init,
        loader: ((String) async -> Reading)? = nil
    ) {
        self.now = now
        self.loader = loader ?? Self.load
        summaries = cachedSummaries ?? PedroOpsClaudeUsageReader.cachedSummary().map { ["claude": $0] } ?? [:]
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.lastAttempt.removeAll() }
        }
    }

    deinit {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    var usageCards: [PedroOpsCard] {
        let checked = Dictionary(uniqueKeysWithValues: summaries.map { id, value in
            (id, value.checkingFreshness(observedAt: observedAt["usage." + id], now: now()))
        })
        return PedroOpsSnapshotBuilder().usageCards(snapshot: .from(summaries: checked))
    }

    var isLoadingUsage: Bool { pending.contains(where: { $0.hasPrefix("usage.") }) }

    func statusCards(for targets: [PedroOpsSSHTarget]) -> [PedroOpsCard] {
        PedroOpsSnapshotBuilder().statusCards(results: sshResults, targets: targets).map { card in
            guard let observed = observedAt["ssh." + card.id], now().timeIntervalSince(observed) >= 30 else { return card }
            return PedroOpsCard(id: card.id, title: card.title, subtitle: "Última leitura",
                                iconName: card.iconName, state: .warning, metrics: card.metrics,
                                footnote: "Atualizando conexão · " + (card.footnote ?? ""),
                                bundleIdentifier: card.bundleIdentifier)
        }
    }

    func refreshUsage() {
        for id in ["claude", "codex"] { refresh(key: "usage." + id, interval: 60) }
    }

    func refreshStatus(targets: [PedroOpsSSHTarget]) {
        for target in targets { refresh(key: "ssh." + target.id, interval: 15) }
    }

    private func refresh(key: String, interval: TimeInterval) {
        guard !pending.contains(key), now().timeIntervalSince(lastAttempt[key] ?? .distantPast) >= interval else { return }
        lastAttempt[key] = now()
        pending.insert(key)
        Task {
            let started = Date()
            let result = await loader(key)
            switch result {
            case .usage(var summary):
                let id = String(key.dropFirst("usage.".count))
                if summary.isStale,
                   summary.lastFiveHoursProgressPercent == nil, summary.lastWeekProgressPercent == nil,
                   var previous = summaries[id] {
                    previous.isStale = true
                    summary = previous
                }
                summaries[id] = summary
                if !summary.isStale { observedAt[key] = now() }
            case .ssh(let result):
                sshResults[String(key.dropFirst("ssh.".count))] = result
                observedAt[key] = now()
            }
            pending.remove(key)
            logger.info("Refresh \(key, privacy: .public) finished in \(Date().timeIntervalSince(started), privacy: .public)s")
        }
    }

    private static func load(_ key: String) async -> Reading {
        await Task.detached(priority: .userInitiated) {
            switch key {
            case "usage.claude":
                return .usage(PedroOpsClaudeUsageReader.summary(includeSessionCounts: false))
            case "usage.codex":
                return .usage(PedroOpsCodexUsageReader.summary(appServerOutput: PedroOpsCodexAppServerClient.fetch()))
            default:
                let id = String(key.dropFirst("ssh.".count))
                let targets = PedroOpsSnapshotBuilder.defaultTargets + [PedroOpsSnapshotBuilder.alienwareTarget]
                guard let target = targets.first(where: { $0.id == id }) else {
                    return .ssh(PedroOpsSSHResult(hostID: id, isReachable: false, output: "", errorMessage: "Destino desconhecido"))
                }
                return .ssh(PedroOpsSSHRunner().status(for: target))
            }
        }.value
    }
}
