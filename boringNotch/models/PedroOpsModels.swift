import Foundation
import Darwin

enum PedroOpsTabKind: Equatable {
    case alerts
    case usage
    case status
    case alienware
    case mac

    var title: String {
        switch self {
        case .alerts:
            return "Alertas"
        case .usage:
            return "Usos"
        case .status:
            return "Status"
        case .alienware:
            return "Alienware"
        case .mac:
            return "Mac"
        }
    }

    var subtitle: String {
        switch self {
        case .alerts:
            return "Alertas e sinais locais"
        case .usage:
            return "Sessões Claude e Codex"
        case .status:
            return "X99 e TrueNAS via SSH"
        case .alienware:
            return "Notebook via SSH"
        case .mac:
            return "Status local"
        }
    }

    var visibleCardLimit: Int {
        switch self {
        case .mac:
            return 4
        case .alienware:
            return 1
        case .alerts, .usage, .status:
            return 3
        }
    }
}

enum PedroOpsCardState: String, Equatable {
    case active
    case warning
    case offline
    case unknown

    var label: String {
        switch self {
        case .active:
            return "OK"
        case .warning:
            return "Atenção"
        case .offline:
            return "Offline"
        case .unknown:
            return "Aguardando"
        }
    }
}

struct PedroOpsMetric: Codable, Equatable {
    let label: String
    let value: String
    let detail: String?
    let progressPercent: Int?
    let secondaryValue: String?
    let secondaryProgressPercent: Int?
    let progressStyle: PedroOpsMetricProgressStyle

    init(
        label: String,
        value: String,
        detail: String? = nil,
        progressPercent: Int? = nil,
        secondaryValue: String? = nil,
        secondaryProgressPercent: Int? = nil,
        progressStyle: PedroOpsMetricProgressStyle = .quota
    ) {
        self.label = label
        self.value = value
        self.detail = detail
        self.progressPercent = progressPercent
        self.secondaryValue = secondaryValue
        self.secondaryProgressPercent = secondaryProgressPercent
        self.progressStyle = progressStyle
    }
}

enum PedroOpsMetricProgressStyle: String, Codable, Equatable {
    case quota
    case relative
}

struct PedroOpsCard: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let iconName: String
    let bundleIdentifier: String?
    let state: PedroOpsCardState
    let metrics: [PedroOpsMetric]
    let footnote: String?

    init(
        id: String,
        title: String,
        subtitle: String,
        iconName: String,
        state: PedroOpsCardState,
        metrics: [PedroOpsMetric],
        footnote: String?,
        bundleIdentifier: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.iconName = iconName
        self.bundleIdentifier = bundleIdentifier
        self.state = state
        self.metrics = metrics
        self.footnote = footnote
    }
}

enum PedroOpsAlertSeverity: String, Codable, Equatable, CaseIterable {
    case critical
    case warning
    case info

    var rank: Int {
        switch self {
        case .critical:
            return 0
        case .warning:
            return 1
        case .info:
            return 2
        }
    }

    var label: String {
        switch self {
        case .critical:
            return "Crítico"
        case .warning:
            return "Alerta"
        case .info:
            return "Info"
        }
    }
}

struct PedroOpsAlert: Codable, Equatable, Identifiable {
    let id: String
    let source: String
    let product: String
    let title: String
    let severity: PedroOpsAlertSeverity
    let stateHash: String
    let status: String
    let detail: String?
    let metrics: [PedroOpsMetric]
    let firstSeenAt: Date
    let lastSeenAt: Date
    let lastChangedAt: Date
}

struct PedroOpsAlertsSnapshot: Equatable {
    let alerts: [PedroOpsAlert]
    var feedState: PedroOpsAlertFeedState = .missing

    var criticalCount: Int {
        alerts.filter { $0.severity == .critical }.count
    }

    var warningCount: Int {
        alerts.filter { $0.severity == .warning }.count
    }

    var infoCount: Int {
        alerts.filter { $0.severity == .info }.count
    }
}

enum PedroOpsAlertFeedState: Equatable {
    case missing
    case empty
    case active
    case invalid

    var label: String {
        switch self {
        case .missing:
            return "Feed ausente"
        case .empty:
            return "Feed sem alertas"
        case .active:
            return "Feed ativo"
        case .invalid:
            return "Feed inválido"
        }
    }
}

struct PedroOpsAlertDismissal: Codable, Equatable {
    let stateHash: String
    let dismissedAt: Date
}

struct PedroOpsAlertsStoreState: Codable, Equatable {
    var alertsByID: [String: PedroOpsAlert]
    var dismissed: [String: PedroOpsAlertDismissal]
    var updatedAt: Date

    static let empty = PedroOpsAlertsStoreState(
        alertsByID: [:],
        dismissed: [:],
        updatedAt: .distantPast
    )
}

