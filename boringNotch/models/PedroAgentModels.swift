import Foundation

enum PedroAgentProvider: String, Codable, Equatable {
    case claude
    case codex

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    var iconName: String {
        switch self {
        case .claude: return "sparkles"
        case .codex: return "terminal.fill"
        }
    }
}

enum PedroAgentSessionState: String, Codable, Equatable {
    case working
    case waitingApproval
    case waitingQuestion
    case completed
    case idle
    case unavailable

    var label: String {
        switch self {
        case .working: return "Trabalhando"
        case .waitingApproval: return "Aguardando aprovacao"
        case .waitingQuestion: return "Aguardando resposta"
        case .completed: return "Concluida"
        case .idle: return "Em espera"
        case .unavailable: return "Indisponivel"
        }
    }

    var needsAttention: Bool {
        self == .waitingApproval || self == .waitingQuestion
    }
}

enum PedroAgentDecision: String, Codable, Equatable {
    case allow
    case deny
}

enum PedroAgentBridgeEventKind: String, Codable, Equatable {
    case sessionStarted
    case working
    case permissionRequest
    case permissionResolved
    case question
    case completed
    case notification
}

struct PedroAgentBridgeEvent: Codable, Equatable, Identifiable {
    let eventID: String
    let provider: PedroAgentProvider
    let kind: PedroAgentBridgeEventKind
    let sessionID: String
    let threadID: String?
    let requestID: String?
    let title: String?
    let prompt: String?
    let cwd: String?
    let model: String?
    let terminalBundleIdentifier: String?
    let createdAt: Date
    let expiresAt: Date?

    var id: String { eventID }

    private enum CodingKeys: String, CodingKey {
        case eventID
        case provider
        case kind
        case sessionID
        case threadID
        case requestID
        case title
        case prompt
        case cwd
        case model
        case terminalBundleIdentifier
        case createdAt
        case expiresAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventID = try container.decode(String.self, forKey: .eventID)
        provider = try container.decode(PedroAgentProvider.self, forKey: .provider)
        kind = try container.decode(PedroAgentBridgeEventKind.self, forKey: .kind)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        threadID = try container.decodeIfPresent(String.self, forKey: .threadID)
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        terminalBundleIdentifier = try container.decodeIfPresent(String.self, forKey: .terminalBundleIdentifier)
        let createdAtMilliseconds = try container.decode(Int64.self, forKey: .createdAt)
        createdAt = Date(timeIntervalSince1970: TimeInterval(createdAtMilliseconds) / 1000)
        if let expiresAtMilliseconds = try container.decodeIfPresent(Int64.self, forKey: .expiresAt) {
            expiresAt = Date(timeIntervalSince1970: TimeInterval(expiresAtMilliseconds) / 1000)
        } else {
            expiresAt = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(provider, forKey: .provider)
        try container.encode(kind, forKey: .kind)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(threadID, forKey: .threadID)
        try container.encodeIfPresent(requestID, forKey: .requestID)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(prompt, forKey: .prompt)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(terminalBundleIdentifier, forKey: .terminalBundleIdentifier)
        try container.encode(Int64(createdAt.timeIntervalSince1970 * 1000), forKey: .createdAt)
        try container.encodeIfPresent(
            expiresAt.map { Int64($0.timeIntervalSince1970 * 1000) },
            forKey: .expiresAt
        )
    }
}

struct PedroAgentApproval: Codable, Equatable {
    let requestID: String
    let prompt: String
    let expiresAt: Date?
}

struct PedroAgentSession: Identifiable, Equatable {
    static let visibleLimit = 3

    let id: String
    let provider: PedroAgentProvider
    let title: String
    let project: String?
    let state: PedroAgentSessionState
    let model: String?
    let branch: String?
    let updatedAt: Date
    let preview: String?
    let threadID: String?
    let terminalBundleIdentifier: String?
    let approval: PedroAgentApproval?
}
