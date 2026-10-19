import Foundation

enum PedroLiveActivityKind: String, Codable, Equatable {
    case stackIncident
    case stackRecovery
    case agentApproval
    case calendar
    case focus
    case dailyPulse
    case externalActivity
    case usageLimit
}

enum PedroLiveActivityPriority: Int, Codable, Comparable {
    case information = 20
    case recovery = 50
    case timely = 70
    case agentAttention = 90
    case stackCritical = 100

    static func < (lhs: PedroLiveActivityPriority, rhs: PedroLiveActivityPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum PedroLiveActivityTint: String, Codable, Equatable {
    case blue
    case green
    case orange
    case red
    case violet
}

struct PedroLiveActivity: Identifiable, Codable, Equatable {
    let id: String
    let stateKey: String
    let kind: PedroLiveActivityKind
    let title: String
    let detail: String
    let symbolName: String
    let tint: PedroLiveActivityTint
    let priority: PedroLiveActivityPriority
    let createdAt: Date
    let expiresAt: Date?
    let countdownEndAt: Date?

    init(
        id: String,
        stateKey: String? = nil,
        kind: PedroLiveActivityKind,
        title: String,
        detail: String,
        symbolName: String,
        tint: PedroLiveActivityTint = .blue,
        priority: PedroLiveActivityPriority,
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        countdownEndAt: Date? = nil
    ) {
        self.id = id
        self.stateKey = stateKey ?? kind.rawValue
        self.kind = kind
        self.title = title
        self.detail = detail
        self.symbolName = symbolName
        self.tint = tint
        self.priority = priority
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.countdownEndAt = countdownEndAt
    }

    func isExpired(at date: Date) -> Bool {
        expiresAt.map { $0 <= date } ?? false
    }
}

struct PedroLiveActivityQueue {
    private(set) var items: [PedroLiveActivity] = []

    mutating func upsert(_ activity: PedroLiveActivity, now: Date = Date()) {
        prune(now: now)

        if let index = items.firstIndex(where: { $0.id == activity.id }) {
            guard items[index].stateKey != activity.stateKey else { return }
            items[index] = activity
        } else {
            items.append(activity)
        }
    }

    mutating func remove(id: String) {
        items.removeAll { $0.id == id }
    }

    mutating func remove(where predicate: (PedroLiveActivity) -> Bool) {
        items.removeAll(where: predicate)
    }

    mutating func prune(now: Date = Date()) {
        items.removeAll { $0.isExpired(at: now) }
    }

    mutating func active(now: Date = Date()) -> PedroLiveActivity? {
        prune(now: now)
        return items.max {
            if $0.priority == $1.priority {
                return $0.createdAt < $1.createdAt
            }
            return $0.priority < $1.priority
        }
    }
}

enum PedroStackIncidentTransition: Equatable {
    case none
    case incident
    case recovery
    case clear
}

struct PedroStackIncidentTracker {
    private let requiredOfflineReadings: Int
    private var offlineReadings: [String: Int] = [:]
    private var reportedOfflineIDs = Set<String>()

    init(requiredOfflineReadings: Int = 2) {
        self.requiredOfflineReadings = max(1, requiredOfflineReadings)
    }

    mutating func transition(
        cardID: String,
        state: PedroStackState
    ) -> PedroStackIncidentTransition {
        switch state {
        case .offline:
            let count = (offlineReadings[cardID] ?? 0) + 1
            offlineReadings[cardID] = count
            guard count >= requiredOfflineReadings else { return .none }
            guard reportedOfflineIDs.insert(cardID).inserted else { return .none }
            return .incident
        case .active:
            offlineReadings.removeValue(forKey: cardID)
            if reportedOfflineIDs.remove(cardID) != nil {
                return .recovery
            }
            return .clear
        case .warning, .unknown:
            offlineReadings.removeValue(forKey: cardID)
            reportedOfflineIDs.remove(cardID)
            return .clear
        }
    }

    mutating func remove(cardID: String) {
        offlineReadings.removeValue(forKey: cardID)
        reportedOfflineIDs.remove(cardID)
    }
}