struct PedroOpsSSHTarget: Equatable {
    let id: String
    let title: String
    let hostAlias: String
    let iconName: String
    let connectionHostAlias: String?
    let identityFileName: String?

    init(
        id: String,
        title: String,
        hostAlias: String,
        iconName: String,
        connectionHostAlias: String? = nil,
        identityFileName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.hostAlias = hostAlias
        self.iconName = iconName
        self.connectionHostAlias = connectionHostAlias
        self.identityFileName = identityFileName
    }

    var sshHostAlias: String {
        connectionHostAlias ?? hostAlias
    }
}

struct PedroOpsSSHResult: Equatable {
    let hostID: String
    let isReachable: Bool
    let output: String
    let errorMessage: String?
}

struct PedroOpsUsageAppSnapshot: Equatable {
    let id: String
    let title: String
    let bundleIdentifier: String
    let iconName: String
    let isRunning: Bool
    let windowCount: Int?
    let isFrontmost: Bool
    let lastFiveHoursTokens: Int?
    let lastWeekTokens: Int?
    let sessionCount: Int?
    let usageSource: String?
    var lastFiveHoursDisplay: String? = nil
    var lastWeekDisplay: String? = nil
    var lastFiveHoursDetail: String? = nil
    var lastWeekDetail: String? = nil
    var lastFiveHoursProgressPercent: Int? = nil
    var lastWeekProgressPercent: Int? = nil
    var lastFiveHoursProgressStyle: PedroOpsMetricProgressStyle = .quota
    var lastWeekProgressStyle: PedroOpsMetricProgressStyle = .quota
    var isUsageStale: Bool = false
}

struct PedroOpsUsageSnapshot: Equatable {
    let apps: [PedroOpsUsageAppSnapshot]
}

struct PedroOpsMacSnapshot: Equatable {
    let hostName: String
    let cpuUsagePercent: Int?
    let gpuUsagePercent: Int?
    let memoryUsagePercent: Int?
    let storageUsagePercent: Int?
    let uptime: String
    let thermalState: String

    static func current() -> PedroOpsMacSnapshot {
        let processInfo = ProcessInfo.processInfo
        return PedroOpsMacSnapshot(
            hostName: Host.current().localizedName ?? "Mac",
            cpuUsagePercent: Self.currentCPUUsagePercent(),
            gpuUsagePercent: Self.currentGPUUsagePercent(),
            memoryUsagePercent: Self.currentMemoryUsagePercent(),
            storageUsagePercent: Self.currentStorageUsagePercent(),
            uptime: Self.formatUptime(processInfo.systemUptime),
            thermalState: processInfo.thermalState.pedroOpsLabel
        )
    }

    static func percentLabel(_ percent: Int?) -> String {
        guard let percent else { return "--%" }
        return "\(percent)%"
    }

    private static func formatUptime(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int(seconds / 60))
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private static func currentCPUUsagePercent() -> Int? {
        guard let first = Self.readCPUCounters() else { return nil }
        Thread.sleep(forTimeInterval: 0.12)
        guard let second = Self.readCPUCounters() else { return nil }

        let user = second.user.saturatingSubtract(first.user)
        let system = second.system.saturatingSubtract(first.system)
        let nice = second.nice.saturatingSubtract(first.nice)
        let idle = second.idle.saturatingSubtract(first.idle)
        let total = user + system + nice + idle
        guard total > 0 else { return nil }

        return Self.percent(used: total - idle, total: total)
    }

    private static func currentGPUUsagePercent() -> Int? {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-r", "-d", "1", "-w", "0", "-c", "AGXAccelerator"]
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

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Self.firstPercent(in: output, markers: [
            "\"Device Utilization %\"=",
            "\"Renderer Utilization %\"=",
            "\"Tiler Utilization %\"="
        ])
    }

