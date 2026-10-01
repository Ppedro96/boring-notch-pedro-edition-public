import Foundation

enum PedroAgentBridgeError: Error {
    case invalidRequestID
}

enum PedroAgentBridge {
    private static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60

    static func baseDirectory(userHome: String = PedroOpsUserHome.realPath) -> URL {
        URL(fileURLWithPath: userHome, isDirectory: true)
            .appendingPathComponent(".pedroops/agent_bridge", isDirectory: true)
    }

    static func eventsDirectory(userHome: String = PedroOpsUserHome.realPath) -> URL {
        baseDirectory(userHome: userHome).appendingPathComponent("events", isDirectory: true)
    }

    static func responsesDirectory(userHome: String = PedroOpsUserHome.realPath) -> URL {
        baseDirectory(userHome: userHome).appendingPathComponent("responses", isDirectory: true)
    }

    static func heartbeatURL(userHome: String = PedroOpsUserHome.realPath) -> URL {
        baseDirectory(userHome: userHome).appendingPathComponent("heartbeat.json")
    }

    static func writeHeartbeat(
        now: Date = Date(),
        userHome: String = PedroOpsUserHome.realPath
    ) throws {
        let url = heartbeatURL(userHome: userHome)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: ["updatedAt": Int64(now.timeIntervalSince1970 * 1000)],
            options: [.sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }

    static func events(
        now: Date = Date(),
        userHome: String = PedroOpsUserHome.realPath
    ) -> [PedroAgentBridgeEvent] {
        let directory = eventsDirectory(userHome: userHome)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> PedroAgentBridgeEvent? in
                guard let data = try? Data(contentsOf: url),
                      let event = decodeEvent(data),
                      now.timeIntervalSince(event.createdAt) <= retentionInterval else {
                    return nil
                }
                return event
            }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(250)
            .map { $0 }
    }

    static func activeEvents(
        now: Date = Date(),
        userHome: String = PedroOpsUserHome.realPath
    ) -> [PedroAgentBridgeEvent] {
        let allEvents = events(now: now, userHome: userHome)
        let resolvedRequestIDs = Set(
            allEvents
                .filter { $0.kind == .permissionResolved }
                .compactMap(\.requestID)
        )
        return allEvents.filter { event in
            if event.kind == .permissionRequest,
               let requestID = event.requestID,
               resolvedRequestIDs.contains(requestID) {
                return false
            }
            if let expiresAt = event.expiresAt, expiresAt <= now, event.kind == .permissionRequest {
                return false
            }
            return true
        }
    }

    static func decodeEvent(_ data: Data) -> PedroAgentBridgeEvent? {
        try? JSONDecoder().decode(PedroAgentBridgeEvent.self, from: data)
    }

    static func respond(
        to requestID: String,
        decision: PedroAgentDecision,
        now: Date = Date(),
        userHome: String = PedroOpsUserHome.realPath
    ) throws {
        guard isSafeIdentifier(requestID) else {
            throw PedroAgentBridgeError.invalidRequestID
        }
        let directory = responsesDirectory(userHome: userHome)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: [
                "decision": decision.rawValue,
                "respondedAt": Int64(now.timeIntervalSince1970 * 1000)
            ],
            options: [.sortedKeys]
        )
        try data.write(
            to: directory.appendingPathComponent("\(requestID).json"),
            options: .atomic
        )
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")).contains($0)
        }
    }
}
