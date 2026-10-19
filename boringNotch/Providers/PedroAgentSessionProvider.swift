import AppKit
import Foundation
import SQLite3

enum PedroAgentSessionProvider {
    private struct CodexThreadRow {
        let id: String
        let rolloutPath: String
        let title: String
        let cwd: String
        let branch: String?
        let model: String?
        let updatedAt: Date
    }

    private struct RolloutTail {
        let eventTypes: [String]
        let latestAgentMessage: String?
    }

    static func sessions(
        now: Date = Date(),
        codexDatabasePath: String = PedroOpsCodexUsageReader.databasePath()
    ) -> [PedroAgentSession] {
        let codexSessions = readCodexThreads(databasePath: codexDatabasePath).map { row in
            let rollout = readRolloutTail(path: row.rolloutPath)
            var state = codexState(fromEventTypes: rollout.eventTypes)
            if state == .completed, now.timeIntervalSince(row.updatedAt) > 15 * 60 {
                state = .idle
            }
            return PedroAgentSession(
                id: "codex.\(row.id)",
                provider: .codex,
                title: compact(row.title, fallback: "Sessao Codex"),
                project: URL(fileURLWithPath: row.cwd).lastPathComponent,
                state: state,
                model: row.model,
                branch: row.branch,
                updatedAt: row.updatedAt,
                preview: rollout.latestAgentMessage.map { compact($0, fallback: "") },
                threadID: row.id,
                terminalBundleIdentifier: "com.openai.codex",
                approval: nil
            )
        }

        return merge(
            sessions: codexSessions + openCodeSessions(now: now),
            bridgeEvents: PedroAgentBridge.activeEvents(now: now),
            now: now
        )
    }

