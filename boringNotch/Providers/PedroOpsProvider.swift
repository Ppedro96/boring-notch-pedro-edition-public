import Foundation
import AppKit
import CoreGraphics
import SQLite3
import Darwin

enum PedroLocalConfiguration {
    static func sshHost(_ key: String, fallback: String, defaults: UserDefaults = .standard) -> String {
        guard let value = defaults.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, !value.hasPrefix("-"),
              value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
        else { return fallback }
        return value
    }
}

protocol PedroOpsSSHRunning {
    func status(for target: PedroOpsSSHTarget) -> PedroOpsSSHResult
}

struct PedroOpsSnapshotBuilder {
    static let defaultTargets = [
        PedroOpsSSHTarget(id: "x99", title: "X99", hostAlias: PedroLocalConfiguration.sshHost("pedro_ssh_x99", fallback: "user@192.0.2.10"), iconName: "desktopcomputer"),
        PedroOpsSSHTarget(id: "truenas", title: "TrueNAS", hostAlias: PedroLocalConfiguration.sshHost("pedro_ssh_truenas", fallback: "user@192.0.2.20"), iconName: "externaldrive.fill")
    ]

    static let alienwareTarget = PedroOpsSSHTarget(
        id: "alienware",
        title: "Alienware",
        hostAlias: PedroLocalConfiguration.sshHost("pedro_ssh_alienware", fallback: "user@windows.example.invalid"),
        iconName: "laptopcomputer",
        connectionHostAlias: PedroLocalConfiguration.sshHost("pedro_ssh_alienware_relay", fallback: "user@192.0.2.10")
    )

    func usageCards(snapshot: PedroOpsUsageSnapshot = .current()) -> [PedroOpsCard] {
        snapshot.apps.map { app in
            let fiveHourValue = app.lastFiveHoursDisplay ?? Self.formatTokenCount(app.lastFiveHoursTokens)
            let weekValue = app.lastWeekDisplay ?? Self.formatTokenCount(app.lastWeekTokens)
            let hasUsage = app.lastFiveHoursTokens != nil ||
                app.lastWeekTokens != nil ||
                app.lastFiveHoursDisplay != nil ||
                app.lastWeekDisplay != nil
            let subtitle = app.isUsageStale ? "Última leitura" : (hasUsage ? "Uso da conta" : "Sem leitura")
            var metrics: [PedroOpsMetric] = []
            if app.lastFiveHoursDetail != "Sem janela" {
                metrics.append(
                    PedroOpsMetric(
                        label: "5h",
                        value: fiveHourValue,
                        detail: app.lastFiveHoursDetail,
                        progressPercent: app.lastFiveHoursProgressPercent,
                        progressStyle: app.lastFiveHoursProgressStyle
                    )
                )
            }
            metrics.append(
                PedroOpsMetric(
                    label: "Semana",
                    value: weekValue,
                    detail: app.lastWeekDetail,
                    progressPercent: app.lastWeekProgressPercent,
                    progressStyle: app.lastWeekProgressStyle
                )
            )
            return PedroOpsCard(
                id: app.id,
                title: app.title,
                subtitle: subtitle,
                iconName: app.iconName,
                state: hasUsage ? (app.isUsageStale ? .warning : .active) : (app.isRunning ? .warning : .offline),
                metrics: metrics,
                footnote: app.usageSource.map { app.isUsageStale ? "Uso desatualizado: \($0)" : "Uso: \($0)" } ??
                    "Uso local ainda sem fonte confiável.",
                bundleIdentifier: app.bundleIdentifier
            )
        }
    }

    func statusCards(
        results: [String: PedroOpsSSHResult],
        targets: [PedroOpsSSHTarget] = Self.defaultTargets
    ) -> [PedroOpsCard] {
        targets.map { target in
            guard let result = results[target.id] else {
                return PedroOpsCard(
                    id: target.id,
                    title: target.title,
                    subtitle: target.hostAlias,
                    iconName: target.iconName,
                    state: .unknown,
                    metrics: [
                        PedroOpsMetric(label: "Conexão", value: "Aguardando"),
                        PedroOpsMetric(label: "Host", value: target.hostAlias)
                    ],
                    footnote: "Sem leitura SSH nesta abertura."
                )
            }

            guard result.isReachable else {
                let warning = Self.sshWarning(for: target, result: result)
                return PedroOpsCard(
                    id: target.id,
                    title: target.title,
                    subtitle: target.hostAlias,
                    iconName: target.iconName,
                    state: .warning,
                    metrics: warning.metrics,
                    footnote: warning.footnote
                )
            }

            let parsedMetrics = Self.prioritizedStatusMetrics(
                Self.metrics(fromSSHOutput: result.output),
                hostID: target.id
            )
            let metrics = parsedMetrics.isEmpty ? [
                PedroOpsMetric(label: "Dados", value: "Sem resposta")
            ] : parsedMetrics

            return PedroOpsCard(
                id: target.id,
                title: target.title,
                subtitle: target.hostAlias,
                iconName: target.iconName,
                state: parsedMetrics.isEmpty ? .warning : .active,
                metrics: metrics,
                footnote: parsedMetrics.isEmpty ? "SSH conectado, mas sem telemetria válida." : "Atualizado via SSH local."
            )
        }
    }

    func macCards(snapshot: PedroOpsMacSnapshot = .current()) -> [PedroOpsCard] {
        [
            PedroOpsCard(
                id: "mac-cpu",
                title: "CPU",
                subtitle: snapshot.hostName,
                iconName: "cpu.fill",
                state: snapshot.cpuUsagePercent == nil ? .warning : .active,
                metrics: [
                    PedroOpsMetric(label: "Uso", value: PedroOpsMacSnapshot.percentLabel(snapshot.cpuUsagePercent)),
                    PedroOpsMetric(label: "Térmico", value: snapshot.thermalState)
                ],
                footnote: "Amostra local curta."
            ),
            PedroOpsCard(
                id: "mac-gpu",
                title: "GPU",
                subtitle: "AGX",
                iconName: "display",
                state: snapshot.gpuUsagePercent == nil ? .warning : .active,
                metrics: [
                    PedroOpsMetric(label: "Uso", value: PedroOpsMacSnapshot.percentLabel(snapshot.gpuUsagePercent)),
                    PedroOpsMetric(label: "Fonte", value: "ioreg")
                ],
                footnote: "Leitura local da GPU."
            ),
            PedroOpsCard(
                id: "mac-ram",
                title: "RAM",
                subtitle: "Memória",
                iconName: "memorychip.fill",
                state: snapshot.memoryUsagePercent == nil ? .warning : .active,
                metrics: [
                    PedroOpsMetric(label: "Uso", value: PedroOpsMacSnapshot.percentLabel(snapshot.memoryUsagePercent)),
                    PedroOpsMetric(label: "Uptime", value: snapshot.uptime)
                ],
                footnote: "Active + wired + compressed."
            ),
            PedroOpsCard(
                id: "mac-ssd",
                title: "SSD",
                subtitle: "Volume /",
                iconName: "internaldrive.fill",
                state: snapshot.storageUsagePercent == nil ? .warning : .active,
                metrics: [
                    PedroOpsMetric(label: "Uso", value: PedroOpsMacSnapshot.percentLabel(snapshot.storageUsagePercent)),
                    PedroOpsMetric(label: "Fonte", value: "FileManager")
                ],
                footnote: "Espaço usado no volume raiz."
            )
        ]
    }

    func alertCards(
        snapshot: PedroOpsAlertsSnapshot,
        now: Date = Date()
    ) -> [PedroOpsCard] {
        guard !snapshot.alerts.isEmpty else {
            return [
                PedroOpsCard(
                    id: "alerts-empty",
                    title: "Sem alertas",
                    subtitle: "Tudo estável",
                    iconName: "checkmark.shield.fill",
                    state: .active,
                    metrics: [
                        PedroOpsMetric(label: "Críticos", value: "0"),
                        PedroOpsMetric(label: "Alertas", value: "0"),
                        PedroOpsMetric(label: "Infos", value: "0")
                    ],
                    footnote: "Sem ruído novo no momento."
                )
            ]
        }

        return snapshot.alerts.map { alert in
            let metrics = alert.metrics.isEmpty
                ? [PedroOpsMetric(label: "Estado", value: alert.severity.label)]
                : Array(alert.metrics.prefix(3))

            return PedroOpsCard(
                id: alert.id,
                title: alert.title,
                subtitle: alert.product,
                iconName: Self.iconName(for: alert),
                state: Self.cardState(for: alert.severity),
                metrics: metrics,
                footnote: Self.alertFootnote(for: alert, now: now)
            )
        }
    }

    private static func sshWarning(for target: PedroOpsSSHTarget, result: PedroOpsSSHResult) -> (metrics: [PedroOpsMetric], footnote: String) {
        let error = result.errorMessage ?? "SSH indisponível"
        if error.localizedCaseInsensitiveContains("could not resolve hostname") ||
            error.localizedCaseInsensitiveContains("nodename nor servname") {
            return (
                [
                    PedroOpsMetric(label: "Conexão", value: "Alias ausente"),
                    PedroOpsMetric(label: "Host", value: target.hostAlias),
                    PedroOpsMetric(label: "Erro", value: "DNS/config")
                ],
                "Host do Qdrant/Vault aplicado; confira Tailscale/DNS."
            )
        }

        if error.localizedCaseInsensitiveContains("permission denied") {
            return (
                [
                    PedroOpsMetric(label: "Conexão", value: "Sem chave"),
                    PedroOpsMetric(label: "Host", value: target.hostAlias),
                    PedroOpsMetric(label: "Erro", value: "Permissão")
                ],
                "Confira chave SSH autorizada para este usuário."
            )
        }

        if error.localizedCaseInsensitiveContains("operation timed out") ||
            error.localizedCaseInsensitiveContains("connection timed out") {
            return (
                [
                    PedroOpsMetric(label: "Conexão", value: "Timeout"),
                    PedroOpsMetric(label: "Host", value: target.hostAlias),
                    PedroOpsMetric(label: "Erro", value: "Rede")
                ],
                "Host não respondeu na porta 22 agora."
            )
        }

        return (
            [
                PedroOpsMetric(label: "Conexão", value: "Offline"),
                PedroOpsMetric(label: "Erro", value: error)
            ],
            "Confira rede e chave SSH."
        )
    }

    static func metrics(fromSSHOutput output: String) -> [PedroOpsMetric] {
        let labels = [
            "hostname": "Hostname",
            "model": "Modelo",
            "uptime": "Uptime",
            "load": "Carga",
            "cpu": "CPU",
            "cpu_model": "Processador",
            "cpu_clock": "Clock",
            "gpu": "GPU",
            "memory": "Memória",
            "disk": "Disco",
            "battery": "Bateria",
            "pools": "Pools",
            "temp": "Temp"
        ]

        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine -> PedroOpsMetric? in
                let parts = rawLine.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }

                let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, !value.isEmpty, let label = labels[key] else { return nil }

