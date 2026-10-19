import Foundation
import CoreAudio
import SQLite3

@main
struct PedroDifferentialTests {
    static func main() throws {
        testAudioChannels()
        testUsageDedupeAndUnknownPrice()
        try testOpenCodeReadOnly()
        try testClaudeLocalFreshness()
        print("PedroDifferentialTests passed: channel mapping, dedupe, unknown prices, OpenCode, Claude freshness")
    }

    static func testAudioChannels() {
        var stereo: [Float] = [0.4, 0.8, -0.4, -0.8]
        var mono: [Float] = [99, 99, 99, 99]
        stereo.withUnsafeMutableBytes { src in
            mono.withUnsafeMutableBytes { dest in
                let source = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(src.count), mData: src.baseAddress!)
                var list = AudioBufferList(mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(dest.count), mData: dest.baseAddress!))
                withUnsafeMutablePointer(to: &list) {
                    let output = UnsafeMutableAudioBufferListPointer($0)
                    let count = MixerRender.render(source: source, into: output, gain: 0.5)
                    precondition(count == 2)
                }
            }
        }
        precondition(abs(mono[0] - 0.3) < 0.00001 && abs(mono[1] + 0.3) < 0.00001)
        precondition(mono[2] == 0 && mono[3] == 0, "Never replay dirty output tail")
        var peak: [Float] = [1.8, -1.8, 0.1, -0.1]
        var limiter = BoostLimiter()
        peak.withUnsafeMutableBufferPointer {
            limiter.process($0.baseAddress!, frames: 2, channels: 2, release: BoostLimiter.release(sampleRate: 48000))
        }
        precondition(peak.allSatisfy { abs($0) <= BoostLimiter.ceiling + 0.00001 })
        precondition(abs(peak[0] + peak[1]) < 0.00001, "Limiter preserves linked stereo")
    }

    static func testUsageDedupeAndUnknownPrice() {
        let now = Date()
        let store = AgentUsageStore()
        let tokens = AgentTokens(input: 100, cacheWrite: 0, cacheRead: 200, output: 20, reasoning: 10)
        let record = AgentUsageRecord(provider: .codex, date: now, model: "unknown-test-model",
                                     project: "/test", session: "test", tokens: tokens, cost: nil, savings: 0)
        let entry = AgentLogEntry.usage(key: "same-response", record: record, billable: AgentBillable(tokens: tokens))
        for file in ["original", "original", "archived-copy"] {
            store.apply([entry], file: file, provider: .codex, tracksTurns: true, modified: now, now: now)
        }
        precondition(store.records.count == 1, "Copying or rereading a response cannot double bill")
        let snapshot = AgentUsageSummary.snapshot(records: store.records, limits: [:], live: [], plans: [:],
            providers: Set(AgentProvider.allCases), now: now)
        let total = snapshot.usage(.today).total
        precondition(total.tokens.total == 320 && total.unpriced == 1 && total.cost == 0)
        precondition(total.tokens.output == 20, "Reasoning is already included in output")
    }

    static func testOpenCodeReadOnly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
        let now = Date()
        let milliseconds = Int64(now.timeIntervalSince1970 * 1000)
        let sql = """
        CREATE TABLE session(id TEXT, title TEXT, directory TEXT, time_updated INTEGER, parent_id TEXT);
        CREATE TABLE message(id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
        INSERT INTO session VALUES('s', 'Fixture', '/test/project', \(milliseconds), NULL);
        INSERT INTO message VALUES('m', 's', \(milliseconds), '{"role":"assistant","modelID":"model-test","time":{"completed":\(milliseconds)}}');
        """
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let before = try Data(contentsOf: url)
        let sessions = PedroAgentSessionProvider.openCodeSessions(now: now, databasePath: url.path)
        precondition(sessions.count == 1 && sessions[0].provider == .opencode && sessions[0].state == .completed)
        precondition(sessions[0].model == "model-test")
        let after = try Data(contentsOf: url)
        precondition(after == before, "Monitoring must not write OpenCode's database")
    }

    static func testClaudeLocalFreshness() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = AgentClaudeAppUsage.historyURL(home: root)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let now = Date()
        let object: [String: Any] = ["version": 2, "samples": [["t": now.timeIntervalSince1970 * 1000, "u": ["fh": 24, "sd": 58]]]]
        try JSONSerialization.data(withJSONObject: object).write(to: path)
        let fresh = PedroClaudeLocalFallback.summary(now: now, home: root.path)!
        precondition(!fresh.isStale && fresh.lastWeekProgressPercent == 58)
        let old = PedroClaudeLocalFallback.summary(now: now.addingTimeInterval(3600), home: root.path)!
        precondition(old.isStale)
        precondition(fresh.fiveHourResetsAt == nil && fresh.weekResetsAt == nil, "Inferred resets must not zero quotas")
    }
}