    private static func currentMemoryUsagePercent() -> Int? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let pageSize = UInt64(vm_kernel_page_size)
        let usedPages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return Self.percent(used: usedPages * pageSize, total: ProcessInfo.processInfo.physicalMemory)
    }

    private static func currentStorageUsagePercent() -> Int? {
        guard
            let attributes = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
            let total = attributes[.systemSize] as? NSNumber,
            let free = attributes[.systemFreeSize] as? NSNumber,
            total.uint64Value > 0
        else {
            return nil
        }

        let used = total.uint64Value - free.uint64Value
        return Self.percent(used: used, total: total.uint64Value)
    }

    private static func readCPUCounters() -> CPUCounters? {
        var processorCount: natural_t = 0
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &processorInfo,
            &processorInfoCount
        )

        guard result == KERN_SUCCESS, let processorInfo else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: processorInfo)),
                vm_size_t(Int(processorInfoCount) * MemoryLayout<integer_t>.stride)
            )
        }

        let states = Int(CPU_STATE_MAX)
        var counters = CPUCounters(user: 0, system: 0, nice: 0, idle: 0)
        for index in 0..<Int(processorCount) {
            let base = index * states
            counters.user += UInt64(processorInfo[base + Int(CPU_STATE_USER)])
            counters.system += UInt64(processorInfo[base + Int(CPU_STATE_SYSTEM)])
            counters.nice += UInt64(processorInfo[base + Int(CPU_STATE_NICE)])
            counters.idle += UInt64(processorInfo[base + Int(CPU_STATE_IDLE)])
        }

        return counters
    }

    private static func firstPercent(in output: String, markers: [String]) -> Int? {
        for marker in markers {
            guard let markerRange = output.range(of: marker) else { continue }
            let remaining = output[markerRange.upperBound...].drop { $0 == " " }
            let digits = remaining.prefix { $0.isNumber }
            guard let value = Int(digits) else { continue }
            return min(100, max(0, value))
        }

        return nil
    }

    private static func percent(used: UInt64, total: UInt64) -> Int? {
        guard total > 0 else { return nil }
        return min(100, max(0, Int((Double(used) / Double(total) * 100).rounded())))
    }
}

private struct CPUCounters {
    var user: UInt64
    var system: UInt64
    var nice: UInt64
    var idle: UInt64
}

struct PedroOpsCardLayout {
    static let cardPadding: Double = 7

    static func cardWidth(cardCount: Int, availableWidth: Double, spacing: Double, visibleLimit: Int = 3) -> Double {
        guard cardCount > 0, availableWidth > 0 else { return 0 }

        let visibleCount = Double(min(max(cardCount, 1), max(1, visibleLimit)))
        let totalSpacing = spacing * (visibleCount - 1)
        return floor(max(0, availableWidth - totalSpacing) / visibleCount)
    }

    static func contentWidth(totalWidth: Double) -> Double {
        floor(max(0, totalWidth - (cardPadding * 2)))
    }

    static func cardHeight(availableHeight: Double) -> Double {
        floor(max(0, availableHeight))
    }

    static func bodyHeight(totalHeight: Double, headerHeight: Double, spacing: Double) -> Double {
        floor(max(0, totalHeight - headerHeight - spacing))
    }

    static func contentHeight(totalHeight: Double) -> Double {
        floor(max(0, totalHeight - (cardPadding * 2)))
    }
}

private extension UInt64 {
    func saturatingSubtract(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}

private extension ProcessInfo.ThermalState {
    var pedroOpsLabel: String {
        switch self {
        case .nominal:
            return "Nominal"
        case .fair:
            return "Moderado"
        case .serious:
            return "Sério"
        case .critical:
            return "Crítico"
        @unknown default:
            return "Desconhecido"
        }
    }
}


enum InsightUsageLimitLevel: Int, Codable, Comparable {
    case normal = 0, warning = 1, critical = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    static func level(percent: Int?, style: PedroOpsMetricProgressStyle = .quota) -> Self {
        guard style == .quota, let percent, (0...100).contains(percent) else { return .normal }
        return percent >= 95 ? .critical : percent >= 80 ? .warning : .normal
    }
}

struct InsightUsageLimitAlert: Equatable {
    let providerID: String
    let window: String
    let percent: Int
    let level: InsightUsageLimitLevel
    let period: String
    var id: String { providerID + "." + window }
    var providerTitle: String {
        switch providerID { case "claude": "Claude"; case "codex": "Codex"; case "gemini": "Gemini"; default: providerID }
    }
    var windowTitle: String { window == "week" ? "Semana" : providerID == "gemini" ? "Atual" : "5h" }
}

struct InsightUsageLimitTracker: Codable {
    struct Episode: Codable, Equatable {
        let period: String
        let level: InsightUsageLimitLevel
    }
    private(set) var episodes: [String: Episode] = [:]

    mutating func observe(providerID: String, window: String, percent: Int?,
                          style: PedroOpsMetricProgressStyle = .quota, resetsAt: Date?,
                          isStale: Bool, now: Date) -> InsightUsageLimitAlert? {
        guard !isStale, style == .quota, let percent, (0...100).contains(percent),
              resetsAt.map({ $0 > now }) ?? true else { return nil }
        let id = providerID + "." + window
        let period = resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "unidentified"
        let level = InsightUsageLimitLevel.level(percent: percent)
        let previous = episodes[id]
        if level == .normal {
            // Without a reset date, a recovered reading starts a new warning episode.
            if resetsAt == nil || previous?.period != period { episodes.removeValue(forKey: id) }
            return nil
        }
        guard previous?.period != period || level > (previous?.level ?? .normal) else { return nil }
        episodes[id] = Episode(period: period, level: level)
        return InsightUsageLimitAlert(providerID: providerID, window: window, percent: percent,
                                      level: level, period: period)
    }
}