                return formattedSSHMetric(key: key, label: label, value: value)
            }
    }

    private struct PoolUsageDisplay {
        let name: String
        let text: String
        let percent: Int
        let order: Int
    }

    private static func formattedSSHMetric(key: String, label: String, value: String) -> PedroOpsMetric {
        switch key {
        case "memory":
            return formattedMemoryMetric(label: label, value: value)
        case "pools":
            return formattedPoolsMetric(label: label, value: value)
        case "cpu":
            return PedroOpsMetric(
                label: label,
                value: value,
                progressPercent: numericPercent(from: value)
            )
        case "cpu_model":
            return PedroOpsMetric(label: label, value: displayCPUName(value))
        case "gpu":
            return formattedGPUMetric(label: label, value: value)
        case "disk":
            return formattedDiskMetric(label: label, value: value)
        case "battery":
            return formattedBatteryMetric(label: label, value: value)
        case "temp":
            return PedroOpsMetric(label: label, value: formattedTemperatureValue(value))
        default:
            return PedroOpsMetric(label: label, value: value)
        }
    }

    private static func formattedMemoryMetric(label: String, value: String) -> PedroOpsMetric {
        let pieces = value
            .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard pieces.count == 2,
              let usedBytes = storageBytes(from: pieces[0]),
              let totalBytes = storageBytes(from: pieces[1]) else {
            let normalized = value
                .replacingOccurrences(of: "GiB", with: "GB")
                .replacingOccurrences(of: "Gi", with: "GB")
                .replacingOccurrences(of: "G", with: " GB")
                .replacingOccurrences(of: "  ", with: " ")
            return PedroOpsMetric(label: label, value: normalized)
        }

        let percent = percent(used: usedBytes, total: totalBytes)
        return PedroOpsMetric(
            label: label,
            value: "\(percent)%",
            detail: "\(compactGigabytes(usedBytes))/\(compactGigabytes(totalBytes)) GB",
            progressPercent: percent
        )
    }

    private static func formattedDiskMetric(label: String, value: String) -> PedroOpsMetric {
        if let range = value.range(of: #"[0-9]+%"#, options: .regularExpression),
           let percentage = numericPercent(from: String(value[range])) {
            return PedroOpsMetric(label: label, value: "\(percentage)%", progressPercent: percentage)
        }
        let pieces = value
            .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard pieces.count == 2,
              let usedBytes = storageBytes(from: pieces[0]),
              let totalBytes = storageBytes(from: pieces[1]),
              totalBytes > 0 else {
            return PedroOpsMetric(
                label: label,
                value: value,
                progressPercent: numericPercent(from: value)
            )
        }

        let usagePercent = percent(used: usedBytes, total: totalBytes)
        return PedroOpsMetric(
            label: label,
            value: "\(usagePercent)%",
            detail: "\(compactStorageCapacity(usedBytes))/\(compactStorageCapacity(totalBytes))",
            progressPercent: usagePercent
        )
    }

    private static func formattedBatteryMetric(label: String, value: String) -> PedroOpsMetric {
        let parts = value
            .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let percentage = numericPercent(from: parts.first ?? value)
        let statusCode = parts.count > 1 ? Int(parts[1]) : nil
        let detail: String?
        switch statusCode {
        case 2, 3:
            detail = "na tomada"
        case 6, 7, 8, 9:
            detail = "carregando"
        case 1:
            detail = "na bateria"
        default:
            detail = nil
        }

        return PedroOpsMetric(
            label: label,
            value: percentage.map { "\($0)%" } ?? parts[0],
            detail: detail,
            progressPercent: percentage
        )
    }

    private static func formattedPoolsMetric(label: String, value: String) -> PedroOpsMetric {
        let formattedPools = value
            .split(separator: ",")
            .compactMap { formattedPoolEntry(String($0)) }
        let dataPools = formattedPools.filter { $0.order < 90 }
        let poolsToDisplay = dataPools.isEmpty ? formattedPools : dataPools
        guard !poolsToDisplay.isEmpty else {
            let normalized = value
                .replacingOccurrences(of: "PrimaryPool", with: "Principal")
                .replacingOccurrences(of: "ArchivePool", with: "Arquivo")
                .replacingOccurrences(of: "boot-pool", with: "Boot")
            return PedroOpsMetric(label: label, value: normalized)
        }

        let sortedPools = poolsToDisplay
            .sorted {
                if $0.order == $1.order {
                    return $0.name < $1.name
                }
                return $0.order < $1.order
            }
        let primaryPool = sortedPools.first
        let secondaryPool = sortedPools.dropFirst().first

        return PedroOpsMetric(
            label: label,
            value: primaryPool?.text ?? "--",
            progressPercent: primaryPool?.percent,
            secondaryValue: secondaryPool?.text,
            secondaryProgressPercent: secondaryPool?.percent
        )
    }

    private static func formattedPoolEntry(_ rawEntry: String) -> PoolUsageDisplay? {
        let parts = rawEntry
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard parts.count >= 4 else {
            return nil
        }

        let name = displayPoolName(parts[0])
        let percent = Int(parts[3].trimmingCharacters(in: CharacterSet(charactersIn: "%"))) ?? 0
        return PoolUsageDisplay(
            name: name,
            text: "\(name) \(percent)%",
            percent: percent,
            order: poolDisplayOrder(name)
        )
    }

    private static func displayPoolName(_ rawName: String) -> String {
        switch rawName {
        case "PrimaryPool":
            return "Principal"
        case "ArchivePool":
            return "Arquivo"
        case "boot-pool":
            return "Boot"
        default:
            return rawName
                .replacingOccurrences(of: "Principal_", with: "")
                .replacingOccurrences(of: "_", with: " ")
        }
    }

    private static func poolDisplayOrder(_ name: String) -> Int {
        switch name {
        case "Principal":
            return 0
        case "Arquivo":
            return 1
        case "Boot":
            return 99
        default:
            return 50
        }
    }

    private static func storageBytes(from rawValue: String) -> Double? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bytes = Double(trimmed), trimmed.rangeOfCharacter(from: CharacterSet.letters) == nil {
            return bytes
        }

        let pattern = #"([0-9]+(?:\.[0-9]+)?)\s*([KMGTPE](?:i?B?)?|B)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range),
              let numberRange = Range(match.range(at: 1), in: trimmed),
              let unitRange = Range(match.range(at: 2), in: trimmed),
              let number = Double(trimmed[numberRange]) else {
            return nil
        }

        let unit = String(trimmed[unitRange]).uppercased()
        let isBinary = unit.contains("I")
        let base = isBinary ? 1024.0 : 1000.0
        let exponent: Double
        switch unit.first {
        case "K":
            exponent = 1
        case "M":
            exponent = 2
        case "G":
            exponent = 3
        case "T":
            exponent = 4
        case "P":
            exponent = 5
        case "E":
            exponent = 6
        default:
            exponent = 0
        }

        return number * pow(base, exponent)
    }

    private static func compactGigabytes(_ bytes: Double) -> String {
        String(Int((bytes / 1_000_000_000).rounded()))
    }

    private static func compactStorageCapacity(_ bytes: Double) -> String {
        if bytes >= 1_000_000_000_000 {
            let terabytes = bytes / 1_000_000_000_000
            return terabytes >= 10
                ? "\(Int(terabytes.rounded())) TB"
                : String(format: "%.1f TB", terabytes)
        }
        return "\(Int((bytes / 1_000_000_000).rounded())) GB"
    }

    private static func formattedGPUMetric(label: String, value: String) -> PedroOpsMetric {
        let parts = value
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        if parts.count >= 6, let index = Int(parts[0]) {
            let usagePercent = Int(parts[2]).map { min(100, max(0, $0)) }
            let memoryUsedMiB = Double(parts[3])
            let memoryTotalMiB = Double(parts[4])
            let memoryValue: String?
            let memoryPercent: Int?
            if let used = memoryUsedMiB, let total = memoryTotalMiB, total > 0 {
                memoryValue = "\(compactVRAMGigabytes(used))/\(compactVRAMGigabytes(total)) GB"
                memoryPercent = percent(used: used, total: total)
            } else {
                memoryValue = nil
                memoryPercent = nil
            }
            let gpuName = displayGPUName(parts[1])
            let temperature = Int(parts[5]).map { "\($0)°C" }
            return PedroOpsMetric(
                label: "GPU \(index) · \(gpuName)",
                value: usagePercent.map { "\($0)%" } ?? "--",
                detail: temperature,
                progressPercent: usagePercent,
                secondaryValue: memoryValue,
                secondaryProgressPercent: memoryPercent
            )
        }

        let usage = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? value
        let detail = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil
        return PedroOpsMetric(
            label: label,
            value: usage,
            detail: detail?.isEmpty == true ? nil : detail,
            progressPercent: numericPercent(from: usage)
        )
    }

    private static func displayGPUName(_ rawName: String) -> String {
        rawName
            .replacingOccurrences(of: "NVIDIA GeForce ", with: "")
            .replacingOccurrences(of: "NVIDIA ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func displayCPUName(_ rawName: String) -> String {
        let normalized = rawName
            .replacingOccurrences(of: "(R)", with: "")
            .replacingOccurrences(of: "(TM)", with: "")
            .replacingOccurrences(of: "Intel Core", with: "")
            .replacingOccurrences(of: "Intel  Core", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = normalized.range(
            of: #"i[3579]-[0-9A-Za-z]+"#,
            options: .regularExpression
        ) {
            return String(normalized[match])
        }
        return normalized
    }

    private static func compactVRAMGigabytes(_ mebibytes: Double) -> String {
        let gigabytes = max(0, mebibytes) / 1024
        let rounded = gigabytes.rounded()
        if abs(gigabytes - rounded) < 0.05 || gigabytes >= 10 {
            return String(Int(rounded))
        }
        return String(format: "%.1f", gigabytes)
    }

    private static func percent(used: Double, total: Double) -> Int {
        guard total > 0 else { return 0 }
        return min(100, max(0, Int((used / total * 100).rounded())))
    }

    private static func numericPercent(from value: String) -> Int? {
        let digits = value.trimmingCharacters(in: CharacterSet(charactersIn: "% ").union(.whitespacesAndNewlines))
        return Int(digits)
    }

    private static func formattedTemperatureValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: " C", with: "°C")
            .replacingOccurrences(of: "C", with: "°C")
            .replacingOccurrences(of: "°°C", with: "°C")
            .replacingOccurrences(of: " ", with: "")
    }

    private static func prioritizedStatusMetrics(_ metrics: [PedroOpsMetric], hostID: String) -> [PedroOpsMetric] {
        let priority: [String]
        switch hostID {
        case "x99":
            priority = ["CPU", "GPU", "Temp", "Memória", "Disco", "Carga", "Uptime", "Hostname"]
        case "alienware":
            priority = ["GPU", "CPU", "Processador", "Clock", "Memória", "Disco", "Bateria", "Modelo", "Uptime", "Hostname"]
        default:
            priority = ["Pools", "Memória", "Temp", "Disco", "Carga", "Uptime", "Hostname"]
        }
        return metrics.sorted { lhs, rhs in
            let left = statusMetricPriority(lhs, labels: priority, hostID: hostID)
            let right = statusMetricPriority(rhs, labels: priority, hostID: hostID)
            if left == right {
                return lhs.label < rhs.label
            }
            return left < right
        }
    }

    private static func statusMetricPriority(
        _ metric: PedroOpsMetric,
        labels: [String],
        hostID: String
    ) -> Int {
        if (hostID == "x99" || hostID == "alienware"), metric.label.hasPrefix("GPU ") {
            let index = metric.label
                .split(separator: " ", maxSplits: 2)
                .dropFirst()
                .first
                .flatMap { Int($0) } ?? 0
            return (labels.firstIndex(of: "GPU") ?? 1) + index
        }
        guard let index = labels.firstIndex(of: metric.label) else {
            return labels.count + 10
        }
        if hostID == "x99", index >= 2 {
            return index + 2
        }
        return index
    }

    private static func formatTokenCount(_ count: Int?) -> String {
        guard let count else { return "--" }
        let absolute = Double(max(0, count))
        if absolute >= 1_000_000 {
            return String(format: "%.1fM", absolute / 1_000_000)
        }
        if absolute >= 1_000 {
            return "\(Int((absolute / 1_000).rounded()))K"
        }
        return "\(Int(absolute))"
    }

    private static func cardState(for severity: PedroOpsAlertSeverity) -> PedroOpsCardState {
        switch severity {
        case .critical:
            return .offline
        case .warning:
            return .warning
        case .info:
            return .active
        }
    }

    private static func iconName(for alert: PedroOpsAlert) -> String {
        if alert.id.hasPrefix("usage.claude") {
            return "sparkles"
        }
        if alert.id.hasPrefix("usage.codex") {
            return "terminal.fill"
        }
        if alert.id.hasPrefix("ssh.truenas") {
            return "externaldrive.fill"
        }
        if alert.id.hasPrefix("ssh.x99") {
            return "desktopcomputer"
        }
        if alert.id.hasPrefix("mac.") {
            return "laptopcomputer"
        }
        return "bell.badge.fill"
    }

    private static func alertFootnote(for alert: PedroOpsAlert, now: Date) -> String {
        let relative = relativeAlertTimestamp(from: alert.lastChangedAt, now: now)
        if let detail = alert.detail, !detail.isEmpty {
            return "\(detail) · \(relative)"
        }
        return "\(alert.severity.label) · \(relative)"
    }

    private static func relativeAlertTimestamp(from date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 {
            return "agora"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h"
        }
        return "\(hours / 24)d"
    }
}

extension PedroOpsUsageSnapshot {
    static func current() -> PedroOpsUsageSnapshot {
        let usageByID = [
            "claude": PedroOpsClaudeUsageReader.summary(),
            "codex": PedroOpsCodexUsageReader.summary(
                appServerOutput: PedroOpsCodexAppServerClient.fetch()
            )
        ]

        return from(summaries: usageByID)
    }

