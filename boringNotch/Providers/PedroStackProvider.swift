import AppKit
import Combine
import Foundation

@MainActor
final class PedroStackProvider: ObservableObject {
    static let shared = PedroStackProvider()

    @Published private(set) var snapshot = PedroStackSnapshot.empty
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let session: URLSession
    private var timer: Timer?
    private var appActiveObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    private var feedURL: URL? {
        if let override = UserDefaults.standard.string(forKey: "pedro_stack_webhook_url")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(string: override)
        }
        return nil
    }

    init(session: URLSession = .shared) {
        self.session = session
    }

    func start() {
        refresh(force: true)
        guard timer == nil else { return }
        let refreshTimer = Timer(timeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        RunLoop.main.add(refreshTimer, forMode: .common)
        timer = refreshTimer

        appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(force: true)
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(force: true)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let appActiveObserver {
            NotificationCenter.default.removeObserver(appActiveObserver)
            self.appActiveObserver = nil
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    private enum RefreshPart {
        case remote(PedroStackSnapshot?)
        case vps(PedroStackCard)
        case backup([PedroStackCard])
    }

    func refresh(force: Bool = false) {
        guard !isLoading else { return }
        isLoading = true
        Task {
            var vpsOverride: PedroStackCard?
            var backupOverride: [PedroStackCard]?
            await withTaskGroup(of: RefreshPart.self) { group in
                group.addTask { .remote(await self.fetchRemoteSnapshot()) }
                group.addTask { .vps(Self.loadVPS1Card()) }
                group.addTask { .backup(Self.loadBackupCards()) }
                for await part in group {
                    var next = snapshot
                    switch part {
                    case .remote(let remote):
                        let previousBackup = next.sections.backup
                        next = remote ?? next
                        next.sections.cloud = next.sections.cloud.map { $0.checkingFreshness(feedUnavailable: remote == nil) }
                        next.sections.core = next.sections.core.map { $0.checkingFreshness(feedUnavailable: remote == nil) }
                        next.sections.operation = next.sections.operation.map { $0.checkingFreshness(feedUnavailable: remote == nil) }
                        next.sections.backup = backupOverride ?? previousBackup
                        errorMessage = remote == nil ? "Feed remoto indisponível" : nil
                    case .vps(let card): vpsOverride = card
                    case .backup(let cards): backupOverride = cards
                    }
                    if let vpsOverride { next.sections.cloud = Self.replacingVPS1Card(in: next.sections.cloud, with: vpsOverride) }
                    if let backupOverride { next.sections.backup = backupOverride }
                    snapshot = next
                }
            }
            isLoading = false
            NotificationCenter.default.post(name: .pedroStackDidRefresh, object: snapshot)
        }
    }

    private func fetchRemoteSnapshot() async -> PedroStackSnapshot? {
        guard let feedURL else { return nil }
        do {
            var request = URLRequest(url: feedURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode)
            else {
                return nil
            }
            return try PedroStackSnapshot.decoder.decode(PedroStackSnapshot.self, from: data)
        } catch {
            return nil
        }
    }

    nonisolated private static func loadVPS1Card() -> PedroStackCard {
        let target = PedroOpsSSHTarget(
            id: "vps1",
            title: "VPS1",
            hostAlias: PedroLocalConfiguration.sshHost("pedro_ssh_vps", fallback: "root@192.0.2.30"),
            iconName: "server.rack"
        )
        return vps1Card(from: PedroOpsSSHRunner().status(for: target))
    }

    nonisolated static func vps1Card(
        from result: PedroOpsSSHResult,
        now: Date = Date()
    ) -> PedroStackCard {
        guard result.isReachable else {
            return PedroStackCard(
                id: "cloud.vps1-hostinger-kvm2",
                title: "VPS1",
                subtitle: "SSH indisponível",
                state: .warning,
                icon: "server.rack",
                metrics: [
                    PedroStackMetric(label: "RAM", value: "--", unit: "%"),
                    PedroStackMetric(label: "SSD", value: "--", unit: "%"),
                    PedroStackMetric(label: "Load", value: "--", unit: nil),
                ],
                updatedAt: nil
            )
        }

        let values = sshValues(from: result.output)
        let ram = ratioPercent(from: values["memory"])
        let disk = PedroOpsSnapshotBuilder.metrics(fromSSHOutput: result.output)
            .first(where: { $0.label == "Disco" })?.progressPercent ?? embeddedPercent(from: values["disk"])
        let load = values["load"]?
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)

        return PedroStackCard(
            id: "cloud.vps1-hostinger-kvm2",
            title: "VPS1",
            subtitle: "Online via SSH",
            state: .active,
            icon: "server.rack",
            metrics: [
                PedroStackMetric(label: "RAM", value: ram.map(String.init) ?? "--", unit: "%"),
                PedroStackMetric(label: "SSD", value: disk.map(String.init) ?? "--", unit: "%"),
                PedroStackMetric(label: "Load", value: load ?? "--", unit: nil),
            ],
            updatedAt: now
        )
    }

    nonisolated private static func replacingVPS1Card(
        in cards: [PedroStackCard],
        with replacement: PedroStackCard
    ) -> [PedroStackCard] {
        var next = cards
        if let index = next.firstIndex(where: {
            $0.id.localizedCaseInsensitiveContains("vps1") ||
                $0.title.localizedCaseInsensitiveCompare("VPS1") == .orderedSame
        }) {
            next[index] = replacement
        } else {
            next.append(replacement)
        }
        return next
    }

    nonisolated private static func sshValues(from output: String) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: output
                .split(whereSeparator: \.isNewline)
                .compactMap { line -> (String, String)? in
                    let parts = line.split(
                        separator: "=",
                        maxSplits: 1,
                        omittingEmptySubsequences: false
                    )
                    guard parts.count == 2 else { return nil }
                    return (String(parts[0]), String(parts[1]))
                }
        )
    }

    nonisolated private static func ratioPercent(from value: String?) -> Int? {
        guard let value else { return nil }
        let numbers = value
            .split(separator: "/")
            .compactMap { part -> Double? in
                let numeric = part.filter { $0.isNumber || $0 == "." }
                return Double(numeric)
            }
        guard numbers.count == 2, numbers[1] > 0 else { return nil }
        return Int((numbers[0] / numbers[1] * 100).rounded())
    }

    nonisolated private static func embeddedPercent(from value: String?) -> Int? {
        guard let value,
              let percent = value.split(whereSeparator: \.isWhitespace).first(where: {
                  $0.hasSuffix("%")
              })
        else {
            return nil
        }
        return Int(percent.dropLast())
    }

    nonisolated private static func loadBackupCards() -> [PedroStackCard] {
        let target = PedroOpsSSHTarget(
            id: "truenas",
            title: "TrueNAS",
            hostAlias: PedroLocalConfiguration.sshHost("pedro_ssh_truenas", fallback: "user@192.0.2.20"),
            iconName: "externaldrive.fill"
        )
        guard !target.sshHostAlias.contains("192.0.2."), !target.sshHostAlias.hasSuffix(".invalid") else {
            return unavailableBackupCards()
        }
        let script = """
        midclt call pool.snapshottask.query 2>/dev/null |
        jq -r '.[] |
          select(.dataset == "PrimaryPool" or .dataset == "ArchivePool") |
          [
            .dataset,
            (.state.state // "UNKNOWN"),
            (((.state.datetime["$date"] // 0) / 1000) | floor),
            (.enabled // false),
            (.lifetime_value // 14),
            (.lifetime_unit // "DAY")
          ] |
          map(tostring) |
          join("|")'
        """
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = PedroOpsSSHRunner.arguments(
            for: target,
            remoteCommand: PedroOpsSSHRunner.remoteCommand(for: script)
        )
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = PedroOpsUserHome.path
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return unavailableBackupCards()
        }

        let deadline = Date().addingTimeInterval(8)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return unavailableBackupCards()
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return unavailableBackupCards()
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return backupCards(from: output)
    }

    nonisolated static func backupCards(from output: String, now: Date = Date()) -> [PedroStackCard] {
        var readings: [String: BackupTaskReading] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let dataset = parts[0].split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
            guard dataset == "PrimaryPool" || dataset == "ArchivePool" else { continue }

            if parts.count >= 6, let epoch = TimeInterval(parts[2]) {
                let reading = BackupTaskReading(
                    date: epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil,
                    taskState: parts[1].uppercased(),
                    isEnabled: parts[3].lowercased() == "true",
                    retention: retentionLabel(value: parts[4], unit: parts[5])
                )
                if (reading.date ?? .distantPast) >= (readings[dataset]?.date ?? .distantPast) {
                    readings[dataset] = reading
                }
            } else if parts.count == 2, let epoch = TimeInterval(parts[1]) {
                let date = Date(timeIntervalSince1970: epoch)
                if date > (readings[dataset]?.date ?? .distantPast) {
                    readings[dataset] = BackupTaskReading(
                        date: date,
                        taskState: "FINISHED",
                        isEnabled: true,
                        retention: "14d"
                    )
                }
            }
        }

        return [
            backupCard(id: "PrimaryPool", title: "Principal", reading: readings["PrimaryPool"], now: now),
            backupCard(id: "ArchivePool", title: "Arquivo", reading: readings["ArchivePool"], now: now),
        ]
    }

    nonisolated private struct BackupTaskReading {
        let date: Date?
        let taskState: String
        let isEnabled: Bool
        let retention: String
    }

    nonisolated private static func backupCard(
        id: String,
        title: String,
        reading: BackupTaskReading?,
        now: Date
    ) -> PedroStackCard {
        guard let reading, let date = reading.date else {
            return PedroStackCard(
                id: "backup.\(id)",
                title: title,
                subtitle: "Sem leitura da tarefa",
                state: .unknown,
                icon: "clock.badge.questionmark",
                metrics: [
                    PedroStackMetric(label: "Último", value: "--", unit: nil),
                    PedroStackMetric(label: "Retenção", value: "14d", unit: nil),
                ],
                updatedAt: nil
            )
        }

        let ageHours = max(0, Int(now.timeIntervalSince(date) / 3600))
        let state: PedroStackState
        let subtitle: String
        if !reading.isEnabled {
            state = .warning
            subtitle = "Tarefa desativada"
        } else {
            switch reading.taskState {
            case "FINISHED", "SUCCESS":
                state = ageHours <= 36 ? .active : ageHours <= 72 ? .warning : .offline
                subtitle = "Backup concluído"
            case "RUNNING":
                state = .warning
                subtitle = "Backup em execução"
            case "ERROR", "FAILED":
                state = .offline
                subtitle = "Falha no backup"
            default:
                state = .unknown
                subtitle = "Estado \(reading.taskState.lowercased())"
            }
        }

        return PedroStackCard(
            id: "backup.\(id)",
            title: title,
            subtitle: subtitle,
            state: state,
            icon: "externaldrive.fill.badge.timemachine",
            metrics: [
                PedroStackMetric(label: "Último", value: date.formatted(date: .omitted, time: .shortened), unit: nil),
                PedroStackMetric(label: "Idade", value: "\(ageHours)h", unit: nil),
                PedroStackMetric(label: "Retenção", value: reading.retention, unit: nil),
            ],
            updatedAt: date
        )
    }

    nonisolated private static func retentionLabel(value: String, unit: String) -> String {
        let suffix: String
        switch unit.uppercased() {
        case "HOUR": suffix = "h"
        case "WEEK": suffix = "sem"
        case "MONTH": suffix = "m"
        default: suffix = "d"
        }
        return value + suffix
    }

    nonisolated private static func unavailableBackupCards() -> [PedroStackCard] {
        [
            backupCard(id: "PrimaryPool", title: "Principal", reading: nil, now: Date()),
            backupCard(id: "ArchivePool", title: "Arquivo", reading: nil, now: Date()),
        ]
    }
}

extension Notification.Name {
    static let pedroStackDidRefresh = Notification.Name("pedroStackDidRefresh")
}
