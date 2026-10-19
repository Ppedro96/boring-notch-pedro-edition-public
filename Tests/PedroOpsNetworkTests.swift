import Foundation

@main
struct PedroOpsNetworkTests {
    @MainActor
    static func main() async throws {
        try testExecutableDiscoveryAndBoundedTail()
        testCachedWindowsReset()
        try testUsageLimitWarnings()
        await testFreshUsagePublishesWarnings()
        try testGeminiRPCMappingAndStaleCache()
        await testIndependentRefreshAndCache()
        await testIndependentSSHAndCache()
        print("PedroOpsNetworkTests passed")
    }

    static func testUsageLimitWarnings() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let reset = now.addingTimeInterval(3600)
        precondition(InsightUsageLimitLevel.level(percent: 79) == .normal)
        precondition(InsightUsageLimitLevel.level(percent: 80) == .warning)
        precondition(InsightUsageLimitLevel.level(percent: 94) == .warning)
        precondition(InsightUsageLimitLevel.level(percent: 95) == .critical)
        precondition(InsightUsageLimitLevel.level(percent: 100) == .critical)
        precondition(InsightUsageLimitLevel.level(percent: 101) == .normal)
        precondition(InsightUsageLimitLevel.level(percent: 95, style: .relative) == .normal)
        var tracker = InsightUsageLimitTracker()
        func observe(_ percent: Int?, stale: Bool = false, date: Date? = reset,
                     style: PedroOpsMetricProgressStyle = .quota) -> InsightUsageLimitAlert? {
            tracker.observe(providerID: "codex", window: "current", percent: percent,
                            style: style, resetsAt: date, isStale: stale, now: now)
        }
        precondition(observe(95, stale: true) == nil, "Cached or failed readings never warn")
        precondition(observe(95, date: now.addingTimeInterval(-1)) == nil, "Expired windows never warn")
        precondition(observe(95, style: .relative) == nil, "Token comparisons are not account quotas")
        precondition(observe(nil) == nil)
        precondition(observe(80)?.level == .warning)
        precondition(observe(85) == nil, "Repeated polling must not warn again")
        precondition(observe(95)?.level == .critical, "Warn once more on escalation")
        precondition(observe(100) == nil)
        precondition(observe(70) == nil)
        precondition(observe(80) == nil, "A correction within the same known window must not rearm")
        var restored = try JSONDecoder().decode(InsightUsageLimitTracker.self, from: JSONEncoder().encode(tracker))
        precondition(restored.observe(providerID: "codex", window: "current", percent: 95,
                                     resetsAt: reset, isStale: false, now: now) == nil, "Restart preserves deduplication")
        precondition(observe(80, date: reset.addingTimeInterval(3600)) != nil, "A new quota window can warn")
        var unknown = InsightUsageLimitTracker()
        for percent in [80, 85, 50, 80] {
            let alert = unknown.observe(providerID: "claude", window: "week", percent: percent,
                                        resetsAt: nil, isStale: false, now: now)
            precondition((alert != nil) == (percent == 80), "Unknown windows rearm after a fresh recovery")
        }
    }

    @MainActor
    static func testFreshUsagePublishesWarnings() async {
        let suite = "InsightNotchAlertsTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date()
        var reading = PedroOpsUsageWindowSummary.empty
        reading.lastFiveHoursProgressPercent = 85
        reading.fiveHourResetsAt = now.addingTimeInterval(3600)
        reading.isStale = true
        let provider = PedroOpsNetworkProvider(cachedSummaries: ["codex": reading], now: { now }, alertDefaults: defaults) { _ in .usage(reading) }
        provider.refreshUsage()
        while provider.isLoadingUsage { await Task.yield() }
        precondition(provider.usageLimitAlerts.isEmpty)
        reading.isStale = false
        now = now.addingTimeInterval(61)
        provider.refreshUsage()
        while provider.isLoadingUsage { await Task.yield() }
        precondition(provider.usageLimitAlerts.first?.level == .warning)
        precondition(defaults.data(forKey: "insightUsageLimitEpisodes.v1") != nil)
        let previous = provider.usageLimitAlerts
        now = now.addingTimeInterval(61)
        provider.refreshUsage()
        while provider.isLoadingUsage { await Task.yield() }
        precondition(provider.usageLimitAlerts == previous)
        reading.lastFiveHoursProgressPercent = 95
        now = now.addingTimeInterval(61)
        provider.refreshUsage()
        while provider.isLoadingUsage { await Task.yield() }
        precondition(provider.usageLimitAlerts.first?.level == .critical)
    }

    static func testExecutableDiscoveryAndBoundedTail() throws {
        let paths = PedroOpsCodexAppServerClient.executableCandidates(
            environment: ["CODEX_CLI_PATH": "/custom/codex"], applicationPaths: ["/Applications/Test.app"])
        precondition(paths.first == "/custom/codex")
        precondition(paths.contains("/Applications/Test.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"))
        precondition(paths.contains("/Applications/Test.app/Contents/Resources/codex"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let content = String(repeating: "large old line\n", count: 100_000) + "{\"rate_limits\":{}}\n"
        try Data(content.utf8).write(to: url)
        let tail = PedroOpsCodexUsageReader.recentLogTail(at: url, maximumBytes: 128)!
        precondition(tail.utf8.count <= 128 && tail.hasSuffix("{\"rate_limits\":{}}\n"))
        precondition(!tail.hasPrefix("old line"))
        precondition(PedroOpsCodexUsageReader.recentLogTail(at: url, maximumBytes: 0) == nil)
    }

    static func testCachedWindowsReset() {
        let now = Date()
        var reading = PedroOpsUsageWindowSummary.empty
        reading.lastFiveHoursDisplay = "90%"
        reading.lastFiveHoursProgressPercent = 90
        reading.fiveHourResetsAt = now.addingTimeInterval(-1)
        reading.lastWeekDisplay = "80%"
        reading.lastWeekProgressPercent = 80
        reading.weekResetsAt = now.addingTimeInterval(-1)
        let reset = reading.checkingFreshness(observedAt: now.addingTimeInterval(-120), now: now)
        precondition(reset.isStale && reset.lastFiveHoursProgressPercent == 0 && reset.lastWeekProgressPercent == 0)
    }

    static func testGeminiRPCMappingAndStaleCache() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let suite = "GeminiUsageTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let value: [String: Any] = ["ok": true, "accountHash": String(repeating: "a", count: 64),
            "observedAtEpoch": now.timeIntervalSince1970,
            "current": ["usedPercent": 23, "resetsAtEpoch": now.timeIntervalSince1970 + 300],
            "weekly": ["usedPercent": 0, "resetsAtEpoch": now.timeIntervalSince1970 + 600]]
        let data = try JSONSerialization.data(withJSONObject: value)
        let live = PedroGeminiUsageReader.summary(output: data, now: now, defaults: defaults)
        precondition(!live.isStale && live.lastFiveHoursProgressPercent == 23 && live.lastWeekProgressPercent == 0)
        precondition(live.source?.contains("uso da conta") == true && !live.inferUsageAfterReset)
        let stale = PedroGeminiUsageReader.summary(output: Data("{\"ok\":false}".utf8), now: now, defaults: defaults)
        precondition(stale.isStale && stale.lastFiveHoursProgressPercent == 23 && stale.lastWeekProgressPercent == 0)
        let expired = live.checkingFreshness(observedAt: now, now: now.addingTimeInterval(301))
        precondition(expired.isStale && expired.lastFiveHoursProgressPercent == 23, "Gemini must not infer zero after reset")
        var invalid = value
        invalid.removeValue(forKey: "weekly")
        let incompleteData = try JSONSerialization.data(withJSONObject: invalid)
        precondition(PedroGeminiUsageReader.rpcObservation(from: incompleteData, now: now) == nil)
        invalid = value
        invalid["observedAtEpoch"] = now.timeIntervalSince1970 - 61
        let oldData = try JSONSerialization.data(withJSONObject: invalid)
        precondition(PedroGeminiUsageReader.rpcObservation(from: oldData, now: now) == nil)
    }

    @MainActor
    static func testIndependentRefreshAndCache() async {
        var now = Date()
        var requests: [String: CheckedContinuation<PedroOpsNetworkProvider.Reading, Never>] = [:]
        var requestCount = 0
        let provider = PedroOpsNetworkProvider(cachedSummaries: [:], now: { now }) { key in
            await withCheckedContinuation { continuation in
                requestCount += 1
                requests[key] = continuation
            }
        }
        provider.refreshUsage()
        provider.refreshUsage()
        while requests.count < 3 { await Task.yield() }
        precondition(requestCount == 3)
        var value = PedroOpsUsageWindowSummary.empty
        value.lastWeekDisplay = "42%"
        value.lastWeekProgressPercent = 42
        requests.removeValue(forKey: "usage.codex")!.resume(returning: .usage(value))
        while provider.pending.contains("usage.codex") { await Task.yield() }
        precondition(provider.summaries["codex"]?.lastWeekProgressPercent == 42)
        precondition(provider.pending.contains("usage.claude"), "Codex must be visible while Claude is still pending")
        provider.refreshUsage()
        precondition(requestCount == 3, "Reopening must reuse the result and in-flight requests")
        requests.removeValue(forKey: "usage.claude")!.resume(returning: .usage(value))
        requests.removeValue(forKey: "usage.gemini")!.resume(returning: .usage(value))
        while provider.isLoadingUsage { await Task.yield() }
        now = now.addingTimeInterval(61)
        provider.refreshUsage()
        while requests.count < 3 { await Task.yield() }
        precondition(requestCount == 6)
        var failure = PedroOpsUsageWindowSummary.empty
        failure.isStale = true
        for continuation in requests.values { continuation.resume(returning: .usage(failure)) }
        requests.removeAll()
        while provider.isLoadingUsage { await Task.yield() }
        precondition(provider.summaries["codex"]?.lastWeekProgressPercent == 42)
        precondition(provider.summaries["codex"]?.isStale == true)
    }

    @MainActor
    static func testIndependentSSHAndCache() async {
        var now = Date()
        var requests: [String: CheckedContinuation<PedroOpsNetworkProvider.Reading, Never>] = [:]
        var requestCount = 0
        let targets = PedroOpsSnapshotBuilder.defaultTargets
        let provider = PedroOpsNetworkProvider(cachedSummaries: [:], now: { now }) { key in
            await withCheckedContinuation { continuation in
                requestCount += 1
                requests[key] = continuation
            }
        }
        provider.refreshStatus(targets: targets)
        provider.refreshStatus(targets: targets)
        while requests.count < targets.count { await Task.yield() }
        precondition(requestCount == targets.count)
        let first = targets[0].id
        requests.removeValue(forKey: "ssh." + first)!.resume(returning: .ssh(
            PedroOpsSSHResult(hostID: first, isReachable: true, output: "", errorMessage: nil)))
        while provider.pending.contains("ssh." + first) { await Task.yield() }
        precondition(provider.sshResults[first]?.isReachable == true)
        precondition(!provider.pending.isEmpty, "Each SSH must publish without waiting for the others")
        for (key, continuation) in requests {
            continuation.resume(returning: .ssh(PedroOpsSSHResult(
                hostID: String(key.dropFirst(4)), isReachable: false, output: "", errorMessage: "Timeout")))
        }
        requests.removeAll()
        while !provider.pending.isEmpty { await Task.yield() }
        provider.refreshStatus(targets: targets)
        precondition(provider.pending.isEmpty, "Reopening must reuse recent SSH readings")
        now = now.addingTimeInterval(31)
        precondition(provider.statusCards(for: targets).first { $0.id == first }?.subtitle == "Última leitura")
        provider.refreshStatus(targets: targets)
        while requests.count < targets.count { await Task.yield() }
        precondition(requestCount == targets.count * 2)
        for (key, continuation) in requests {
            continuation.resume(returning: .ssh(PedroOpsSSHResult(
                hostID: String(key.dropFirst(4)), isReachable: true, output: "", errorMessage: nil)))
        }
        while !provider.pending.isEmpty { await Task.yield() }
    }
}