    static func from(summaries usageByID: [String: PedroOpsUsageWindowSummary]) -> PedroOpsUsageSnapshot {
        let targets: [(id: String, title: String, bundleIdentifier: String, iconName: String)] = [
            ("claude", "Claude", "com.anthropic.claudefordesktop", "sparkles"),
            ("codex", "Codex", "com.openai.codex", "terminal.fill")
        ]
        let runningApps = NSWorkspace.shared.runningApplications
        let windowsByPID = Self.visibleWindowCountsByProcessID()

        return PedroOpsUsageSnapshot(apps: targets.map { target in
            let matches = runningApps.filter { app in
                app.bundleIdentifier == target.bundleIdentifier || app.localizedName == target.title
            }
            let windowCount = matches.reduce(0) { total, app in
                total + (windowsByPID[app.processIdentifier] ?? 0)
            }
            let usage = usageByID[target.id] ?? PedroOpsUsageWindowSummary.empty

            return PedroOpsUsageAppSnapshot(
                id: target.id,
                title: target.title,
                bundleIdentifier: target.bundleIdentifier,
                iconName: target.iconName,
                isRunning: !matches.isEmpty,
                windowCount: !matches.isEmpty ? windowCount : 0,
                isFrontmost: matches.contains(where: \.isActive),
                lastFiveHoursTokens: usage.lastFiveHoursTokens,
                lastWeekTokens: usage.lastWeekTokens,
                sessionCount: usage.sessionCount ?? (!matches.isEmpty ? windowCount : nil),
                usageSource: usage.source ?? (!matches.isEmpty ? "janelas visíveis" : nil),
                lastFiveHoursDisplay: usage.lastFiveHoursDisplay,
                lastWeekDisplay: usage.lastWeekDisplay,
                lastFiveHoursDetail: usage.lastFiveHoursDetail,
                lastWeekDetail: usage.lastWeekDetail,
                lastFiveHoursProgressPercent: usage.lastFiveHoursProgressPercent,
                lastWeekProgressPercent: usage.lastWeekProgressPercent,
                lastFiveHoursProgressStyle: usage.lastFiveHoursProgressStyle,
                lastWeekProgressStyle: usage.lastWeekProgressStyle,
                isUsageStale: usage.isStale
            )
        })
    }

    private static func visibleWindowCountsByProcessID() -> [pid_t: Int] {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return [:]
        }

        var counts: [pid_t: Int] = [:]
        for window in windowInfo {
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard layer == 0, alpha > 0 else { continue }
            guard let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
            counts[ownerPID, default: 0] += 1
        }

        return counts
    }
}

struct PedroOpsUsageWindowSummary {
    let lastFiveHoursTokens: Int?
    let lastWeekTokens: Int?
    let sessionCount: Int?
    let source: String?
    var lastFiveHoursDisplay: String? = nil
    var lastWeekDisplay: String? = nil
    var lastFiveHoursDetail: String? = nil
    var lastWeekDetail: String? = nil
    var lastFiveHoursProgressPercent: Int? = nil
    var lastWeekProgressPercent: Int? = nil
    var lastFiveHoursProgressStyle: PedroOpsMetricProgressStyle = .quota
    var lastWeekProgressStyle: PedroOpsMetricProgressStyle = .quota
    var isStale: Bool = false
    var fiveHourResetsAt: Date? = nil
    var weekResetsAt: Date? = nil

    func checkingFreshness(observedAt: Date?, now: Date = Date()) -> Self {
        var next = self
        if now.timeIntervalSince(observedAt ?? .distantPast) >= 60 { next.isStale = true }
        if let reset = fiveHourResetsAt, now >= reset {
            next.lastFiveHoursDisplay = "0%"
            next.lastFiveHoursProgressPercent = 0
            next.lastFiveHoursDetail = "Janela renovada"
        }
        if let reset = weekResetsAt, now >= reset {
            next.lastWeekDisplay = "0%"
            next.lastWeekProgressPercent = 0
            next.lastWeekDetail = "Janela renovada"
        }
        return next
    }

    static let empty = PedroOpsUsageWindowSummary(
        lastFiveHoursTokens: nil,
        lastWeekTokens: nil,
        sessionCount: nil,
        source: nil
    )
}

enum PedroOpsUserHome {
    static func candidatePaths(preferredHome: String? = nil) -> [String] {
        var candidates: [String] = []

        if let preferredHome = preferredHome?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preferredHome.isEmpty {
            candidates.append(preferredHome)
        }

        if let environmentHome = ProcessInfo.processInfo.environment["HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !environmentHome.isEmpty {
            candidates.append(environmentHome)
        }

        let fileManagerHome = FileManager.default.homeDirectoryForCurrentUser.path
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !fileManagerHome.isEmpty {
            candidates.append(fileManagerHome)
        }

        if let passwd = getpwuid(getuid()), let directory = passwd.pointee.pw_dir {
            let passwdHome = String(cString: directory).trimmingCharacters(in: .whitespacesAndNewlines)
            if !passwdHome.isEmpty {
                candidates.append(passwdHome)
            }
        }

        let nsHome = NSHomeDirectory().trimmingCharacters(in: .whitespacesAndNewlines)
        if !nsHome.isEmpty {
            candidates.append(nsHome)
        }

        return Array(NSOrderedSet(array: candidates)) as? [String] ?? candidates
    }

    static var candidatePaths: [String] {
        candidatePaths(preferredHome: nil)
    }

    static var path: String {
        for candidate in candidatePaths where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        return NSHomeDirectory()
    }

    static var realPath: String {
        candidatePaths.first { candidate in
            FileManager.default.fileExists(atPath: candidate + "/.codex") ||
                FileManager.default.fileExists(atPath: candidate + "/.claude")
        } ?? path
    }

    static func existingHomeRelativePath(
        _ relativePath: String,
        preferredHome: String? = nil,
        isDirectory: Bool = false
    ) -> String? {
        for home in candidatePaths(preferredHome: preferredHome) {
            let candidate = home + relativePath
            var candidateIsDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &candidateIsDirectory) {
                if !isDirectory || candidateIsDirectory.boolValue {
                    return candidate
                }
            }
        }
        return nil
    }

    static func existingHomeRelativeURL(
        _ relativePath: String,
        preferredHome: String? = nil,
        isDirectory: Bool = false
    ) -> URL? {
        existingHomeRelativePath(
            relativePath,
            preferredHome: preferredHome,
            isDirectory: isDirectory
        ).map { URL(fileURLWithPath: $0, isDirectory: isDirectory) }
    }
}

struct PedroOpsCodexTokenLimits: Equatable {
    let fiveHourTokens: Int
    let weekTokens: Int

    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> PedroOpsCodexTokenLimits {
        PedroOpsCodexTokenLimits(
            fiveHourTokens: configuredTokenLimit(
                environmentKey: "PEDROOPS_CODEX_5H_TOKEN_LIMIT",
                defaultsKey: "codex_five_hour_token_limit",
                fallback: 80_000_000,
                environment: environment,
                defaults: defaults
            ),
            weekTokens: configuredTokenLimit(
                environmentKey: "PEDROOPS_CODEX_WEEK_TOKEN_LIMIT",
                defaultsKey: "codex_week_token_limit",
                fallback: 300_000_000,
                environment: environment,
                defaults: defaults
            )
        )
    }

    private static func configuredTokenLimit(
        environmentKey: String,
        defaultsKey: String,
        fallback: Int,
        environment: [String: String],
        defaults: UserDefaults
    ) -> Int {
        if let rawValue = environment[environmentKey],
           let value = Int(rawValue),
           value > 0 {
            return value
        }

        let defaultsValue = defaults.integer(forKey: defaultsKey)
        return defaultsValue > 0 ? defaultsValue : fallback
    }
}

struct PedroOpsCodexLiveRateLimitWindow: Equatable {
    let usedPercent: Int
    let resetsAt: Date?
}

struct PedroOpsCodexLiveRateLimits: Equatable {
    let windows: [Int: PedroOpsCodexLiveRateLimitWindow]
    let planType: String?
}

enum PedroOpsCodexAppServerClient {

    static let requestPayload = """
    {"id":1,"method":"initialize","params":{"clientInfo":{"name":"boring-notch-pedro","title":"Boring Notch Pedro","version":"1"},"capabilities":{}}}
    {"method":"initialized","params":{}}
    {"id":2,"method":"account/rateLimits/read","params":null}

    """

