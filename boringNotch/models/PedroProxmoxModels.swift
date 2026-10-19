import Foundation

enum PedroProxmoxNode: String, CaseIterable, Identifiable {
    case lab
    case pveo2

    var id: String { rawValue }
    var title: String { self == .lab ? "LAB" : "PVE02" }

    var target: PedroOpsSSHTarget {
        switch self {
        case .lab:
            PedroOpsSSHTarget(
                id: "proxmox", title: "Proxmox LAB",
                hostAlias: PedroLocalConfiguration.sshHost("pedro_ssh_proxmox", fallback: "root@proxmox.example.invalid"), iconName: "server.rack"
            )
        case .pveo2:
            PedroOpsSSHTarget(
                id: "proxmox-pveo2", title: "Proxmox PVE02",
                hostAlias: PedroLocalConfiguration.sshHost("pedro_ssh_pveo2", fallback: "root@192.0.2.50"), iconName: "server.rack",
                identityFileName: UserDefaults.standard.string(forKey: "pedro_ssh_pveo2_identity") ?? "id_ed25519_secondary"
            )
        }
    }
}

enum PedroProxmoxSection: String, CaseIterable, Identifiable {
    case host
    case containers
    case virtualMachines

    var id: String { rawValue }

    var title: String {
        switch self {
        case .host: "Host"
        case .containers: "CTs"
        case .virtualMachines: "VMs"
        }
    }

    var icon: String {
        switch self {
        case .host: "server.rack"
        case .containers: "shippingbox.fill"
        case .virtualMachines: "macwindow.on.rectangle"
        }
    }
}

enum PedroProxmoxGuestKind: String, Equatable {
    case container
    case virtualMachine
}

enum PedroProxmoxGuestStatus: String, Equatable {
    case running
    case stopped
    case unknown

    init(rawValue: String) {
        switch rawValue.lowercased() {
        case "running": self = .running
        case "stopped": self = .stopped
        default: self = .unknown
        }
    }

    var label: String {
        switch self {
        case .running: "Ativo"
        case .stopped: "Parado"
        case .unknown: "Desconhecido"
        }
    }
}

struct PedroProxmoxHost: Equatable {
    let name: String
    let version: String
    let cpuModel: String
    let cpuCores: Int
    let cpuThreads: Int
    let cpuUsagePercent: Int
    let memoryUsedBytes: Double
    let memoryTotalBytes: Double
    let memoryUsagePercent: Int
    let storageUsedBytes: Double
    let storageTotalBytes: Double
    let storageUsagePercent: Int
    let cpuTemperature: Int?
    let gpuName: String?
    let gpuMemoryGB: Int?
    let gpuTemperature: Int?
    let gpuDriver: String?
    let gpuGuest: String?
    let uptime: TimeInterval
    let loadAverage: String

    var memoryLabel: String {
        Self.capacityLabel(used: memoryUsedBytes, total: memoryTotalBytes, unit: "GB")
    }

    var storageLabel: String {
        Self.capacityLabel(used: storageUsedBytes, total: storageTotalBytes, unit: "GB")
    }

    var uptimeLabel: String {
        Self.uptimeLabel(uptime)
    }

    private static func capacityLabel(used: Double, total: Double, unit: String) -> String {
        let divisor = 1_000_000_000.0
        return String(format: "%.1f/%.1f %@", used / divisor, total / divisor, unit)
    }

    private static func uptimeLabel(_ interval: TimeInterval) -> String {
        let days = Int(interval) / 86_400
        let hours = (Int(interval) % 86_400) / 3_600
        if days > 0 {
            return "\(days)d \(hours)h"
        }
        return "\(hours)h"
    }
}

struct PedroProxmoxGuest: Identifiable, Equatable {
    let id: Int
    let name: String
    let kind: PedroProxmoxGuestKind
    let status: PedroProxmoxGuestStatus
    let cpuUsagePercent: Int
    let memoryUsagePercent: Int
    let storageUsagePercent: Int
    let uptime: TimeInterval
    let memoryUsedBytes: Double
    let memoryTotalBytes: Double
    let storageUsedBytes: Double
    let storageTotalBytes: Double

    init(
        id: Int,
        name: String,
        kind: PedroProxmoxGuestKind,
        status: PedroProxmoxGuestStatus,
        cpuUsagePercent: Int,
        memoryUsagePercent: Int,
        storageUsagePercent: Int,
        uptime: TimeInterval,
        memoryUsedBytes: Double = 0,
        memoryTotalBytes: Double = 0,
        storageUsedBytes: Double = 0,
        storageTotalBytes: Double = 0
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.status = status
        self.cpuUsagePercent = cpuUsagePercent
        self.memoryUsagePercent = memoryUsagePercent
        self.storageUsagePercent = storageUsagePercent
        self.uptime = uptime
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.storageUsedBytes = storageUsedBytes
        self.storageTotalBytes = storageTotalBytes
    }