    static func merge(
        sessions: [PedroAgentSession],
        bridgeEvents: [PedroAgentBridgeEvent],
        now: Date
    ) -> [PedroAgentSession] {
        let latestEvents = Dictionary(
            bridgeEvents.sorted { $0.createdAt < $1.createdAt }.map {
                (bridgeKey(provider: $0.provider, sessionID: $0.sessionID), $0)
            },
            uniquingKeysWith: { _, latest in latest }
        )
        var consumedKeys = Set<String>()
        var merged = sessions.map { session -> PedroAgentSession in
            let candidateKeys = [session.threadID, session.id.components(separatedBy: ".").last]
                .compactMap { $0 }
                .map { bridgeKey(provider: session.provider, sessionID: $0) }
            guard let matchingKey = candidateKeys.first(where: { latestEvents[$0] != nil }),
                  let event = latestEvents[matchingKey] else {
                return session
            }
            consumedKeys.insert(matchingKey)
            return applying(event: event, to: session, now: now)
        }

        for (key, event) in latestEvents where !consumedKeys.contains(key) {
            merged.append(session(from: event, now: now))
        }

        return merged.sorted { lhs, rhs in
            if lhs.state.needsAttention != rhs.state.needsAttention {
                return lhs.state.needsAttention
            }
            if (lhs.state == .working) != (rhs.state == .working) {
                return lhs.state == .working
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    static func codexState(fromEventTypes eventTypes: [String]) -> PedroAgentSessionState {
        guard let lastStarted = eventTypes.lastIndex(of: "task_started") else {
            return eventTypes.contains("task_complete") ? .completed : .idle
        }
        let lastCompleted = eventTypes.lastIndex(of: "task_complete")
        if let lastCompleted, lastCompleted > lastStarted {
            return .completed
        }
        return .working
    }

    static func openCodeSessions(now: Date = Date(), databasePath: String = PedroOpsUserHome.realPath + "/.local/share/opencode/opencode.db") -> [PedroAgentSession] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db); return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        let sql = """
        SELECT s.id, s.title, s.directory, s.time_updated,
          (SELECT json_extract(m.data, '$.modelID') FROM message m
           WHERE m.session_id = s.id AND json_valid(m.data) AND json_extract(m.data, '$.role') = 'assistant'
           ORDER BY m.time_created DESC LIMIT 1),
          (SELECT json_extract(m.data, '$.time.completed') FROM message m
           WHERE m.session_id = s.id AND json_valid(m.data) AND json_extract(m.data, '$.role') = 'assistant'
           ORDER BY m.time_created DESC LIMIT 1)
        FROM session s WHERE s.parent_id IS NULL AND s.time_updated >= ?
        ORDER BY s.time_updated DESC LIMIT 15
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970 * 1000))
        func text(_ index: Int32) -> String? {
            sqlite3_column_text(statement, index).map { String(cString: $0) }
        }
        var result: [PedroAgentSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(0) else { continue }
            let updated = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)) / 1000)
            let completed = sqlite3_column_type(statement, 5) != SQLITE_NULL
            let recent = now.timeIntervalSince(updated) < 120
            // Without event hooks, incomplete old replies mean unknown/idle, never a stuck active task.
            result.append(PedroAgentSession(id: "opencode." + id, provider: .opencode,
                title: compact(text(1) ?? "", fallback: "Sessão OpenCode"),
                project: text(2).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "OpenCode",
                state: recent && text(4) != nil ? (completed ? .completed : .working) : .idle, model: text(4), branch: nil,
                updatedAt: updated, preview: "Abrir OpenCode · estado observado no histórico local",
                threadID: id, terminalBundleIdentifier: "ai.opencode.desktop", approval: nil))
        }
        return result
    }

    private static func applying(
        event: PedroAgentBridgeEvent,
        to session: PedroAgentSession,
        now: Date
    ) -> PedroAgentSession {
        PedroAgentSession(
            id: session.id,
            provider: session.provider,
            title: session.title,
            project: session.project ?? event.cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
            state: state(for: event, now: now),
            model: session.model ?? event.model,
            branch: session.branch,
            updatedAt: max(session.updatedAt, event.createdAt),
            preview: event.prompt ?? session.preview,
            threadID: session.threadID ?? event.threadID,
            terminalBundleIdentifier: event.terminalBundleIdentifier ?? session.terminalBundleIdentifier,
            approval: approval(for: event, now: now)
        )
    }

    private static func session(from event: PedroAgentBridgeEvent, now: Date) -> PedroAgentSession {
        let project = event.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
        return PedroAgentSession(
            id: "\(event.provider.rawValue).\(event.sessionID)",
            provider: event.provider,
            title: compact(event.title ?? event.prompt ?? "Sessao \(event.provider.title)", fallback: event.provider.title),
            project: project,
            state: state(for: event, now: now),
            model: event.model,
            branch: nil,
            updatedAt: event.createdAt,
            preview: event.prompt.map { compact($0, fallback: "") },
            threadID: event.threadID,
            terminalBundleIdentifier: event.terminalBundleIdentifier,
            approval: approval(for: event, now: now)
        )
    }

    private static func state(
        for event: PedroAgentBridgeEvent,
        now: Date
    ) -> PedroAgentSessionState {
        switch event.kind {
        case .permissionRequest:
            if let expiresAt = event.expiresAt, expiresAt <= now {
                return .idle
            }
            return .waitingApproval
        case .question:
            return .waitingQuestion
        case .completed:
            return now.timeIntervalSince(event.createdAt) <= 15 * 60 ? .completed : .idle
        case .sessionStarted, .working, .permissionResolved:
            return .working
        case .notification:
            return .idle
        }
    }

    private static func approval(
        for event: PedroAgentBridgeEvent,
        now: Date
    ) -> PedroAgentApproval? {
        guard event.kind == .permissionRequest,
              let requestID = event.requestID,
              event.expiresAt.map({ $0 > now }) ?? true else {
            return nil
        }
        return PedroAgentApproval(
            requestID: requestID,
            prompt: event.prompt ?? event.title ?? "Permissao solicitada",
            expiresAt: event.expiresAt
        )
    }

    private static func bridgeKey(provider: PedroAgentProvider, sessionID: String) -> String {
        "\(provider.rawValue).\(sessionID)"
    }

    private static func readCodexThreads(databasePath: String) -> [CodexThreadRow] {
        guard FileManager.default.fileExists(atPath: databasePath) else { return [] }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
        let uri = URL(fileURLWithPath: databasePath).absoluteString + "?mode=ro"
        guard sqlite3_open_v2(uri, &database, flags, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return []
        }
        defer { sqlite3_close(database) }

        let query = """
        SELECT id, rollout_path, title, cwd, git_branch, model,
               COALESCE(updated_at_ms, updated_at * 1000)
        FROM threads
        WHERE archived = 0 AND preview <> '' AND thread_source <> 'subagent'
        ORDER BY COALESCE(recency_at_ms, updated_at_ms, updated_at * 1000) DESC
        LIMIT 8;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var rows: [CodexThreadRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqliteText(statement, column: 0),
                  let rolloutPath = sqliteText(statement, column: 1),
                  let title = sqliteText(statement, column: 2),
                  let cwd = sqliteText(statement, column: 3) else {
                continue
            }
            rows.append(
                CodexThreadRow(
                    id: id,
                    rolloutPath: rolloutPath,
                    title: title,
                    cwd: cwd,
                    branch: sqliteText(statement, column: 4),
                    model: sqliteText(statement, column: 5),
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 6)) / 1000)
                )
            )
        }
        return rows
    }

    private static func readRolloutTail(path: String, byteLimit: UInt64 = 512 * 1024) -> RolloutTail {
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return RolloutTail(eventTypes: [], latestAgentMessage: nil)
        }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > byteLimit ? size - byteLimit : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              let content = String(data: data, encoding: .utf8) else {
            return RolloutTail(eventTypes: [], latestAgentMessage: nil)
        }

        var lines = content.split(whereSeparator: \.isNewline)
        if offset > 0, !lines.isEmpty {
            lines.removeFirst()
        }

        var eventTypes: [String] = []
        var latestAgentMessage: String?
        for line in lines {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let type = payload["type"] as? String else {
                continue
            }
            if object["type"] as? String == "event_msg" {
                eventTypes.append(type)
                if type == "agent_message", let text = payload["text"] as? String {
                    latestAgentMessage = text
                }
            }
        }
        return RolloutTail(eventTypes: eventTypes, latestAgentMessage: latestAgentMessage)
    }

    private static func sqliteText(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column) else {
            return nil
        }
        let string = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string
    }

    private static func compact(_ value: String, fallback: String) -> String {
        let collapsed = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return fallback }
        return String(collapsed.prefix(180))
    }
}

enum PedroAgentSessionOpener {
    static func codexURL(threadID: String) -> URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard let encodedID = threadID.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "codex://threads/\(encodedID)")
    }

    @discardableResult
    static func open(_ session: PedroAgentSession) -> Bool {
        if session.provider == .codex,
           let threadID = session.threadID,
           let url = codexURL(threadID: threadID),
           NSWorkspace.shared.open(url) {
            return true
        }

        let bundleIdentifier = session.terminalBundleIdentifier ??
            (session.provider == .codex ? "com.openai.codex" : "com.apple.Terminal")
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            return running.activate(options: [.activateAllWindows])
        }
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return false
        }
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: .init())
        return true
    }
}