    static func fetch(timeout: TimeInterval = 4) -> String? {
        guard let executableURL = executableURL() else { return nil }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let completion = DispatchSemaphore(value: 0)
        let responseReady = DispatchSemaphore(value: 0)
        let outputLock = NSLock()
        var outputData = Data()
        var didReceiveResponse = false

        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.environment = processEnvironment(
            base: ProcessInfo.processInfo.environment,
            userHome: PedroOpsUserHome.realPath
        )
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in completion.signal() }
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }

            outputLock.lock()
            outputData.append(chunk)
            let shouldSignal = !didReceiveResponse && containsRateLimitResponse(in: outputData)
            if shouldSignal {
                didReceiveResponse = true
            }
            outputLock.unlock()

            if shouldSignal {
                responseReady.signal()
            }
        }

        do {
            try process.run()
            try inputPipe.fileHandleForWriting.write(contentsOf: Data(requestPayload.utf8))
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
            }
            return nil
        }

        guard responseReady.wait(timeout: .now() + timeout) == .success else {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            try? inputPipe.fileHandleForWriting.close()
            process.terminate()
            _ = completion.wait(timeout: .now() + 0.5)
            return nil
        }

        try? inputPipe.fileHandleForWriting.close()
        _ = completion.wait(timeout: .now() + 0.5)
        if process.isRunning {
            process.terminate()
        }
        outputPipe.fileHandleForReading.readabilityHandler = nil

        outputLock.lock()
        let data = outputData
        outputLock.unlock()
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func processEnvironment(
        base: [String: String],
        userHome: String
    ) -> [String: String] {
        var environment = base
        environment["HOME"] = userHome
        environment["CODEX_HOME"] = userHome + "/.codex"
        return environment
    }

    static func parseRateLimits(from output: String) -> PedroOpsCodexLiveRateLimits? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  requestID(from: object["id"]) == 2,
                  let result = object["result"] as? [String: Any] else {
                continue
            }

            let rateLimitsByID = result["rateLimitsByLimitId"] as? [String: Any]
            let selected = (rateLimitsByID?["codex"] as? [String: Any]) ??
                (result["rateLimits"] as? [String: Any])
            guard let selected else { continue }

            var windows: [Int: PedroOpsCodexLiveRateLimitWindow] = [:]
            for key in ["primary", "secondary"] {
                guard let window = selected[key] as? [String: Any],
                      let minutes = integer(from: window["windowDurationMins"]),
                      let usedPercent = integer(from: window["usedPercent"]) else {
                    continue
                }
                windows[minutes] = PedroOpsCodexLiveRateLimitWindow(
                    usedPercent: min(100, max(0, usedPercent)),
                    resetsAt: epochDate(from: window["resetsAt"])
                )
            }

            guard !windows.isEmpty else { continue }
            return PedroOpsCodexLiveRateLimits(
                windows: windows,
                planType: selected["planType"] as? String
            )
        }

        return nil
    }

    static func executableCandidates(environment: [String: String], applicationPaths: [String]) -> [String] {
        var candidates: [String] = []
        if let configuredPath = environment["CODEX_CLI_PATH"],
           !configuredPath.isEmpty {
            candidates.append(configuredPath)
        }
        for path in applicationPaths {
            candidates.append(path + "/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
            candidates.append(path + "/Contents/Resources/codex")
        }
        candidates += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        return candidates
    }

    private static func executableURL() -> URL? {
        let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")?.path
        let candidates = executableCandidates(
            environment: ProcessInfo.processInfo.environment,
            applicationPaths: [registered, "/Applications/ChatGPT.app", "/Applications/Codex.app"].compactMap { $0 }
        )

        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    private static func requestID(from value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func containsRateLimitResponse(in data: Data) -> Bool {
        guard let output = String(data: data, encoding: .utf8) else { return false }
        return output.split(whereSeparator: \.isNewline).contains { line in
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                return false
            }
            return requestID(from: object["id"]) == 2
        }
    }

    private static func integer(from value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func epochDate(from value: Any?) -> Date? {
        guard let seconds = integer(from: value) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}

enum PedroOpsCodexUsageReader {
    private struct RateLimitWindow {
        let usedPercent: Int?
        let windowMinutes: Int?
        let resetsAt: Date?
    }

    private struct RateLimitSnapshot {
        let timestamp: Date?
        let primary: RateLimitWindow?
        let secondary: RateLimitWindow?
        let planType: String?
    }

    static func summary(
        databasePath: String = databasePath(),
        now: Date = Date(),
        sessionsDirectory: String = sessionsDirectory(),
        tokenLimits: PedroOpsCodexTokenLimits = .current(),
        appServerOutput: String? = nil
    ) -> PedroOpsUsageWindowSummary {
        let tokenSummary = summaryFromDatabase(databasePath: databasePath, now: now, tokenLimits: tokenLimits)
        if let appServerOutput,
           let liveRateLimits = PedroOpsCodexAppServerClient.parseRateLimits(from: appServerOutput) {
            return summary(from: liveRateLimits, tokenSummary: tokenSummary, now: now)
        }
        guard let rateLimits = latestRateLimits(in: sessionsDirectory) else {
            return PedroOpsUsageWindowSummary(
                lastFiveHoursTokens: tokenSummary.lastFiveHoursTokens,
                lastWeekTokens: tokenSummary.lastWeekTokens,
                sessionCount: tokenSummary.sessionCount,
                source: "Limites indisponíveis",
                lastFiveHoursDisplay: "--",
                lastWeekDisplay: "--",
                lastFiveHoursDetail: "Sem janela",
                lastWeekDetail: "Aguardando leitura",
                isStale: true
            )
        }

        return summary(from: rateLimits, tokenSummary: tokenSummary, now: now)
    }

    static func databasePath(
        userHome: String? = nil,
        fallbackHomes: [String] = []
    ) -> String {
        let candidateHomes = homeCandidates(userHome: userHome, fallbackHomes: fallbackHomes)
        return exactHomeRelativePath(
            "/.codex/state_5.sqlite",
            candidateHomes: candidateHomes
        ) ?? ((userHome ?? candidateHomes.first ?? NSHomeDirectory()) + "/.codex/state_5.sqlite")
    }

    static func sessionsDirectory(
        userHome: String? = nil,
        fallbackHomes: [String] = []
    ) -> String {
        let candidateHomes = homeCandidates(userHome: userHome, fallbackHomes: fallbackHomes)
        return exactHomeRelativePath(
            "/.codex/sessions",
            candidateHomes: candidateHomes,
            isDirectory: true
        ) ?? ((userHome ?? candidateHomes.first ?? NSHomeDirectory()) + "/.codex/sessions")
    }

    private static func summaryFromDatabase(
        databasePath: String,
        now: Date,
        tokenLimits: PedroOpsCodexTokenLimits
    ) -> PedroOpsUsageWindowSummary {
        guard FileManager.default.fileExists(atPath: databasePath) else {
            return .empty
        }

        guard let database = openDatabase(at: databasePath) else {
            return .empty
        }
        defer { sqlite3_close(database) }

        let nowSeconds = Int(now.timeIntervalSince1970)
        let fiveHourCutoff = nowSeconds - (5 * 60 * 60)
        let weekCutoff = nowSeconds - (7 * 24 * 60 * 60)
        let lastFiveHoursTokens = sumTokens(in: database, updatedAfter: fiveHourCutoff)
        let lastWeekTokens = sumTokens(in: database, updatedAfter: weekCutoff)
        return PedroOpsUsageWindowSummary(
            lastFiveHoursTokens: lastFiveHoursTokens,
            lastWeekTokens: lastWeekTokens,
            sessionCount: countSessions(in: database, updatedAfter: weekCutoff),
            source: "~/.codex/state_5.sqlite (limite estimado)",
            lastFiveHoursDisplay: quotaDisplay(usedTokens: lastFiveHoursTokens, tokenLimit: tokenLimits.fiveHourTokens),
            lastWeekDisplay: quotaDisplay(usedTokens: lastWeekTokens, tokenLimit: tokenLimits.weekTokens),
            lastFiveHoursDetail: quotaDetail(usedTokens: lastFiveHoursTokens, tokenLimit: tokenLimits.fiveHourTokens),
            lastWeekDetail: quotaDetail(usedTokens: lastWeekTokens, tokenLimit: tokenLimits.weekTokens),
            lastFiveHoursProgressPercent: quotaPercent(usedTokens: lastFiveHoursTokens, tokenLimit: tokenLimits.fiveHourTokens),
            lastWeekProgressPercent: quotaPercent(usedTokens: lastWeekTokens, tokenLimit: tokenLimits.weekTokens),
            lastFiveHoursProgressStyle: .quota,
            lastWeekProgressStyle: .quota
        )
    }

    private static func summary(
        from rateLimits: RateLimitSnapshot,
        tokenSummary: PedroOpsUsageWindowSummary,
        now: Date,
        source: String? = nil
    ) -> PedroOpsUsageWindowSummary {
        let fiveHourWindow = window(in: rateLimits, matchingMinutes: 300)
        let weekWindow = window(in: rateLimits, matchingMinutes: 10_080)
        let primaryPercent = effectivePercent(
            from: fiveHourWindow?.usedPercent,
            resetsAt: fiveHourWindow?.resetsAt,
            now: now
        )
        let secondaryPercent = effectivePercent(
            from: weekWindow?.usedPercent,
            resetsAt: weekWindow?.resetsAt,
            now: now
        )
        return PedroOpsUsageWindowSummary(
            lastFiveHoursTokens: tokenSummary.lastFiveHoursTokens,
            lastWeekTokens: tokenSummary.lastWeekTokens,
            sessionCount: tokenSummary.sessionCount,
            source: source ?? sourceLabel(for: rateLimits),
            lastFiveHoursDisplay: percentDisplay(primaryPercent) ?? "--",
            lastWeekDisplay: percentDisplay(secondaryPercent) ?? "--",
            lastFiveHoursDetail: activeResetLabel(
                for: fiveHourWindow?.resetsAt,
                now: now,
                format: "HH:mm"
            ) ?? "Sem janela",
            lastWeekDetail: activeResetLabel(
                for: weekWindow?.resetsAt,
                now: now,
                format: "dd/MM HH:mm"
            ) ?? "Sem janela",
            lastFiveHoursProgressPercent: primaryPercent,
            lastWeekProgressPercent: secondaryPercent,
            lastFiveHoursProgressStyle: .quota,
            lastWeekProgressStyle: .quota,
            isStale: true,
            fiveHourResetsAt: fiveHourWindow?.resetsAt,
            weekResetsAt: weekWindow?.resetsAt
        )
    }

    private static func summary(
        from liveRateLimits: PedroOpsCodexLiveRateLimits,
        tokenSummary: PedroOpsUsageWindowSummary,
        now: Date
    ) -> PedroOpsUsageWindowSummary {
        let fiveHourWindow = liveRateLimits.windows[300]
        let weekWindow = liveRateLimits.windows[10_080]
        let fiveHourPercent = effectivePercent(
            from: fiveHourWindow?.usedPercent,
            resetsAt: fiveHourWindow?.resetsAt,
            now: now
        )
        let weekPercent = effectivePercent(
            from: weekWindow?.usedPercent,
            resetsAt: weekWindow?.resetsAt,
            now: now
        )
        let planSuffix = liveRateLimits.planType.map { " \($0)" } ?? ""
        return PedroOpsUsageWindowSummary(
            lastFiveHoursTokens: tokenSummary.lastFiveHoursTokens,
            lastWeekTokens: tokenSummary.lastWeekTokens,
            sessionCount: tokenSummary.sessionCount,
            source: "Codex app-server\(planSuffix)",
            lastFiveHoursDisplay: percentDisplay(fiveHourPercent) ?? "—",
            lastWeekDisplay: percentDisplay(weekPercent) ?? "—",
            lastFiveHoursDetail: fiveHourWindow.flatMap {
                activeResetLabel(for: $0.resetsAt, now: now, format: "HH:mm")
            } ?? "Sem janela",
            lastWeekDetail: weekWindow.flatMap {
                activeResetLabel(for: $0.resetsAt, now: now, format: "dd/MM HH:mm")
            } ?? "Sem janela",
            lastFiveHoursProgressPercent: fiveHourWindow == nil ? nil : fiveHourPercent,
            lastWeekProgressPercent: weekWindow == nil ? nil : weekPercent,
            lastFiveHoursProgressStyle: .quota,
            lastWeekProgressStyle: .quota,
            fiveHourResetsAt: fiveHourWindow?.resetsAt,
            weekResetsAt: weekWindow?.resetsAt
        )
    }

    private static func latestRateLimits(in sessionsDirectory: String) -> RateLimitSnapshot? {
        let rootURL = URL(fileURLWithPath: sessionsDirectory, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: []
        ) else {
            return nil
        }

        var files: [(url: URL, modifiedAt: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            files.append((url, values?.contentModificationDate ?? .distantPast))
        }

        var latest: RateLimitSnapshot?
        let candidates = files
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(40)

        for candidate in candidates {
            guard let rateLimits = lastRateLimits(in: candidate.url) else { continue }
            if isNewer(rateLimits, than: latest) {
                latest = rateLimits
            }
        }

        return latest
    }

    static func recentLogTail(at url: URL, maximumBytes: Int = 512 * 1024) -> String? {
        guard maximumBytes > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
        do {
            try handle.seek(toOffset: offset)
            guard var data = try handle.read(upToCount: maximumBytes) else { return nil }
            // A bounded tail may begin inside a JSON line or a UTF-8 character.
            if offset > 0 {
                guard let newline = data.firstIndex(of: 10) else { return nil }
                data = data.suffix(from: data.index(after: newline))
            }
            return String(decoding: data, as: UTF8.self)
        } catch { return nil }
    }

    private static func lastRateLimits(in url: URL) -> RateLimitSnapshot? {
        guard let content = recentLogTail(at: url) else { return nil }

        for rawLine in content.split(whereSeparator: \.isNewline).reversed() {
            guard rawLine.contains("\"rate_limits\"") else { continue }
            if let snapshot = parseRateLimitsLine(String(rawLine)) {
                return snapshot
            }
        }

        return nil
    }

    private static func parseRateLimitsLine(_ line: String) -> RateLimitSnapshot? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let payload = (object["payload"] as? [String: Any]) ?? object
        guard let rateLimits = payload["rate_limits"] as? [String: Any] else {
            return nil
        }

        let primary = rateLimits["primary"] as? [String: Any]
        let secondary = rateLimits["secondary"] as? [String: Any]
        let primaryPercent = percent(from: primary?["used_percent"])
        let secondaryPercent = percent(from: secondary?["used_percent"])
        guard primaryPercent != nil || secondaryPercent != nil else {
            return nil
        }

        return RateLimitSnapshot(
            timestamp: isoDate(from: object["timestamp"]),
            primary: RateLimitWindow(
                usedPercent: primaryPercent,
                windowMinutes: windowMinutes(from: primary?["window_minutes"]),
                resetsAt: epochDate(from: primary?["resets_at"])
            ),
            secondary: RateLimitWindow(
                usedPercent: secondaryPercent,
                windowMinutes: windowMinutes(from: secondary?["window_minutes"]),
                resetsAt: epochDate(from: secondary?["resets_at"])
            ),
            planType: rateLimits["plan_type"] as? String
        )
    }

    private static func isNewer(_ candidate: RateLimitSnapshot, than current: RateLimitSnapshot?) -> Bool {
        guard let current else { return true }
        return (candidate.timestamp ?? .distantPast) > (current.timestamp ?? .distantPast)
    }

    private static func openDatabase(at path: String) -> OpaquePointer? {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
        let uri = URL(fileURLWithPath: path).absoluteString + "?mode=ro"
        guard sqlite3_open_v2(uri, &database, flags, nil) == SQLITE_OK, let database else {
            if let database {
                sqlite3_close(database)
            }
            return nil
        }
        return database
    }

    private static func sumTokens(in database: OpaquePointer, updatedAfter cutoff: Int) -> Int? {
        let query = "SELECT COALESCE(SUM(tokens_used), 0) FROM threads WHERE updated_at >= ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, sqlite3_int64(cutoff))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func countSessions(in database: OpaquePointer, updatedAfter cutoff: Int) -> Int? {
        let query = "SELECT COUNT(*) FROM threads WHERE updated_at >= ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, sqlite3_int64(cutoff))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func quotaDisplay(usedTokens: Int?, tokenLimit: Int) -> String? {
        guard let percent = quotaPercent(usedTokens: usedTokens, tokenLimit: tokenLimit) else {
            return nil
        }
        return "\(percent)%"
    }

    private static func quotaDetail(usedTokens: Int?, tokenLimit: Int) -> String? {
        guard let usedTokens else { return nil }
        return "\(formatTokenCount(usedTokens) ?? "0") / \(formatTokenCount(tokenLimit) ?? "0")"
    }

    private static func quotaPercent(usedTokens: Int?, tokenLimit: Int) -> Int? {
        guard let usedTokens, tokenLimit > 0 else { return nil }
        return min(100, max(0, Int((Double(usedTokens) / Double(tokenLimit) * 100).rounded())))
    }

    private static func percentDisplay(_ percent: Int?) -> String? {
        percent.map { "\($0)%" }
    }

    private static func effectivePercent(from percent: Int?, resetsAt: Date?, now: Date) -> Int? {
        guard let percent else { return nil }
        if let resetsAt, now >= resetsAt {
            return 0
        }
        return percent
    }

    private static func activeResetLabel(for date: Date?, now: Date, format: String) -> String? {
        guard let date else { return nil }
        if now >= date { return "Janela renovada" }
        return resetLabel(for: date, format: format)
    }

    private static func percent(from value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return min(100, max(0, Int(number.doubleValue.rounded())))
        }
        if let string = value as? String, let number = Double(string) {
            return min(100, max(0, Int(number.rounded())))
        }
        return nil
    }

    private static func windowMinutes(from value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return Int(number.doubleValue.rounded())
        }
        if let string = value as? String, let number = Double(string) {
            return Int(number.rounded())
        }
        return nil
    }

    private static func window(
        in snapshot: RateLimitSnapshot,
        matchingMinutes targetMinutes: Int
    ) -> RateLimitWindow? {
        [snapshot.primary, snapshot.secondary]
            .compactMap { $0 }
            .first { window in
                guard let minutes = window.windowMinutes else { return false }
                return minutes == targetMinutes
            }
    }

    private static func epochDate(from value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        let raw = number.doubleValue
        return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
    }

    private static func isoDate(from value: Any?) -> Date? {
        guard let string = value as? String else { return nil }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: string) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func resetLabel(for date: Date?, format: String) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.timeZone = .current
        formatter.dateFormat = format
        return "reseta \(formatter.string(from: date))"
    }

    private static func sourceLabel(for rateLimits: RateLimitSnapshot) -> String {
        let planSuffix = rateLimits.planType.map { " \($0)" } ?? ""
        return "~/.codex/sessions rate_limits\(planSuffix)"
    }

    private static func formatTokenCount(_ count: Int?) -> String? {
        guard let count else { return nil }
        let absolute = Double(max(0, count))
        if absolute >= 1_000_000 {
            return String(format: "%.1fM", absolute / 1_000_000)
        }
        if absolute >= 1_000 {
            return "\(Int((absolute / 1_000).rounded()))K"
        }
        return "\(Int(absolute))"
    }

    private static func exactHomeRelativePath(
        _ relativePath: String,
        candidateHomes: [String],
        isDirectory: Bool = false
    ) -> String? {
        for userHome in candidateHomes {
            let candidate = userHome + relativePath
            var candidateIsDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate, isDirectory: &candidateIsDirectory) else {
                continue
            }
            if !isDirectory || candidateIsDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    private static func homeCandidates(
        userHome: String?,
        fallbackHomes: [String]
    ) -> [String] {
        if let userHome {
            return Array(NSOrderedSet(array: [userHome] + fallbackHomes)) as? [String] ?? [userHome] + fallbackHomes
        }
        return PedroOpsUserHome.candidatePaths
    }
}

struct ClaudeUsage: Codable, Equatable {
    var session5hPercent: Int? = nil
    var session5hResetsAt: Date? = nil
    var weekly7dPercent: Int? = nil
    var weekly7dResetsAt: Date? = nil
    var isStale: Bool = false
    var lastUpdated: Date = Date()
    var errorMessage: String? = nil
}

enum PedroOpsClaudeUsageReader {
    private static let organizationID = "e1d0e323-8474-4543-8ffb-27ee3733c9c6"

    static func summary(now: Date = Date(), includeSessionCounts: Bool = true) -> PedroOpsUsageWindowSummary {
        let historySessionCount = includeSessionCounts ? (recentHistorySessionCount(now: now) ?? activeSessionCountFromClaudeCLI()) : nil
        return summary(from: currentAPIUsage(now: now), historySessionCount: historySessionCount, now: now)
    }

    static func cachedSummary(now: Date = Date()) -> PedroOpsUsageWindowSummary? {
        guard var usage = cachedUsage() else { return nil }
        usage.isStale = true
        return summary(from: usage, now: now)
    }

    static func summary(from usage: ClaudeUsage, historySessionCount: Int? = nil, now: Date = Date()) -> PedroOpsUsageWindowSummary {
        let fiveHour = usage.session5hPercent.map { usage.session5hResetsAt.map { now >= $0 } == true ? 0 : $0 }
        let week = usage.weekly7dPercent.map { usage.weekly7dResetsAt.map { now >= $0 } == true ? 0 : $0 }
        return PedroOpsUsageWindowSummary(
            lastFiveHoursTokens: nil,
            lastWeekTokens: nil,
            sessionCount: historySessionCount,
            source: usage.errorMessage ?? "claude.ai usage API",
            lastFiveHoursDisplay: fiveHour.map { "\($0)%" } ?? "--",
            lastWeekDisplay: week.map { "\($0)%" } ?? "--",
            lastFiveHoursDetail: activeResetLabel(usage.session5hResetsAt, now: now, format: "HH:mm"),
            lastWeekDetail: activeResetLabel(usage.weekly7dResetsAt, now: now, format: "dd/MM HH:mm"),
            lastFiveHoursProgressPercent: fiveHour,
            lastWeekProgressPercent: week,
            isStale: usage.isStale,
            fiveHourResetsAt: usage.session5hResetsAt,
            weekResetsAt: usage.weekly7dResetsAt
        )
    }

    static func parseUsageData(_ data: Data, now: Date = Date()) -> ClaudeUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var usage = ClaudeUsage(lastUpdated: now)
        if let fiveHour = object["five_hour"] as? [String: Any] {
            usage.session5hPercent = percent(from: fiveHour["utilization"]) ?? usage.session5hPercent
            usage.session5hResetsAt = date(from: fiveHour["resets_at"]) ?? usage.session5hResetsAt
        }

        if let sevenDay = object["seven_day"] as? [String: Any] {
            usage.weekly7dPercent = percent(from: sevenDay["utilization"]) ?? usage.weekly7dPercent
            usage.weekly7dResetsAt = date(from: sevenDay["resets_at"]) ?? usage.weekly7dResetsAt
        }

        if let limits = object["limits"] as? [[String: Any]] {
            for limit in limits {
                switch limit["kind"] as? String {
                case "session":
                    usage.session5hPercent = percent(from: limit["percent"]) ?? usage.session5hPercent
                    usage.session5hResetsAt = date(from: limit["resets_at"]) ?? usage.session5hResetsAt
                case "weekly_all":
                    usage.weekly7dPercent = percent(from: limit["percent"]) ?? usage.weekly7dPercent
                    usage.weekly7dResetsAt = date(from: limit["resets_at"]) ?? usage.weekly7dResetsAt
                default:
                    continue
                }
            }
        }

        guard usage.session5hPercent != nil || usage.weekly7dPercent != nil else { return nil }
        return usage
    }

    static func cookiePath(userHome: String = PedroOpsUserHome.path) -> String {
        PedroOpsUserHome.existingHomeRelativePath(
            "/.pedroops/claude_cookie.txt",
            preferredHome: userHome
        ) ?? (userHome + "/.pedroops/claude_cookie.txt")
    }

    private static func currentAPIUsage(now: Date) -> ClaudeUsage {
        let cachedUsage = cachedUsage()
        guard let cookie = cookieString(), !cookie.isEmpty else {
            return staleUsage(from: cachedUsage, errorMessage: "cookie ausente", now: now)
        }

        var request = URLRequest(url: URL(string: "https://claude.ai/api/organizations/\(organizationID)/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        let result = fetch(request: request)
        guard result.statusCode == 200, let data = result.data else {
            return staleUsage(
                from: cachedUsage,
                errorMessage: result.errorMessage ?? "HTTP \(result.statusCode ?? 0)",
                now: now
            )
        }

        guard let usage = parseUsageData(data, now: now) else {
            return staleUsage(from: cachedUsage, errorMessage: "payload inválido", now: now)
        }

        saveCachedUsage(usage)
        return usage
    }

    private static func fetch(request: URLRequest) -> (data: Data?, statusCode: Int?, errorMessage: String?) {
        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var statusCode: Int?
        var errorMessage: String?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            responseData = data
            statusCode = (response as? HTTPURLResponse)?.statusCode
            errorMessage = error?.localizedDescription
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 9) == .timedOut {
            task.cancel()
            return (nil, nil, "timeout")
        }
        return (responseData, statusCode, errorMessage)
    }

    private static func cookieString() -> String? {
        if let content = try? String(contentsOfFile: cookiePath(), encoding: .utf8) {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return UserDefaults.standard.string(forKey: "claude_session_cookie")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cachedUsage() -> ClaudeUsage? {
        let url = URL(fileURLWithPath: cachePath())
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ClaudeUsage.self, from: data)
    }

    private static func saveCachedUsage(_ usage: ClaudeUsage) {
        let url = URL(fileURLWithPath: cachePath())
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(usage) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func cachePath(userHome: String = PedroOpsUserHome.path) -> String {
        userHome + "/.pedroops/claude_usage_cache.json"
    }

    private static func staleUsage(from cachedUsage: ClaudeUsage?, errorMessage: String, now: Date) -> ClaudeUsage {
        var usage = cachedUsage ?? ClaudeUsage(lastUpdated: now)
        usage.isStale = true
        usage.errorMessage = errorMessage
        return usage
    }

    private static func percent(from value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        return min(100, max(0, Int(number.doubleValue.rounded())))
    }

    private static func date(from value: Any?) -> Date? {
        guard let string = value as? String else { return nil }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: string) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func activeResetLabel(_ date: Date?, now: Date, format: String) -> String? {
        guard let date else { return nil }
        return now >= date ? "Janela renovada" : resetLabel(for: date, format: format)
    }

    private static func resetLabel(for date: Date?, format: String) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.timeZone = .current
        formatter.dateFormat = format
        return "reseta \(formatter.string(from: date))"
    }

    private static func activeSessionCountFromClaudeCLI() -> Int? {
        let claudeURL = URL(fileURLWithPath: "/opt/homebrew/bin/claude")
        guard FileManager.default.isExecutableFile(atPath: claudeURL.path) else {
            return nil
        }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = claudeURL
        process.arguments = ["agents", "--json", "--all"]
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return nil
        }

        return array.count
    }

    static func recentHistorySessionCount(
        in url: URL = PedroOpsUserHome.existingHomeRelativeURL(
            "/.claude/history.jsonl",
            preferredHome: PedroOpsUserHome.path
        ) ?? URL(fileURLWithPath: PedroOpsUserHome.path + "/.claude/history.jsonl"),
        now: Date = Date()
    ) -> Int? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        let weekCutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        var sessionIDs = Set<String>()
        for rawLine in content.split(whereSeparator: \.isNewline) {
            guard let data = String(rawLine).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sessionID = object["sessionId"] as? String,
                  let timestamp = timestamp(in: object),
                  timestamp >= weekCutoff
            else {
                continue
            }

            sessionIDs.insert(sessionID)
        }

        return sessionIDs.isEmpty ? nil : sessionIDs.count
    }

    private static func usage(fromJSONLinesAt url: URL, now: Date) -> (foundUsage: Bool, lastFiveHoursTokens: Int, lastWeekTokens: Int) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return (false, 0, 0)
        }

        let fiveHourCutoff = now.addingTimeInterval(-5 * 60 * 60)
        let weekCutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        var foundUsage = false
        var lastFiveHoursTokens = 0
        var lastWeekTokens = 0

        for rawLine in content.split(whereSeparator: \.isNewline) {
            guard let data = String(rawLine).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let timestamp = timestamp(in: object),
                  timestamp >= weekCutoff
            else {
                continue
            }

            let tokens = tokenCount(in: object)
            guard tokens > 0 else { continue }
            foundUsage = true
            lastWeekTokens += tokens
            if timestamp >= fiveHourCutoff {
                lastFiveHoursTokens += tokens
            }
        }

        return (foundUsage, lastFiveHoursTokens, lastWeekTokens)
    }

    private static func timestamp(in object: [String: Any]) -> Date? {
        for key in ["timestamp", "createdAt", "created_at", "time"] {
            if let string = object[key] as? String {
                if let date = ISO8601DateFormatter().date(from: string) {
                    return date
                }
            }
            if let number = object[key] as? NSNumber {
                let raw = number.doubleValue
                return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
            }
        }
        return nil
    }

    private static func tokenCount(in object: Any) -> Int {
        guard let dictionary = object as? [String: Any] else { return 0 }
        var total = 0

        if let usage = dictionary["usage"] as? [String: Any] {
            total += tokenFields(in: usage)
        }

        for value in dictionary.values {
            if let nested = value as? [String: Any] {
                total += tokenCount(in: nested)
            } else if let array = value as? [Any] {
                total += array.reduce(0) { $0 + tokenCount(in: $1) }
            }
        }

        return total
    }

    private static func tokenFields(in usage: [String: Any]) -> Int {
        [
            "input_tokens",
            "output_tokens",
            "cache_creation_input_tokens",
            "cache_read_input_tokens"
        ].reduce(0) { total, key in
            total + ((usage[key] as? NSNumber)?.intValue ?? 0)
        }
    }
}