    var memoryLabel: String {
        guard memoryTotalBytes > 0 else { return "--" }
        if kind == .virtualMachine {
            return String(format: "%.1f GB no host", memoryUsedBytes / 1_000_000_000)
        }
        return String(
            format: "%.1f/%.1f GB",
            memoryUsedBytes / 1_000_000_000,
            memoryTotalBytes / 1_000_000_000
        )
    }

    var identityLabel: String { "\(kind == .container ? "CT" : "VM") \(id)" }

    var cpuLabel: String { status == .running ? "\(cpuUsagePercent)%" : "--" }

    var memoryValue: String {
        guard status == .running, memoryTotalBytes > 0 else { return "--" }
        // QEMU reports host-resident memory, not in-guest utilization (ballooning may be disabled).
        if kind == .virtualMachine { return String(format: "%.1f GB", memoryUsedBytes / 1_000_000_000) }
        return "\(memoryUsagePercent)%"
    }

    var storageValue: String {
        if kind == .virtualMachine {
            return storageTotalBytes > 0 ? String(format: "%.0f GB", storageTotalBytes / 1_000_000_000) : "--"
        }
        return status == .running && storageTotalBytes > 0 ? "\(storageUsagePercent)%" : "--"
    }
}

struct PedroProxmoxSnapshot: Equatable {
    let host: PedroProxmoxHost?
    let guests: [PedroProxmoxGuest]
    let errorMessage: String?

    var containers: [PedroProxmoxGuest] {
        guests.filter { $0.kind == .container }.sorted { $0.id < $1.id }
    }

    var virtualMachines: [PedroProxmoxGuest] {
        guests.filter { $0.kind == .virtualMachine }.sorted { $0.id < $1.id }
    }

    static let empty = PedroProxmoxSnapshot(host: nil, guests: [], errorMessage: nil)
}

// Keep late SSH responses in their own node's cache when the user switches hosts.
struct PedroProxmoxFleetState {
    private struct Entry {
        var snapshot: PedroProxmoxSnapshot
        var lastUpdated: Date?
    }

    private(set) var selectedNode: PedroProxmoxNode
    private var entries: [PedroProxmoxNode: Entry] = [:]
    private var refreshing: Set<PedroProxmoxNode> = []

    init(selectedNode: PedroProxmoxNode = .lab) {
        self.selectedNode = selectedNode
    }

    var snapshot: PedroProxmoxSnapshot { entries[selectedNode]?.snapshot ?? .empty }
    var lastUpdated: Date? { entries[selectedNode]?.lastUpdated }
    var isLoading: Bool { refreshing.contains(selectedNode) }

    mutating func select(_ node: PedroProxmoxNode) {
        selectedNode = node
    }

    mutating func beginRefresh(for node: PedroProxmoxNode) -> Bool {
        refreshing.insert(node).inserted
    }

    mutating func finishRefresh(for node: PedroProxmoxNode, snapshot: PedroProxmoxSnapshot, at date: Date) {
        entries[node] = Entry(
            snapshot: snapshot,
            lastUpdated: snapshot.errorMessage == nil ? date : entries[node]?.lastUpdated
        )
        refreshing.remove(node)
    }
}

enum PedroProxmoxSnapshotParser {
    private struct RawCPUInfo: Decodable {
        let cores: Int?
        let cpus: Int?
        let model: String?
    }

    private struct RawUsage: Decodable {
        let used: Double?
        let total: Double?
    }

    private struct RawHost: Decodable {
        let cpu: Double?
        let cpuinfo: RawCPUInfo?
        let memory: RawUsage?
        let rootfs: RawUsage?
        let uptime: Double?
        let pveversion: String?
        let loadavg: [String]?
    }

    private struct RawGuest: Decodable {
        let cpu: Double?
        let disk: Double?
        let maxdisk: Double?
        let maxmem: Double?
        let mem: Double?
        let name: String?
        let node: String?
        let status: String?
        let type: String?
        let uptime: Double?
        let vmid: Int
    }

