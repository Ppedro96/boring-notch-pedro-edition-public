import Foundation

@main
struct PedroOpsNetworkTests {
    @MainActor
    static func main() async throws {
        try testExecutableDiscoveryAndBoundedTail()
        testCachedWindowsReset()
        await testIndependentRefreshAndCache()
        await testIndependentSSHAndCache()
        print("PedroOpsNetworkTests passed")
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
        while requests.count < 2 { await Task.yield() }
        precondition(requestCount == 2)
        var value = PedroOpsUsageWindowSummary.empty
        value.lastWeekDisplay = "42%"
        value.lastWeekProgressPercent = 42
        requests.removeValue(forKey: "usage.codex")!.resume(returning: .usage(value))
        while provider.pending.contains("usage.codex") { await Task.yield() }
        precondition(provider.summaries["codex"]?.lastWeekProgressPercent == 42)
        precondition(provider.pending.contains("usage.claude"), "Codex must be visible while Claude is still pending")
        provider.refreshUsage()
        precondition(requestCount == 2, "Reopening must reuse the result and in-flight requests")
        requests.removeValue(forKey: "usage.claude")!.resume(returning: .usage(value))
        while provider.isLoadingUsage { await Task.yield() }
        now = now.addingTimeInterval(61)
        provider.refreshUsage()
        while requests.count < 2 { await Task.yield() }
        precondition(requestCount == 4)
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