struct PedroOpsSSHRunner: PedroOpsSSHRunning {
    func statuses(for targets: [PedroOpsSSHTarget] = PedroOpsSnapshotBuilder.defaultTargets) -> [String: PedroOpsSSHResult] {
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [String: PedroOpsSSHResult] = [:]

        for target in targets {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let result = status(for: target)
                lock.lock()
                results[target.id] = result
                lock.unlock()
                group.leave()
            }
        }

        group.wait()
        return results
    }

    func status(for target: PedroOpsSSHTarget) -> PedroOpsSSHResult {
        let command = target.id == "alienware"
            ? Self.alienwareRemoteCommand()
            : Self.remoteCommand()
        return status(for: target, remoteCommand: command)
    }

    func status(for target: PedroOpsSSHTarget, remoteCommand: String) -> PedroOpsSSHResult {
        guard !target.sshHostAlias.contains("192.0.2."), !target.sshHostAlias.hasSuffix(".invalid") else {
            return PedroOpsSSHResult(hostID: target.id, isReachable: false, output: "", errorMessage: "Configure o destino SSH local")
        }
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.arguments(for: target, remoteCommand: remoteCommand)
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = PedroOpsUserHome.path
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return PedroOpsSSHResult(
                hostID: target.id,
                isReachable: false,
                output: "",
                errorMessage: error.localizedDescription
            )
        }

        // Drain both pipes while SSH runs; waiting first deadlocks on larger guest lists.
        let readers = DispatchGroup()
        let outputLock = NSLock()
        var outputData = Data()
        var errorData = Data()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            outputLock.lock()
            outputData = data
            outputLock.unlock()
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            outputLock.lock()
            errorData = data
            outputLock.unlock()
            readers.leave()
        }
        let deadline = Date().addingTimeInterval(target.id == "proxmox" || target.id == "alienware" ? 15 : 8)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < terminationDeadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            _ = readers.wait(timeout: .now() + 1)
            return PedroOpsSSHResult(
                hostID: target.id,
                isReachable: false,
                output: "",
                errorMessage: "Timeout"
            )
        }

        process.waitUntilExit()

        _ = readers.wait(timeout: .now() + 1)
        outputLock.lock()
        let output = outputData.pedroOpsTrimmedString
        let errorOutput = errorData.pedroOpsTrimmedString
        outputLock.unlock()

        return PedroOpsSSHResult(
            hostID: target.id,
            isReachable: process.terminationStatus == 0,
            output: output,
            errorMessage: errorOutput.isEmpty ? nil : errorOutput
        )
    }

    static func arguments(
        for target: PedroOpsSSHTarget,
        userHome: String = PedroOpsUserHome.path,
        identityExists: Bool? = nil,
        remoteCommand: String = remoteCommand()
    ) -> [String] {
        let identityPath = userHome + "/.ssh/id_ed25519"
        let knownHostsPath = userHome + "/.ssh/known_hosts"
        let shouldUseIdentity = identityExists ?? FileManager.default.fileExists(atPath: identityPath)
        var arguments = [
            "-F", "/dev/null",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=4",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(knownHostsPath)"
        ]

        if shouldUseIdentity {
            arguments += [
                "-i", identityPath,
                "-o", "IdentitiesOnly=yes"
            ]
        }

        arguments += [
            target.sshHostAlias,
            remoteCommand
        ]
        return arguments
    }

    static func alienwareRemoteCommand() -> String {
        guard let data = alienwareProbeScript.data(using: .utf16LittleEndian) else {
            return remoteCommand(for: "exit 1")
        }
        let encodedScript = data.base64EncodedString()
        let host = PedroLocalConfiguration.sshHost("pedro_ssh_alienware_worker", fallback: "user@192.0.2.40")
        let nestedSSH = """
        ssh -i ~/.ssh/id_ed25519_alienware_worker -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes \(singleQuoted(host)) powershell.exe -NoProfile -NonInteractive -EncodedCommand \(encodedScript)
        """
        return remoteCommand(for: nestedSSH)
    }

    static func remoteCommand(for script: String = remoteProbeScript) -> String {
        "sh -lc \(singleQuoted(script))"
    }

    private static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static let alienwareProbeScript = #"""
    $ErrorActionPreference = 'SilentlyContinue'
    $os = Get-CimInstance Win32_OperatingSystem
    $computer = Get-CimInstance Win32_ComputerSystem
    $processors = @(Get-CimInstance Win32_Processor)
    $cpu = $processors | Select-Object -First 1
    $cpuAverage = ($processors | Measure-Object -Property LoadPercentage -Average).Average
    $cpuUsage = if ($null -ne $cpuAverage) { "{0}%" -f [int][Math]::Round($cpuAverage) } else { "--" }
    $cpuClock = if ($cpu.CurrentClockSpeed -gt 0) { "{0:N1} GHz" -f ([double]$cpu.CurrentClockSpeed / 1000) } else { "--" }
    $memoryTotal = [double]$os.TotalVisibleMemorySize * 1024
    $memoryFree = [double]$os.FreePhysicalMemory * 1024
    $memoryUsed = $memoryTotal - $memoryFree
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $diskUsed = [double]$disk.Size - [double]$disk.FreeSpace
    $battery = Get-CimInstance Win32_Battery | Select-Object -First 1
    $uptime = (Get-Date) - $os.LastBootUpTime
    $uptimeLabel = if ($uptime.Days -gt 0) { "{0}d {1}h" -f $uptime.Days, $uptime.Hours } else { "{0}h" -f $uptime.Hours }

    Write-Output "hostname=$env:COMPUTERNAME"
    Write-Output "model=$($computer.Model)"
    Write-Output "uptime=$uptimeLabel"
    if (-not $os -or -not $computer) { Write-Error 'Telemetria Windows indisponivel'; exit 1 }
    Write-Output "cpu=$cpuUsage"
    Write-Output "cpu_model=$($cpu.Name)"
    Write-Output "cpu_clock=$cpuClock"
    Write-Output ("memory={0} / {1}" -f [long]$memoryUsed, [long]$memoryTotal)
    Write-Output ("disk={0} / {1}" -f [long]$diskUsed, [long]$disk.Size)
    if ($battery) {
        Write-Output ("battery={0}%|{1}" -f $battery.EstimatedChargeRemaining, $battery.BatteryStatus)
    }

    nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits | ForEach-Object {
        $gpu = $_ -split ',' | ForEach-Object { $_.Trim() }
        if ($gpu.Count -ge 6) {
            Write-Output ("gpu={0}|{1}|{2}|{3}|{4}|{5}" -f $gpu[0], $gpu[1], $gpu[2], $gpu[3], $gpu[4], $gpu[5])
        }
    }
    """#

    private static let remoteProbeScript = """
    hostname_value=$(hostname 2>/dev/null || uname -n 2>/dev/null || printf unknown)
    uptime_value=$(uptime 2>/dev/null | sed 's/^ *//')
    load_value=$(cat /proc/loadavg 2>/dev/null | awk '{print $1" "$2" "$3}')
    if [ -z "$load_value" ]; then load_value=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}'); fi
    memory_value=$(free -b 2>/dev/null | awk '/Mem:/ {printf "%.1fGB / %.1fGB", $3/1000000000, $2/1000000000}')
    if [ -z "$memory_value" ]; then memory_value=$(top -l 1 2>/dev/null | awk -F': ' '/PhysMem/ {print $2; exit}'); fi
    disk_value=$(df -k / 2>/dev/null | awk 'NR==2 {printf "%.0f / %.0f", $3*1024, $2*1024}')
    cpu_value=
    if [ -r /proc/stat ]; then
        read _ u1 n1 s1 i1 w1 q1 sq1 st1 _ < /proc/stat
        total1=$((u1+n1+s1+i1+w1+q1+sq1+st1))
        idle1=$((i1+w1))
        sleep 1
        read _ u2 n2 s2 i2 w2 q2 sq2 st2 _ < /proc/stat
        total2=$((u2+n2+s2+i2+w2+q2+sq2+st2))
        idle2=$((i2+w2))
        diff_total=$((total2-total1))
        diff_idle=$((idle2-idle1))
        if [ "$diff_total" -gt 0 ]; then
            cpu_value=$(( (100*(diff_total-diff_idle) + diff_total/2) / diff_total ))%
        fi
    fi
    if [ -z "$cpu_value" ]; then cpu_value=$(top -bn2 2>/dev/null | awk -F'[, ]+' '/Cpu\\(s\\)/ {idle=$(NF-1); gsub(/,/, ".", idle); usage=100-idle; printf "%d%%", usage + 0.5}' | tail -1); fi
    gpu_values=
    if command -v nvidia-smi >/dev/null 2>&1; then
        gpu_values=$(nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits 2>/dev/null | awk -F, '
        {
            for (i = 1; i <= 6; i++) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
            }
            printf "gpu=%s|%s|%s|%s|%s|%s\\n", $1, $2, $3, $4, $5, $6
        }')
    fi
    pools_value=$(zpool list -H -o name,size,alloc,cap 2>/dev/null | awk '$1 != "boot-pool" {printf "%s%s %s %s %s", sep, $1, $2, $3, $4; sep=", "}')
    if [ -z "$pools_value" ]; then pools_value=$(zfs list -H -o name,used,avail -d 0 2>/dev/null | awk '{printf "%s%s %s used %s free", sep, $1, $2, $3; sep=", "}'); fi
    temp_value=$(sensors 2>/dev/null | awk '
    /Package id|Tctl|CPU/ {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^[+-]?[0-9.]+/ && $i ~ /C/) {
                value = $i
                gsub(/^\\+/, "", value)
                sub(/\\.0°C$/, "°C", value)
                temps[++count] = value
                break
            }
        }
    }
    END {
        if (count == 1) {
            print temps[1]
        } else if (count > 1) {
            printf "%s/%s", temps[1], temps[2]
        }
    }')
    if [ -z "$temp_value" ]; then temp_value=$(sysctl -a 2>/dev/null | awk -F': ' '/temperature|temp/ {print $2; exit}'); fi
    printf 'hostname=%s\\n' "$hostname_value"
    printf 'uptime=%s\\n' "$uptime_value"
    printf 'load=%s\\n' "$load_value"
    printf 'cpu=%s\\n' "$cpu_value"
    if [ -n "$gpu_values" ]; then printf '%s\\n' "$gpu_values"; fi
    printf 'memory=%s\\n' "$memory_value"
    printf 'disk=%s\\n' "$disk_value"
    printf 'pools=%s\\n' "$pools_value"
    printf 'temp=%s\\n' "$temp_value"
    """
}

private extension Data {
    var pedroOpsTrimmedString: String {
        String(data: self, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum PedroOpsAlertsProvider {
    private static let stateLock = NSLock()
    private static let dismissalRetentionInterval: TimeInterval = 14 * 24 * 60 * 60

    private struct RemoteAlertFetchResult {
        let payloads: [RemoteAlertPayload]
        let isAvailable: Bool
        let isInvalid: Bool
    }

    private struct RemoteAlertDocument: Codable {
        let alerts: [RemoteAlertPayload]
    }

    private struct RemoteAlertPayload: Codable {
        let id: String?
        let source: String
        let product: String
        let title: String
        let severity: PedroOpsAlertSeverity
        let status: String?
        let detail: String?
        let metrics: [RemoteAlertMetricPayload]?
        let stateHash: String?
    }

    private struct RemoteAlertMetricPayload: Codable {
        let label: String
        let value: String
        let detail: String?
        let progressPercent: Int?
        let secondaryValue: String?
        let secondaryProgressPercent: Int?
        let progressStyle: PedroOpsMetricProgressStyle?
    }

    private static var remoteWebhookURL: URL? {
        if let override = UserDefaults.standard.string(forKey: "pedro_ops_alerts_webhook_url")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           let url = URL(string: override) {
            return url
        }

        return nil
    }

    static func snapshot(
        now: Date = Date(),
        userHome: String = PedroOpsUserHome.path,
        sshRunner: PedroOpsSSHRunning = PedroOpsSSHRunner(),
        usageSnapshot: PedroOpsUsageSnapshot = .current(),
        macSnapshot: PedroOpsMacSnapshot = .current()
    ) -> PedroOpsAlertsSnapshot {
        let sshResults = (sshRunner as? PedroOpsSSHRunner)?.statuses(for: PedroOpsSnapshotBuilder.defaultTargets) ??
            Dictionary(uniqueKeysWithValues: PedroOpsSnapshotBuilder.defaultTargets.map { target in
                (target.id, sshRunner.status(for: target))
            })
        let fileFeed = remoteAlertPayloadsFromFile(userHome: userHome)
        let webhookFeed = remoteAlertPayloadsFromWebhook()
        let alerts = localAlerts(
            remoteAlerts: (fileFeed.payloads + webhookFeed.payloads).map { remoteAlert(from: $0, now: now) },
            sshResults: sshResults,
            usageSnapshot: usageSnapshot,
            macSnapshot: macSnapshot,
            now: now
        )
        // Read the latest dismissals after network work, in the same transaction as the write.
        stateLock.lock()
        defer { stateLock.unlock() }
        var state = loadState(userHome: userHome)
        var snapshot = reconcile(alerts: alerts, persistedState: &state, now: now)
        snapshot.feedState = feedState(fileFeed, webhookFeed)
        saveState(state, userHome: userHome)
        return snapshot
    }

    static func persistDismissal(
        alertIDs: [String],
        visibleAlerts: [PedroOpsAlert],
        userHome: String = PedroOpsUserHome.path,
        now: Date = Date()
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        var state = loadState(userHome: userHome)
        dismiss(alertIDs: alertIDs, visibleAlerts: visibleAlerts, persistedState: &state, now: now)
        saveState(state, userHome: userHome)
    }

    static func localAlerts(
        remoteAlerts: [PedroOpsAlert],
        sshResults: [String: PedroOpsSSHResult],
        usageSnapshot: PedroOpsUsageSnapshot,
        macSnapshot: PedroOpsMacSnapshot,
        now: Date
    ) -> [PedroOpsAlert] {
        dedupe(
            remoteAlerts +
            sshAlerts(results: sshResults, now: now) +
            usageAlerts(snapshot: usageSnapshot, now: now) +
            macAlerts(snapshot: macSnapshot, now: now)
        )
    }

    static func reconcile(
        alerts: [PedroOpsAlert],
        persistedState: inout PedroOpsAlertsStoreState,
        now: Date
    ) -> PedroOpsAlertsSnapshot {
        let dedupedAlerts = dedupe(alerts)
        var nextByID: [String: PedroOpsAlert] = [:]
        var visibleAlerts: [PedroOpsAlert] = []

        for alert in dedupedAlerts {
            let previous = persistedState.alertsByID[alert.id]
            let isChanged = previous?.stateHash != alert.stateHash
            let mergedAlert = PedroOpsAlert(
                id: alert.id,
                source: alert.source,
                product: alert.product,
                title: alert.title,
                severity: alert.severity,
                stateHash: alert.stateHash,
                status: alert.status,
                detail: alert.detail,
                metrics: alert.metrics,
                firstSeenAt: previous?.firstSeenAt ?? alert.firstSeenAt,
                lastSeenAt: now,
                lastChangedAt: isChanged ? now : (previous?.lastChangedAt ?? alert.lastChangedAt)
            )
            nextByID[mergedAlert.id] = mergedAlert

            if let dismissal = persistedState.dismissed[mergedAlert.id],
               dismissal.stateHash == mergedAlert.stateHash {
                continue
            }

            visibleAlerts.append(mergedAlert)
        }

        persistedState.alertsByID = nextByID
        persistedState.dismissed = persistedState.dismissed.filter { key, dismissal in
            if nextByID[key] != nil {
                return true
            }
            return now.timeIntervalSince(dismissal.dismissedAt) < dismissalRetentionInterval
        }
        persistedState.updatedAt = now

        return PedroOpsAlertsSnapshot(alerts: sort(visibleAlerts))
    }

    static func dismiss(
        alertIDs: [String],
        visibleAlerts: [PedroOpsAlert],
        persistedState: inout PedroOpsAlertsStoreState,
        now: Date = Date()
    ) {
        let alertsByID = Dictionary(uniqueKeysWithValues: visibleAlerts.map { ($0.id, $0) })
        for id in alertIDs {
            guard let alert = alertsByID[id] ?? persistedState.alertsByID[id] else { continue }
            persistedState.dismissed[id] = PedroOpsAlertDismissal(
                stateHash: alert.stateHash,
                dismissedAt: now
            )
        }
        persistedState.updatedAt = now
    }

    static func clearAll(
        visibleAlerts: [PedroOpsAlert],
        persistedState: inout PedroOpsAlertsStoreState,
        now: Date = Date()
    ) {
        dismiss(
            alertIDs: visibleAlerts.map(\.id),
            visibleAlerts: visibleAlerts,
            persistedState: &persistedState,
            now: now
        )
    }

    static func loadState(userHome: String = PedroOpsUserHome.path) -> PedroOpsAlertsStoreState {
        let url = URL(fileURLWithPath: statePath(userHome: userHome))
        guard let data = try? Data(contentsOf: url) else {
            return .empty
        }
        return (try? JSONDecoder().decode(PedroOpsAlertsStoreState.self, from: data)) ?? .empty
    }

    static func saveState(_ state: PedroOpsAlertsStoreState, userHome: String = PedroOpsUserHome.path) {
        let directoryURL = URL(fileURLWithPath: userHome + "/.pedroops", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: URL(fileURLWithPath: statePath(userHome: userHome)), options: .atomic)
    }

    static func statePath(userHome: String = PedroOpsUserHome.path) -> String {
        userHome + "/.pedroops/alerts_state.json"
    }

    static func remoteFeedState(userHome: String = PedroOpsUserHome.path) -> PedroOpsAlertFeedState {
        let fileFeed = remoteAlertPayloadsFromFile(userHome: userHome)
        let webhookFeed = remoteAlertPayloadsFromWebhook()
        return feedState(fileFeed, webhookFeed)
    }

    private static func feedState(_ fileFeed: RemoteAlertFetchResult, _ webhookFeed: RemoteAlertFetchResult) -> PedroOpsAlertFeedState {
        let payloads = fileFeed.payloads + webhookFeed.payloads

        if !payloads.isEmpty {
            return .active
        }
        if fileFeed.isInvalid || webhookFeed.isInvalid {
            return .invalid
        }
        if fileFeed.isAvailable || webhookFeed.isAvailable {
            return .empty
        }
        return .missing
    }

    private static func remoteAlerts(
        userHome: String,
        now: Date
    ) -> [PedroOpsAlert] {
        let payloads =
            remoteAlertPayloadsFromFile(userHome: userHome).payloads +
            remoteAlertPayloadsFromWebhook().payloads

        return payloads.map { remoteAlert(from: $0, now: now) }
    }

    private static func remoteAlertPayloadsFromFile(
        userHome: String
    ) -> RemoteAlertFetchResult {
        guard let url = PedroOpsUserHome.existingHomeRelativeURL(
            "/.pedroops/alerts_feed.json",
            preferredHome: userHome
        ) else {
            return RemoteAlertFetchResult(payloads: [], isAvailable: false, isInvalid: false)
        }
        guard let data = try? Data(contentsOf: url) else {
            return RemoteAlertFetchResult(payloads: [], isAvailable: true, isInvalid: true)
        }
        guard !data.isEmpty else {
            return RemoteAlertFetchResult(payloads: [], isAvailable: true, isInvalid: false)
        }
        guard let payloads = decodeRemoteAlertPayloads(from: data) else {
            return RemoteAlertFetchResult(payloads: [], isAvailable: true, isInvalid: true)
        }
        return RemoteAlertFetchResult(payloads: payloads, isAvailable: true, isInvalid: false)
    }

    private static func remoteAlertPayloadsFromWebhook() -> RemoteAlertFetchResult {
        guard let url = remoteWebhookURL else {
            return RemoteAlertFetchResult(payloads: [], isAvailable: false, isInvalid: false)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let result = fetchRemote(request: request)
        guard result.statusCode == 200, let data = result.data else {
            return RemoteAlertFetchResult(payloads: [], isAvailable: true, isInvalid: true)
        }
        guard let payloads = decodeRemoteAlertPayloads(from: data) else {
            return RemoteAlertFetchResult(payloads: [], isAvailable: true, isInvalid: true)
        }
        return RemoteAlertFetchResult(payloads: payloads, isAvailable: true, isInvalid: false)
    }

    private static func decodeRemoteAlertPayloads(from data: Data) -> [RemoteAlertPayload]? {
        let decoder = JSONDecoder()
        if let document = try? decoder.decode(RemoteAlertDocument.self, from: data) {
            return document.alerts
        }
        if let alerts = try? decoder.decode([RemoteAlertPayload].self, from: data) {
            return alerts
        }
        return nil
    }

    private static func fetchRemote(
        request: URLRequest
    ) -> (data: Data?, statusCode: Int?, errorMessage: String?) {
        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var statusCode: Int?
        var errorMessage: String?

        URLSession.shared.dataTask(with: request) { data, response, error in
            responseData = data
            statusCode = (response as? HTTPURLResponse)?.statusCode
            errorMessage = error?.localizedDescription
            semaphore.signal()
        }.resume()

        if semaphore.wait(timeout: .now() + 7) == .timedOut {
            return (nil, nil, "timeout")
        }
        return (responseData, statusCode, errorMessage)
    }

    private static func remoteAlert(
        from payload: RemoteAlertPayload,
        now: Date
    ) -> PedroOpsAlert {
        let metrics = (payload.metrics ?? []).map { metric in
            PedroOpsMetric(
                label: metric.label,
                value: metric.value,
                detail: metric.detail,
                progressPercent: metric.progressPercent,
                secondaryValue: metric.secondaryValue,
                secondaryProgressPercent: metric.secondaryProgressPercent,
                progressStyle: metric.progressStyle ?? .quota
            )
        }
        let stateHash = payload.stateHash ?? [
            payload.severity.rawValue,
            payload.status ?? "",
            payload.detail ?? "",
            metrics.map { "\($0.label):\($0.value):\($0.detail ?? "")" }.joined(separator: "|")
        ].joined(separator: "||")

        return PedroOpsAlert(
            id: payload.id ?? "feed.\(slug(payload.source)).\(slug(payload.title))",
            source: payload.source,
            product: payload.product,
            title: payload.title,
            severity: payload.severity,
            stateHash: stateHash,
            status: payload.status ?? payload.severity.rawValue,
            detail: payload.detail,
            metrics: metrics,
            firstSeenAt: now,
            lastSeenAt: now,
            lastChangedAt: now
        )
    }

    private static func sshAlerts(
        results: [String: PedroOpsSSHResult],
        now: Date
    ) -> [PedroOpsAlert] {
        PedroOpsSnapshotBuilder.defaultTargets.flatMap { target in
            guard let result = results[target.id] else { return [PedroOpsAlert]() }

            if !result.isReachable {
                let error = (result.errorMessage?.isEmpty == false ? result.errorMessage! : "SSH indisponível")
                let severity: PedroOpsAlertSeverity = error.localizedCaseInsensitiveContains("permission denied") ||
                    error.localizedCaseInsensitiveContains("could not resolve hostname") ? .warning : .critical

                return [
                    PedroOpsAlert(
                        id: "ssh.\(target.id).connectivity",
                        source: "ssh",
                        product: target.title,
                        title: "SSH indisponível",
                        severity: severity,
                        stateHash: "connectivity|\(error)",
                        status: severity.rawValue,
                        detail: error,
                        metrics: [
                            PedroOpsMetric(label: "Host", value: target.hostAlias)
                        ],
                        firstSeenAt: now,
                        lastSeenAt: now,
                        lastChangedAt: now
                    )
                ]
            }

            let parsedMetrics = PedroOpsSnapshotBuilder.metrics(fromSSHOutput: result.output)
            let metrics = Dictionary(uniqueKeysWithValues: parsedMetrics.map { ($0.label, $0) })
            var alerts: [PedroOpsAlert] = []

            if let cpuMetric = metrics["CPU"],
               let percent = cpuMetric.progressPercent,
               let severity = severity(for: percent) {
                alerts.append(
                    alert(
                        id: "ssh.\(target.id).cpu",
                        source: "ssh",
                        product: target.title,
                        title: "CPU alta",
                        severity: severity,
                        status: severity.rawValue,
                        detail: "Uso sustentado",
                        metrics: [cpuMetric],
                        stateHash: "cpu|\(percent)",
                        now: now
                    )
                )
            }

            let gpuMetrics = parsedMetrics.filter {
                $0.label == "GPU" || $0.label.hasPrefix("GPU ")
            }
            for (index, gpuMetric) in gpuMetrics.enumerated() {
                if let percent = gpuMetric.progressPercent,
                   let severity = severity(for: percent) {
                    alerts.append(
                        alert(
                            id: "ssh.\(target.id).gpu.\(index)",
                            source: "ssh",
                            product: target.title,
                            title: "\(gpuMetric.label) alta",
                            severity: severity,
                            status: severity.rawValue,
                            detail: gpuMetric.detail,
                            metrics: [gpuMetric],
                            stateHash: "gpu|\(gpuMetric.label)|\(percent)|\(gpuMetric.detail ?? "")",
                            now: now
                        )
                    )
                }
            }

            if let memoryMetric = metrics["Memória"],
               let percent = memoryMetric.progressPercent,
               let severity = severity(for: percent) {
                alerts.append(
                    alert(
                        id: "ssh.\(target.id).memory",
                        source: "ssh",
                        product: target.title,
                        title: "Memória alta",
                        severity: severity,
                        status: severity.rawValue,
                        detail: memoryMetric.detail,
                        metrics: [memoryMetric],
                        stateHash: "memory|\(percent)|\(memoryMetric.detail ?? "")",
                        now: now
                    )
                )
            }

            if let tempMetric = metrics["Temp"],
               let hottest = highestTemperature(in: tempMetric.value),
               let severity = temperatureSeverity(for: hottest) {
                alerts.append(
                    alert(
                        id: "ssh.\(target.id).temp",
                        source: "ssh",
                        product: target.title,
                        title: "Temperatura alta",
                        severity: severity,
                        status: severity.rawValue,
                        detail: "Leitura térmica",
                        metrics: [PedroOpsMetric(label: tempMetric.label, value: "\(hottest)°C")],
                        stateHash: "temp|\(hottest)",
                        now: now
                    )
                )
            }

            if let poolsMetric = metrics["Pools"] {
                alerts += poolAlerts(
                    for: target,
                    metric: poolsMetric,
                    now: now
                )
            }

            return alerts
        }
    }

    private static func usageAlerts(
        snapshot: PedroOpsUsageSnapshot,
        now: Date
    ) -> [PedroOpsAlert] {
        snapshot.apps.flatMap { app in
            var alerts: [PedroOpsAlert] = []

            if let percent = app.lastFiveHoursProgressPercent,
               let severity = severity(for: percent, warningAt: 75, criticalAt: 90) {
                alerts.append(
                    alert(
                        id: "usage.\(app.id).5h",
                        source: "usage",
                        product: app.title,
                        title: "Uso 5h alto",
                        severity: severity,
                        status: severity.rawValue,
                        detail: app.lastFiveHoursDetail,
                        metrics: [
                            PedroOpsMetric(
                                label: "5h",
                                value: app.lastFiveHoursDisplay ?? "\(percent)%",
                                detail: app.lastFiveHoursDetail,
                                progressPercent: percent
                            )
                        ],
                        stateHash: "5h|\(percent)|\(app.lastFiveHoursDetail ?? "")",
                        now: now
                    )
                )
            }

            if let percent = app.lastWeekProgressPercent,
               let severity = severity(for: percent, warningAt: 80, criticalAt: 95) {
                alerts.append(
                    alert(
                        id: "usage.\(app.id).week",
                        source: "usage",
                        product: app.title,
                        title: "Uso semanal alto",
                        severity: severity,
                        status: severity.rawValue,
                        detail: app.lastWeekDetail,
                        metrics: [
                            PedroOpsMetric(
                                label: "Semana",
                                value: app.lastWeekDisplay ?? "\(percent)%",
                                detail: app.lastWeekDetail,
                                progressPercent: percent
                            )
                        ],
                        stateHash: "week|\(percent)|\(app.lastWeekDetail ?? "")",
                        now: now
                    )
                )
            }

            return alerts
        }
    }

    private static func macAlerts(
        snapshot: PedroOpsMacSnapshot,
        now: Date
    ) -> [PedroOpsAlert] {
        var alerts: [PedroOpsAlert] = []

        if let cpuPercent = snapshot.cpuUsagePercent,
           let severity = severity(for: cpuPercent, warningAt: 85, criticalAt: 95) {
            alerts.append(
                alert(
                    id: "mac.cpu",
                    source: "mac",
                    product: snapshot.hostName,
                    title: "CPU do Mac alta",
                    severity: severity,
                    status: severity.rawValue,
                    detail: snapshot.thermalState,
                    metrics: [PedroOpsMetric(label: "CPU", value: "\(cpuPercent)%", progressPercent: cpuPercent)],
                    stateHash: "mac.cpu|\(cpuPercent)|\(snapshot.thermalState)",
                    now: now
                )
            )
        }

        if let gpuPercent = snapshot.gpuUsagePercent,
           let severity = severity(for: gpuPercent, warningAt: 85, criticalAt: 95) {
            alerts.append(
                alert(
                    id: "mac.gpu",
                    source: "mac",
                    product: snapshot.hostName,
                    title: "GPU do Mac alta",
                    severity: severity,
                    status: severity.rawValue,
                    detail: nil,
                    metrics: [PedroOpsMetric(label: "GPU", value: "\(gpuPercent)%", progressPercent: gpuPercent)],
                    stateHash: "mac.gpu|\(gpuPercent)",
                    now: now
                )
            )
        }

        if let memoryPercent = snapshot.memoryUsagePercent,
           let severity = severity(for: memoryPercent, warningAt: 85, criticalAt: 95) {
            alerts.append(
                alert(
                    id: "mac.memory",
                    source: "mac",
                    product: snapshot.hostName,
                    title: "RAM do Mac alta",
                    severity: severity,
                    status: severity.rawValue,
                    detail: snapshot.uptime,
                    metrics: [PedroOpsMetric(label: "RAM", value: "\(memoryPercent)%", progressPercent: memoryPercent)],
                    stateHash: "mac.memory|\(memoryPercent)",
                    now: now
                )
            )
        }

        if let storagePercent = snapshot.storageUsagePercent,
           let severity = severity(for: storagePercent, warningAt: 85, criticalAt: 95) {
            alerts.append(
                alert(
                    id: "mac.storage",
                    source: "mac",
                    product: snapshot.hostName,
                    title: "SSD do Mac alto",
                    severity: severity,
                    status: severity.rawValue,
                    detail: nil,
                    metrics: [PedroOpsMetric(label: "SSD", value: "\(storagePercent)%", progressPercent: storagePercent)],
                    stateHash: "mac.storage|\(storagePercent)",
                    now: now
                )
            )
        }

        if snapshot.thermalState != "Nominal" {
            alerts.append(
                alert(
                    id: "mac.thermal",
                    source: "mac",
                    product: snapshot.hostName,
                    title: "Térmico alterado",
                    severity: .warning,
                    status: "warning",
                    detail: snapshot.thermalState,
                    metrics: [PedroOpsMetric(label: "Térmico", value: snapshot.thermalState)],
                    stateHash: "mac.thermal|\(snapshot.thermalState)",
                    now: now
                )
            )
        }

        return alerts
    }

    private static func poolAlerts(
        for target: PedroOpsSSHTarget,
        metric: PedroOpsMetric,
        now: Date
    ) -> [PedroOpsAlert] {
        var alerts: [PedroOpsAlert] = []

        if let percent = metric.progressPercent,
           let severity = severity(for: percent, warningAt: 80, criticalAt: 90) {
            alerts.append(
                alert(
                    id: "ssh.\(target.id).pool.primary",
                    source: "ssh",
                    product: target.title,
                    title: "Pool alta",
                    severity: severity,
                    status: severity.rawValue,
                    detail: metric.value,
                    metrics: [PedroOpsMetric(label: "Pool", value: metric.value, progressPercent: percent)],
                    stateHash: "pool.primary|\(metric.value)|\(percent)",
                    now: now
                )
            )
        }

        if let secondaryValue = metric.secondaryValue,
           let percent = metric.secondaryProgressPercent,
           let severity = severity(for: percent, warningAt: 80, criticalAt: 90) {
            alerts.append(
                alert(
                    id: "ssh.\(target.id).pool.secondary",
                    source: "ssh",
                    product: target.title,
                    title: "Pool alta",
                    severity: severity,
                    status: severity.rawValue,
                    detail: secondaryValue,
                    metrics: [PedroOpsMetric(label: "Pool", value: secondaryValue, progressPercent: percent)],
                    stateHash: "pool.secondary|\(secondaryValue)|\(percent)",
                    now: now
                )
            )
        }

        return alerts
    }

    private static func alert(
        id: String,
        source: String,
        product: String,
        title: String,
        severity: PedroOpsAlertSeverity,
        status: String,
        detail: String?,
        metrics: [PedroOpsMetric],
        stateHash: String,
        now: Date
    ) -> PedroOpsAlert {
        PedroOpsAlert(
            id: id,
            source: source,
            product: product,
            title: title,
            severity: severity,
            stateHash: stateHash,
            status: status,
            detail: detail,
            metrics: metrics,
            firstSeenAt: now,
            lastSeenAt: now,
            lastChangedAt: now
        )
    }

    private static func dedupe(_ alerts: [PedroOpsAlert]) -> [PedroOpsAlert] {
        var unique: [String: PedroOpsAlert] = [:]
        for alert in alerts {
            if let existing = unique[alert.id] {
                if alert.severity.rank < existing.severity.rank ||
                    (alert.severity.rank == existing.severity.rank && alert.lastChangedAt > existing.lastChangedAt) {
                    unique[alert.id] = alert
                }
            } else {
                unique[alert.id] = alert
            }
        }
        return Array(unique.values)
    }

    private static func sort(_ alerts: [PedroOpsAlert]) -> [PedroOpsAlert] {
        alerts.sorted { lhs, rhs in
            if lhs.severity.rank != rhs.severity.rank {
                return lhs.severity.rank < rhs.severity.rank
            }
            if lhs.lastChangedAt != rhs.lastChangedAt {
                return lhs.lastChangedAt > rhs.lastChangedAt
            }
            if lhs.product != rhs.product {
                return lhs.product < rhs.product
            }
            return lhs.title < rhs.title
        }
    }

    private static func severity(
        for percent: Int,
        warningAt: Int = 85,
        criticalAt: Int = 95
    ) -> PedroOpsAlertSeverity? {
        if percent >= criticalAt {
            return .critical
        }
        if percent >= warningAt {
            return .warning
        }
        return nil
    }

    private static func temperatureSeverity(for celsius: Int) -> PedroOpsAlertSeverity? {
        severity(for: celsius, warningAt: 78, criticalAt: 88)
    }

    private static func highestTemperature(in value: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "([0-9]{2,3})") else {
            return nil
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let numbers = regex.matches(in: value, range: range).compactMap { match -> Int? in
            guard let numberRange = Range(match.range(at: 1), in: value) else {
                return nil
            }
            return Int(value[numberRange])
        }
        return numbers.max()
    }

    private static func slug(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