    static func parse(output: String, hostName: String = "lab") -> PedroProxmoxSnapshot {
        guard let hostJSON = section(in: output, after: "__HOST__", before: "__GUESTS__"),
              let guestsJSON = section(in: output, after: "__GUESTS__", before: "__THERMALS__"),
              let hostData = hostJSON.data(using: .utf8),
              let guestsData = guestsJSON.data(using: .utf8) else {
            return PedroProxmoxSnapshot(host: nil, guests: [], errorMessage: "Resposta SSH incompleta")
        }

        do {
            let decoder = JSONDecoder()
            let rawHost = try decoder.decode(RawHost.self, from: hostData)
            let rawGuests = try decoder.decode([RawGuest].self, from: guestsData)
            guard rawHost.memory?.total ?? 0 > 0, rawHost.rootfs?.total ?? 0 > 0 else {
                return PedroProxmoxSnapshot(host: nil, guests: [], errorMessage: "Telemetria do host incompleta")
            }
            let thermals = keyValues(in: section(in: output, after: "__THERMALS__", before: nil) ?? "")
            let nodeName = thermals["node_name"].flatMap { $0.isEmpty ? nil : $0 } ?? hostName
            guard nodeName == hostName else {
                return PedroProxmoxSnapshot(host: nil, guests: [], errorMessage: "Nó Proxmox inesperado: \(nodeName)")
            }
            let memoryUsed = rawHost.memory?.used ?? 0
            let memoryTotal = rawHost.memory?.total ?? 0
            let storageUsed = rawHost.rootfs?.used ?? 0
            let storageTotal = rawHost.rootfs?.total ?? 0

            let host = PedroProxmoxHost(
                name: nodeName,
                version: displayVersion(rawHost.pveversion),
                cpuModel: rawHost.cpuinfo?.model ?? "CPU",
                cpuCores: rawHost.cpuinfo?.cores ?? 0,
                cpuThreads: rawHost.cpuinfo?.cpus ?? 0,
                cpuUsagePercent: thermals["cpu_percent"].flatMap(Int.init).map { min(100, max(0, $0)) } ?? percent(rawHost.cpu ?? 0),
                memoryUsedBytes: memoryUsed,
                memoryTotalBytes: memoryTotal,
                memoryUsagePercent: percent(used: memoryUsed, total: memoryTotal),
                storageUsedBytes: storageUsed,
                storageTotalBytes: storageTotal,
                storageUsagePercent: percent(used: storageUsed, total: storageTotal),
                cpuTemperature: thermals["cpu_temp"].flatMap(Int.init),
                gpuName: thermals["gpu_name"].flatMap { $0.isEmpty ? nil : $0 },
                gpuMemoryGB: thermals["gpu_memory_gb"].flatMap(Int.init),
                gpuTemperature: thermals["gpu_temp"].flatMap(Int.init),
                gpuDriver: thermals["gpu_driver"].flatMap { $0.isEmpty ? nil : $0 },
                gpuGuest: thermals["gpu_guest"].flatMap { $0.isEmpty ? nil : $0 },
                uptime: rawHost.uptime ?? 0,
                loadAverage: rawHost.loadavg?.prefix(3).joined(separator: " ") ?? "--"
            )

            let guests = rawGuests.filter { $0.node == nil || $0.node == nodeName }.map { raw in
                let memoryUsed = raw.mem ?? 0
                let memoryTotal = raw.maxmem ?? 0
                let storageUsed = raw.disk ?? 0
                let storageTotal = raw.maxdisk ?? 0
                return PedroProxmoxGuest(
                    id: raw.vmid,
                    name: raw.name ?? "Guest \(raw.vmid)",
                    kind: raw.type == "qemu" ? .virtualMachine : .container,
                    status: PedroProxmoxGuestStatus(rawValue: raw.status ?? ""),
                    cpuUsagePercent: percent(raw.cpu ?? 0),
                    memoryUsagePercent: percent(used: memoryUsed, total: memoryTotal),
                    storageUsagePercent: percent(used: storageUsed, total: storageTotal),
                    uptime: raw.uptime ?? 0,
                    memoryUsedBytes: memoryUsed,
                    memoryTotalBytes: memoryTotal,
                    storageUsedBytes: storageUsed,
                    storageTotalBytes: storageTotal
                )
            }

            return PedroProxmoxSnapshot(host: host, guests: guests, errorMessage: nil)
        } catch {
            return PedroProxmoxSnapshot(host: nil, guests: [], errorMessage: "Resposta Proxmox inválida")
        }
    }

    private static func section(in output: String, after startMarker: String, before endMarker: String?) -> String? {
        guard let startRange = output.range(of: startMarker) else { return nil }
        let start = startRange.upperBound
        let end: String.Index
        if let endMarker, let endRange = output.range(of: endMarker, range: start..<output.endIndex) {
            end = endRange.lowerBound
        } else {
            end = output.endIndex
        }
        return String(output[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func keyValues(in output: String) -> [String: String] {
        Dictionary(output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        }, uniquingKeysWith: { _, latest in latest })
    }

    private static func displayVersion(_ rawVersion: String?) -> String {
        guard let rawVersion else { return "PVE" }
        let version = rawVersion
            .replacingOccurrences(of: "pve-manager/", with: "")
            .split(separator: "/")
            .first
            .map(String.init) ?? rawVersion
        return "PVE \(version)"
    }

    private static func percent(_ ratio: Double) -> Int {
        min(100, max(0, Int((ratio * 100).rounded())))
    }

    private static func percent(used: Double, total: Double) -> Int {
        guard total > 0 else { return 0 }
        return percent(used / total)
    }
}
