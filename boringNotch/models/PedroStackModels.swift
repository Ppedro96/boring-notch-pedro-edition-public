import Foundation

enum PedroStackSection: String, Codable, CaseIterable, Identifiable {
    case cloud
    case core
    case operation
    case backup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cloud: "Cloud"
        case .core: "Core"
        case .operation: "Operação"
        case .backup: "Backup"
        }
    }

    var icon: String {
        switch self {
        case .cloud: "cloud.fill"
        case .core: "square.stack.3d.up.fill"
        case .operation: "waveform.path.ecg"
        case .backup: "clock.arrow.circlepath"
        }
    }
}

enum PedroStackState: String, Codable, CaseIterable {
    case active
    case warning
    case offline
    case unknown
}

struct PedroStackMetric: Codable, Equatable {
    let label: String
    let value: String
    let unit: String?

    var displayValue: String {
        guard let unit, !unit.isEmpty else { return value }
        return value + unit
    }

    var displayLabel: String {
        switch label {
        case "Conectadas": "Online"
        case "Campanhas": "Camp."
        default: label
        }
    }
}

struct PedroStackCard: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let state: PedroStackState
    let icon: String
    let metrics: [PedroStackMetric]
    let updatedAt: Date?

    func checkingFreshness(now: Date = Date(), feedUnavailable: Bool = false) -> Self {
        guard feedUnavailable || updatedAt.map({ now.timeIntervalSince($0) > 300 }) == true else { return self }
        return Self(id: id, title: title, subtitle: "Última leitura · sem atualização", state: .warning,
                    icon: icon, metrics: metrics, updatedAt: updatedAt)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case subtitle
        case state
        case icon
        case metrics
        case updatedAt = "updated_at"
    }
}

struct PedroStackSourceHealth: Codable, Equatable {
    let main: Bool
    let pool: Bool

    static let unavailable = PedroStackSourceHealth(main: false, pool: false)
}

struct PedroStackSections: Codable, Equatable {
    var cloud: [PedroStackCard]
    var core: [PedroStackCard]
    var operation: [PedroStackCard]
    var backup: [PedroStackCard]

    static let empty = PedroStackSections(cloud: [], core: [], operation: [], backup: [])
}

struct PedroStackSnapshot: Codable, Equatable {
    let generatedAt: Date
    var sections: PedroStackSections
    let sourceHealth: PedroStackSourceHealth

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case sections
        case sourceHealth = "source_health"
    }

    func cards(for section: PedroStackSection) -> [PedroStackCard] {
        switch section {
        case .cloud: sections.cloud
        case .core: sections.core
        case .operation: sections.operation
        case .backup: sections.backup
        }
    }

    static let empty = PedroStackSnapshot(
        generatedAt: .distantPast,
        sections: .empty,
        sourceHealth: .unavailable
    )

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { container in
            let value = try container.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) {
                return date
            }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: try container.singleValueContainer(),
                debugDescription: "Invalid ISO-8601 date: \(value)"
            )
        }
        return decoder
    }()
}
