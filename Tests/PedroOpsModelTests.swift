import Foundation
import SQLite3

@main
struct PedroOpsModelTests {
    static func main() {
        testLocalSSHConfiguration()
        testUsageCardsIncludeClaudeAndCodex()
        testUsageCardsCarryAppBundleIdentifiers()
        testUsageCardsReflectSessionWindows()
        testCodexUsageCardOmitsUnavailableFiveHourWindow()
        testAlertsTabTitleAndVisibleLimit()
        testAlertsStoreKeepsDismissedAlertHiddenUntilStateChanges()
        testAlertsStoreKeepsDismissalAcrossTemporaryFeedDrop()
        testAlertsStoreSortsBySeverityThenRecency()
        testAlertCardsShowHealthyPlaceholderWhenNoAlerts()
        testLocalAlertsIncludeHighCodexQuota()
        testCodexUsageSummaryUsesRateLimitPercentages()
        testCodexUsageSummaryPrefersAppServerRateLimits()
        testCodexAppServerRequestCompletesProtocolHandshake()
        testCodexAppServerUsesRealHomeInsideSandbox()
        testCodexUsageSummaryMapsSingleWeeklyRateLimitWindow()
        testCodexUsageSummaryZeroesExpiredWindowsWithoutNewEvent()
        testCodexUsageNeverEstimatesQuotaFromTokens()
        testUnavailableAndPartialTelemetry()
        testConcurrentAlertDismissalsPersist()
        testDefaultSSHTargetsUseVaultEndpoints()
        testStatusCardsIncludeDefaultHosts()
        testMacCardsIncludePercentUsageTiles()
        testDynamicCardWidthFillsUpToThreeVisibleCards()
        testMacLayoutUsesFourEqualCards()
        testCardLayoutExpandsVerticallyToAvailableNotchHeight()
        testCardLayoutReservesCompactHeaderHeight()
        testCardContentWidthAccountsForPadding()
        testCodexUsageReaderUsesRealUserHome()
        testCodexUsageReaderFallsBackFromSandboxHome()
        testCodexUsageReaderSummarizesThreadsDatabase()
        testCodexSessionStateTracksTaskLifecycle()
        testCodexSessionOpenerBuildsExactThreadURL()
        testAgentBridgeDecodesPermissionEvent()
        testAgentBridgeWritesApprovalResponse()
        testAgentBridgePermissionOverridesCodexSessionState()
        testAgentMonitorConsumesEachEventOnlyOnce()
        testUsageCardShowsLocalUsageWhenAppDetectionMissesCodex()
        testEntitlementsUseHomeRelativeAbsolutePathsForPedroOpsData()
        testClaudeUsageParserExtractsFiveHourAndWeeklyLimits()
        testClaudeUsageSummaryUsesPercentDisplays()
        testSSHArgumentsUseExplicitUserKey()
        testAlienwareSSHTargetUsesX99Bridge()
        testAlienwareStatusCardBuildsSeparately()
        testMacTabTitle()
        testUnavailableSSHResultBecomesWarningCard()
        testUnresolvedSSHAliasBecomesConfigWarning()
        testSSHOutputParserExtractsHostMetrics()
        testSSHOutputParserExtractsBothX99GPUs()
        testSSHOutputParserExtractsTrueNASPools()
        testStatusCardsKeepTemperatureVisible()
        testStatusCardsKeepBothX99GPUsVisible()
        testStatusCardsKeepPoolsVisibleForTrueNAS()
        testSSHRemoteCommandQuotesProbeScript()
        testProxmoxProbeParserExtractsHostAndGuests()
        testProxmoxSnapshotSeparatesContainersAndVMs()
        testClaudeHistoryCountsRecentDistinctSessions()
        print("PedroOpsModelTests passed")
    }

    static func testLocalSSHConfiguration() {
        let name = "notch-clean-config-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        assert(PedroLocalConfiguration.sshHost("host", fallback: "example.invalid", defaults: defaults) == "example.invalid")
        defaults.set(" user@server.example ", forKey: "host")
        assert(PedroLocalConfiguration.sshHost("host", fallback: "example.invalid", defaults: defaults) == "user@server.example")
        for value in ["", "-oProxyCommand=anything", "server with spaces", "host\ncommand"] {
            defaults.set(value, forKey: "host")
            assert(PedroLocalConfiguration.sshHost("host", fallback: "example.invalid", defaults: defaults) == "example.invalid")
        }
        let example = PedroOpsSSHTarget(id: "x99", title: "Example", hostAlias: "user@192.0.2.10", iconName: "desktopcomputer")
        let result = PedroOpsSSHRunner().status(for: example)
        assert(!result.isReachable && result.errorMessage == "Configure o destino SSH local")
    }

    static func testUsageCardsIncludeClaudeAndCodex() {
        let cards = PedroOpsSnapshotBuilder().usageCards(snapshot: .from(summaries: [:]))

        assert(cards.map(\.id) == ["claude", "codex"], "Expected Claude and Codex usage cards")
        assert(cards[0].title == "Claude", "Expected first usage card to be Claude")
        assert(cards[1].title == "Codex", "Expected second usage card to be Codex")
        assert(cards.allSatisfy { card in
            !card.metrics.isEmpty && card.metrics.allSatisfy { ["5h", "Semana"].contains($0.label) }
        }, "Expected usage cards to show only available usage windows")
    }

    static func testUsageCardsCarryAppBundleIdentifiers() {
        let cards = PedroOpsSnapshotBuilder().usageCards(snapshot: .from(summaries: [:]))

        assert(cards[0].bundleIdentifier == "com.anthropic.claudefordesktop", "Expected Claude card to keep its app bundle for real icon lookup")
        assert(cards[1].bundleIdentifier == "com.openai.codex", "Expected Codex card to keep its app bundle for real icon lookup")
    }

    static func testUsageCardsReflectSessionWindows() {
        let snapshot = PedroOpsUsageSnapshot(apps: [
            PedroOpsUsageAppSnapshot(
                id: "claude",
                title: "Claude",
                bundleIdentifier: "com.anthropic.claudefordesktop",
                iconName: "sparkles",
                isRunning: true,
                windowCount: 2,
                isFrontmost: false,
                lastFiveHoursTokens: 123_456,
                lastWeekTokens: 654_321,
                sessionCount: 4,
                usageSource: "Codex"
            ),
            PedroOpsUsageAppSnapshot(
                id: "codex",
                title: "Codex",
                bundleIdentifier: "com.openai.codex",
                iconName: "terminal.fill",
                isRunning: false,
                windowCount: 0,
                isFrontmost: false,
                lastFiveHoursTokens: nil,
                lastWeekTokens: nil,
                sessionCount: nil,
                usageSource: nil
            )
        ])

        let cards = PedroOpsSnapshotBuilder().usageCards(snapshot: snapshot)

        assert(cards[0].state == .active, "Running Claude should be active")
        assert(cards[0].metrics.contains(PedroOpsMetric(label: "5h", value: "123K", detail: nil)))
        assert(cards[0].metrics.contains(PedroOpsMetric(label: "Semana", value: "654K", detail: nil)))
        assert(cards[0].metrics.count == 2, "Usage cards should not show session count")
        assert(cards[1].state == .offline, "Closed Codex should be offline")
        assert(cards[1].metrics.contains(PedroOpsMetric(label: "5h", value: "--", detail: nil)))
    }

    static func testCodexUsageCardOmitsUnavailableFiveHourWindow() {
        let snapshot = PedroOpsUsageSnapshot(apps: [
            PedroOpsUsageAppSnapshot(
                id: "codex",
                title: "Codex",
                bundleIdentifier: "com.openai.codex",
                iconName: "terminal.fill",
                isRunning: true,
                windowCount: 1,
                isFrontmost: false,
                lastFiveHoursTokens: 180_000_000,
                lastWeekTokens: 75_000_000,
                sessionCount: nil,
                usageSource: "Codex app-server prolite",
                lastFiveHoursDisplay: "—",
                lastWeekDisplay: "25%",
                lastFiveHoursDetail: "Sem janela",
                lastWeekDetail: "reseta 28/jul.",
                lastFiveHoursProgressPercent: nil,
                lastWeekProgressPercent: 25
            )
        ])

        let card = PedroOpsSnapshotBuilder().usageCards(snapshot: snapshot)[0]

        assert(card.metrics.map(\.label) == ["Semana"], "Codex should only show the weekly window exposed by the live API")
        assert(card.metrics[0].value == "25%", "The single Codex metric should preserve the live weekly percentage")
        assert(card.metrics[0].progressPercent == 25, "The single Codex metric should keep the weekly progress bar")
    }

    static func testUsageCardShowsLocalUsageWhenAppDetectionMissesCodex() {
        let snapshot = PedroOpsUsageSnapshot(apps: [
            PedroOpsUsageAppSnapshot(
                id: "codex",
                title: "Codex",
                bundleIdentifier: "com.openai.codex",
                iconName: "terminal.fill",
                isRunning: false,
                windowCount: 0,
                isFrontmost: false,
                lastFiveHoursTokens: 1_200,
                lastWeekTokens: 3_400,
                sessionCount: 2,
                usageSource: "~/.codex/state_5.sqlite"
            )
        ])

        let card = PedroOpsSnapshotBuilder().usageCards(snapshot: snapshot)[0]

        assert(card.state == .active, "Local usage should keep Codex visible even if NSWorkspace misses the app")
        assert(card.subtitle == "Uso da conta", "Usage should identify account limits")
        assert(card.metrics.contains(PedroOpsMetric(label: "5h", value: "1K", detail: nil)))
        assert(card.metrics.contains(PedroOpsMetric(label: "Semana", value: "3K", detail: nil)))
    }

    static func testAlertsTabTitleAndVisibleLimit() {
        assert(PedroOpsTabKind.alerts.title == "Alertas", "Expected alert tab title")
        assert(PedroOpsTabKind.alerts.subtitle == "Alertas e sinais locais", "Expected alert tab subtitle")
        assert(PedroOpsTabKind.alerts.visibleCardLimit == 3, "Expected alert tab to reuse three-card layout")
    }

    static func testAlertsStoreKeepsDismissedAlertHiddenUntilStateChanges() {
        let now = Date(timeIntervalSince1970: 1_783_080_000)
        let firstSeen = now.addingTimeInterval(-900)
        let baseAlert = PedroOpsAlert(
            id: "usage.codex.5h",
            source: "usage",
            product: "Codex",
            title: "Uso alto",
            severity: .warning,
            stateHash: "codex-81",
            status: "warning",
            detail: "Janela 5h",
            metrics: [
                PedroOpsMetric(label: "5h", value: "81%", progressPercent: 81)
            ],
            firstSeenAt: firstSeen,
            lastSeenAt: firstSeen,
            lastChangedAt: firstSeen
        )

        var state = PedroOpsAlertsStoreState.empty
        let initialSnapshot = PedroOpsAlertsProvider.reconcile(
            alerts: [baseAlert],
            persistedState: &state,
            now: now
        )
        assert(initialSnapshot.alerts.map(\.id) == ["usage.codex.5h"], "Expected first alert to be visible")

        PedroOpsAlertsProvider.dismiss(
            alertIDs: ["usage.codex.5h"],
            visibleAlerts: initialSnapshot.alerts,
            persistedState: &state,
            now: now.addingTimeInterval(5)
        )

        let hiddenSnapshot = PedroOpsAlertsProvider.reconcile(
            alerts: [baseAlert],
            persistedState: &state,
            now: now.addingTimeInterval(60)
        )
        assert(hiddenSnapshot.alerts.isEmpty, "Dismissed alert should stay hidden while the state is unchanged")

        let escalatedAlert = PedroOpsAlert(
            id: "usage.codex.5h",
            source: "usage",
            product: "Codex",
            title: "Uso alto",
            severity: .critical,
            stateHash: "codex-96",
            status: "critical",
            detail: "Janela 5h",
            metrics: [
                PedroOpsMetric(label: "5h", value: "96%", progressPercent: 96)
            ],
            firstSeenAt: firstSeen,
            lastSeenAt: firstSeen,
            lastChangedAt: firstSeen
        )

        let reopenedSnapshot = PedroOpsAlertsProvider.reconcile(
            alerts: [escalatedAlert],
            persistedState: &state,
            now: now.addingTimeInterval(120)
        )
        assert(reopenedSnapshot.alerts.map(\.id) == ["usage.codex.5h"], "Changed alert state should reopen locally")
        assert(reopenedSnapshot.alerts[0].severity == .critical, "Expected reopened alert to keep the new severity")
    }

    static func testAlertsStoreKeepsDismissalAcrossTemporaryFeedDrop() {
        let now = Date(timeIntervalSince1970: 1_783_080_000)
        let alert = PedroOpsAlert(
            id: "meta.saldo",
            source: "feed",
            product: "Meta Ads",
            title: "Saldo baixo",
            severity: .warning,
            stateHash: "saldo|714.31",
            status: "warning",
            detail: "Abaixo do alvo",
            metrics: [PedroOpsMetric(label: "Saldo", value: "R$ 714,31")],
            firstSeenAt: now,
            lastSeenAt: now,
            lastChangedAt: now
        )

        var state = PedroOpsAlertsStoreState.empty
        let initial = PedroOpsAlertsProvider.reconcile(
            alerts: [alert],
            persistedState: &state,
            now: now
        )
        PedroOpsAlertsProvider.dismiss(
            alertIDs: [alert.id],
            visibleAlerts: initial.alerts,
            persistedState: &state,
            now: now.addingTimeInterval(5)
        )

        _ = PedroOpsAlertsProvider.reconcile(
            alerts: [],
            persistedState: &state,
            now: now.addingTimeInterval(60)
        )

        let reopened = PedroOpsAlertsProvider.reconcile(
            alerts: [alert],
            persistedState: &state,
            now: now.addingTimeInterval(120)
        )

        assert(reopened.alerts.isEmpty, "Dismissed alert should stay hidden even if the feed drops it temporarily and reintroduces the same state")
    }

    static func testAlertsStoreSortsBySeverityThenRecency() {
        let start = Date(timeIntervalSince1970: 1_783_080_000)
        var state = PedroOpsAlertsStoreState.empty

        let seedAlerts = [
            PedroOpsAlert(
                id: "warning-old",
                source: "ssh",
                product: "TrueNAS",
                title: "Pool alta",
                severity: .warning,
                stateHash: "pool-82",
                status: "warning",
                detail: nil,
                metrics: [PedroOpsMetric(label: "Pool", value: "82%", progressPercent: 82)],
                firstSeenAt: start,
                lastSeenAt: start,
                lastChangedAt: start
            ),
            PedroOpsAlert(
                id: "critical-current",
                source: "ssh",
                product: "X99",
                title: "SSH offline",
                severity: .critical,
                stateHash: "offline",
                status: "critical",
                detail: nil,
                metrics: [PedroOpsMetric(label: "Host", value: "Offline")],
                firstSeenAt: start,
                lastSeenAt: start,
                lastChangedAt: start
            ),
            PedroOpsAlert(
                id: "warning-new",
                source: "usage",
                product: "Claude",
                title: "Uso alto",
                severity: .warning,
                stateHash: "claude-73",
                status: "warning",
                detail: nil,
                metrics: [PedroOpsMetric(label: "5h", value: "73%", progressPercent: 73)],
                firstSeenAt: start,
                lastSeenAt: start,
                lastChangedAt: start
            )
        ]

        _ = PedroOpsAlertsProvider.reconcile(
            alerts: seedAlerts,
            persistedState: &state,
            now: start
        )

        let secondPass = PedroOpsAlertsProvider.reconcile(
            alerts: [
                seedAlerts[0],
                seedAlerts[1],
                PedroOpsAlert(
                    id: "warning-new",
                    source: "usage",
                    product: "Claude",
                    title: "Uso alto",
                    severity: .warning,
                    stateHash: "claude-88",
                    status: "warning",
                    detail: nil,
                    metrics: [PedroOpsMetric(label: "5h", value: "88%", progressPercent: 88)],
                    firstSeenAt: start,
                    lastSeenAt: start,
                    lastChangedAt: start
                )
            ],
            persistedState: &state,
            now: start.addingTimeInterval(300)
        )

        assert(secondPass.alerts.map(\.id) == ["critical-current", "warning-new", "warning-old"], "Expected severity first, then freshest change inside each severity")
    }

    static func testAlertCardsShowHealthyPlaceholderWhenNoAlerts() {
        let snapshot = PedroOpsAlertsSnapshot(alerts: [])
        let cards = PedroOpsSnapshotBuilder().alertCards(snapshot: snapshot)

        assert(cards.count == 1, "Expected a placeholder card when there are no alerts")
        assert(cards[0].title == "Sem alertas", "Expected healthy placeholder title")
        assert(cards[0].state == .active, "Expected healthy placeholder to be green")
    }

    static func testLocalAlertsIncludeHighCodexQuota() {
        let usageSnapshot = PedroOpsUsageSnapshot(apps: [
            PedroOpsUsageAppSnapshot(
                id: "codex",
                title: "Codex",
                bundleIdentifier: "com.openai.codex",
                iconName: "terminal.fill",
                isRunning: true,
                windowCount: 1,
                isFrontmost: false,
                lastFiveHoursTokens: nil,
                lastWeekTokens: nil,
                sessionCount: 1,
                usageSource: "~/.codex/sessions",
                lastFiveHoursDisplay: "81%",
                lastWeekDisplay: "23%",
                lastFiveHoursDetail: "Reset 10:00",
                lastWeekDetail: "Reset seg",
                lastFiveHoursProgressPercent: 81,
                lastWeekProgressPercent: 23
            )
        ])
        let macSnapshot = PedroOpsMacSnapshot(
            hostName: "pedro-mac",
            cpuUsagePercent: 24,
            gpuUsagePercent: 18,
            memoryUsagePercent: 41,
            storageUsagePercent: 57,
            uptime: "1d 2h",
            thermalState: "Nominal"
        )

        let alerts = PedroOpsAlertsProvider.localAlerts(
            remoteAlerts: [],
            sshResults: [:],
            usageSnapshot: usageSnapshot,
            macSnapshot: macSnapshot,
            now: Date(timeIntervalSince1970: 1_783_080_000)
        )

        let codexAlert = alerts.first { $0.id == "usage.codex.5h" }
        assert(codexAlert?.severity == .warning, "Expected Codex 5h high usage to become an alert")
        assert(codexAlert?.metrics.first?.value == "81%", "Expected alert to keep the usage percentage")
    }

    static func testCodexUsageSummaryUsesRateLimitPercentages() {
        let now = Date(timeIntervalSince1970: 1_783_080_000)
        let sessionsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-rate-limit-test-\(UUID().uuidString)")
        let dayDirectory = sessionsDirectory.appendingPathComponent("2026/07/03")
        try! FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionsDirectory) }
        let sessionURL = dayDirectory.appendingPathComponent("rollout-test.jsonl")
        let content = """
        {"timestamp":"2026-07-03T04:04:05.649Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":18.0,"window_minutes":300,"resets_at":1783088723},"secondary":{"used_percent":4.0,"window_minutes":10080,"resets_at":1783443198},"plan_type":"plus"}}}
        """
        try! content.write(to: sessionURL, atomically: true, encoding: .utf8)

        let summary = PedroOpsCodexUsageReader.summary(
            databasePath: "/tmp/missing-codex-state-\(UUID().uuidString).sqlite",
            now: now,
            sessionsDirectory: sessionsDirectory.path
        )
        let snapshot = PedroOpsUsageSnapshot(apps: [
            PedroOpsUsageAppSnapshot(
                id: "codex",
                title: "Codex",
                bundleIdentifier: "com.openai.codex",
                iconName: "terminal.fill",
                isRunning: true,
                windowCount: 1,
                isFrontmost: false,
                lastFiveHoursTokens: summary.lastFiveHoursTokens,
                lastWeekTokens: summary.lastWeekTokens,
                sessionCount: summary.sessionCount,
                usageSource: summary.source,
                lastFiveHoursDisplay: summary.lastFiveHoursDisplay,
                lastWeekDisplay: summary.lastWeekDisplay,
                lastFiveHoursDetail: summary.lastFiveHoursDetail,
                lastWeekDetail: summary.lastWeekDetail,
                lastFiveHoursProgressPercent: summary.lastFiveHoursProgressPercent,
                lastWeekProgressPercent: summary.lastWeekProgressPercent,
                lastFiveHoursProgressStyle: summary.lastFiveHoursProgressStyle,
                lastWeekProgressStyle: summary.lastWeekProgressStyle,
                isUsageStale: summary.isStale
            )
        ])

        let card = PedroOpsSnapshotBuilder().usageCards(snapshot: snapshot)[0]

        assert(card.metrics.map(\.label) == ["5h", "Semana"], "Codex card should only show usage windows")
        assert(card.metrics[0].value == "18%", "Expected Codex 5h rate limit percentage")
        assert(card.metrics[1].value == "4%", "Expected Codex weekly rate limit percentage")
        assert(card.metrics[0].progressPercent == 18, "Expected Codex 5h progress from rate limits")
        assert(card.metrics[1].progressPercent == 4, "Expected Codex weekly progress from rate limits")
        assert(card.metrics.allSatisfy { $0.progressStyle == .quota }, "Codex rate limits should use quota color progression")
        assert(card.footnote?.contains("rate_limits") == true, "Expected Codex source to identify rate limits")
    }

    static func testCodexUsageSummaryPrefersAppServerRateLimits() {
        let now = Date(timeIntervalSince1970: 1_784_771_400)
        let response = """
        {"id":1,"result":{"codexHome":"/Users/example/.codex"}}
        {"method":"remoteControl/status/changed","params":{"status":"disabled"}}
        {"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":11,"windowDurationMins":10080,"resetsAt":1785258198},"secondary":null,"planType":"prolite"},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":11,"windowDurationMins":10080,"resetsAt":1785258198},"secondary":null,"planType":"prolite"}}}}
        """

        let liveLimits = PedroOpsCodexAppServerClient.parseRateLimits(from: response)
        assert(liveLimits?.windows[10_080]?.usedPercent == 11, "Expected app-server weekly usage")
        assert(liveLimits?.windows[10_080]?.resetsAt == Date(timeIntervalSince1970: 1_785_258_198), "Expected app-server reset date")

        let summary = PedroOpsCodexUsageReader.summary(
            databasePath: "/tmp/missing-codex-state-\(UUID().uuidString).sqlite",
            now: now,
            sessionsDirectory: "/tmp/missing-codex-sessions-\(UUID().uuidString)",
            appServerOutput: response
        )

        assert(summary.lastFiveHoursDisplay == "—", "A missing live 5h window must not fall back to a fabricated token estimate")
        assert(summary.lastFiveHoursDetail == "Sem janela", "A missing live 5h window should be explicit")
        assert(summary.lastFiveHoursProgressPercent == nil, "A missing live 5h window should not draw a progress bar")
        assert(summary.lastWeekDisplay == "11%", "Expected app-server rate limits to drive the Codex weekly card")
        assert(summary.lastWeekProgressPercent == 11, "Expected app-server weekly progress")
        assert(summary.source?.contains("app-server") == true, "Expected app-server source label")
    }

    static func testCodexAppServerRequestCompletesProtocolHandshake() {
        let payload = PedroOpsCodexAppServerClient.requestPayload
        let initialize = payload.range(of: "\"method\":\"initialize\"")
        let initialized = payload.range(of: "\"method\":\"initialized\"")
        let rateLimits = payload.range(of: "\"method\":\"account/rateLimits/read\"")

        assert(initialize != nil, "Expected Codex app-server initialize request")
        assert(initialized != nil, "Expected Codex app-server initialized notification")
        assert(rateLimits != nil, "Expected Codex app-server rate limits request")
        assert(
            initialize!.lowerBound < initialized!.lowerBound && initialized!.lowerBound < rateLimits!.lowerBound,
            "Expected the app-server handshake before reading rate limits"
        )
    }

    static func testCodexAppServerUsesRealHomeInsideSandbox() {
        let environment = PedroOpsCodexAppServerClient.processEnvironment(
            base: ["HOME": "/sandbox/container"],
            userHome: "/Users/pedro"
        )

        assert(environment["HOME"] == "/Users/pedro", "Expected subprocess HOME to leave the app sandbox container")
        assert(environment["CODEX_HOME"] == "/Users/pedro/.codex", "Expected subprocess to use the authenticated Codex home")
    }

    static func testCodexUsageSummaryMapsSingleWeeklyRateLimitWindow() {
        let now = Date(timeIntervalSince1970: 1_783_080_000)
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-weekly-window-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let database = openTemporarySQLiteDatabase(at: databaseURL)
        defer { sqlite3_close(database) }

        executeSQLite(
            """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                updated_at INTEGER NOT NULL,
                tokens_used INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO threads VALUES ('recent-a', \(Int(now.timeIntervalSince1970) - 60), 40000000);
            INSERT INTO threads VALUES ('recent-b', \(Int(now.timeIntervalSince1970) - 6 * 60 * 60), 50000000);
            """,
            in: database
        )

        let sessionsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-weekly-rate-limit-test-\(UUID().uuidString)")
        let dayDirectory = sessionsDirectory.appendingPathComponent("2026/07/23")
        try! FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionsDirectory) }
        let sessionURL = dayDirectory.appendingPathComponent("rollout-test.jsonl")
        let content = """
        {"timestamp":"2026-07-23T01:29:42.823Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":8.0,"window_minutes":10080,"resets_at":1785258198},"secondary":null,"plan_type":"prolite"}}}
        """
        try! content.write(to: sessionURL, atomically: true, encoding: .utf8)

        let summary = PedroOpsCodexUsageReader.summary(
            databasePath: databaseURL.path,
            now: now,
            sessionsDirectory: sessionsDirectory.path,
            tokenLimits: PedroOpsCodexTokenLimits(fiveHourTokens: 80_000_000, weekTokens: 300_000_000)
        )

        assert(summary.lastFiveHoursDisplay == "--", "Missing 5h window must not invent a quota")
        assert(summary.lastFiveHoursProgressPercent == nil, "Missing 5h window must have no bar")
        assert(summary.lastFiveHoursDetail == "Sem janela")
        assert(summary.isStale, "Log fallback must not look live")
        assert(summary.lastWeekDisplay == "8%", "Expected weekly Codex usage to map from the single 10080-minute rate limit window")
        assert(summary.lastWeekProgressPercent == 8, "Expected weekly Codex progress to use the single weekly rate limit window")
        assert(summary.source?.contains("rate_limits") == true, "Expected Codex source to still identify rate limits")
    }

    static func testCodexUsageSummaryZeroesExpiredWindowsWithoutNewEvent() {
        let now = Date(timeIntervalSince1970: 1_783_080_000)
        let sessionsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-rate-limit-reset-test-\(UUID().uuidString)")
        let dayDirectory = sessionsDirectory.appendingPathComponent("2026/07/03")
        try! FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionsDirectory) }
        let sessionURL = dayDirectory.appendingPathComponent("rollout-test.jsonl")
        let content = """
        {"timestamp":"2026-07-03T00:04:05.649Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":81.0,"window_minutes":300,"resets_at":1783070000},"secondary":{"used_percent":23.0,"window_minutes":10080,"resets_at":1783070000},"plan_type":"plus"}}}
        """
        try! content.write(to: sessionURL, atomically: true, encoding: .utf8)

        let summary = PedroOpsCodexUsageReader.summary(
            databasePath: "/tmp/missing-codex-state-\(UUID().uuidString).sqlite",
            now: now,
            sessionsDirectory: sessionsDirectory.path
        )

        assert(summary.lastFiveHoursDisplay == "0%", "Expected expired 5h Codex window to zero until a new event arrives")
        assert(summary.lastWeekDisplay == "0%", "Expected expired weekly Codex window to zero until a new event arrives")
        assert(summary.lastFiveHoursProgressPercent == 0, "Expected expired 5h progress to zero")
        assert(summary.lastWeekProgressPercent == 0, "Expected expired weekly progress to zero")
        assert(summary.lastFiveHoursDetail == "Janela renovada", "Expired 5h window should remain visible at zero")
        assert(summary.lastWeekDetail == "Janela renovada", "Expired weekly window should report renewal")
    }

    static func testCodexUsageNeverEstimatesQuotaFromTokens() {
        let now = Date(timeIntervalSince1970: 1_783_080_000)
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-usage-display-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let database = openTemporarySQLiteDatabase(at: databaseURL)
        defer { sqlite3_close(database) }

        executeSQLite(
            """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                updated_at INTEGER NOT NULL,
                tokens_used INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO threads VALUES ('recent-a', \(Int(now.timeIntervalSince1970) - 60), 40000000);
            INSERT INTO threads VALUES ('recent-b', \(Int(now.timeIntervalSince1970) - 6 * 60 * 60), 50000000);
            """,
            in: database
        )

        let summary = PedroOpsCodexUsageReader.summary(
            databasePath: databaseURL.path,
            now: now,
            sessionsDirectory: "/tmp/missing-codex-sessions-\(UUID().uuidString)",
            tokenLimits: PedroOpsCodexTokenLimits(fiveHourTokens: 80_000_000, weekTokens: 300_000_000)
        )

        assert(summary.lastFiveHoursDisplay == "--")
        assert(summary.lastWeekDisplay == "--")
        assert(summary.lastFiveHoursProgressPercent == nil && summary.lastWeekProgressPercent == nil)
        assert(summary.isStale)
        assert(summary.lastWeekTokens == 90_000_000, "Session totals may remain available, but are not quota")
    }

    static func testUnavailableAndPartialTelemetry() {
        let missingSSH = PedroOpsSnapshotBuilder().statusCards(results: [
            "x99": PedroOpsSSHResult(hostID: "x99", isReachable: true, output: "", errorMessage: nil)
        ])[0]
        assert(missingSSH.state == .warning, "Empty SSH output must not be healthy")
        let gpu = PedroOpsSnapshotBuilder.metrics(fromSSHOutput: "gpu=0|NVIDIA GeForce RTX 4080|[N/A]|1024|12288|[N/A]")[0]
        assert(gpu.label == "GPU 0 · RTX 4080" && gpu.value == "--")
        assert(gpu.secondaryValue == "1/12 GB" && gpu.detail == nil)
        assert(PedroOpsClaudeUsageReader.parseUsageData(Data("{}".utf8)) == nil)
        let unavailable = PedroOpsClaudeUsageReader.summary(from: ClaudeUsage(isStale: true))
        assert(unavailable.lastWeekDisplay == "--" && unavailable.lastWeekProgressPercent == nil)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let expired = ClaudeUsage(session5hPercent: 92, session5hResetsAt: now.addingTimeInterval(-1), weekly7dPercent: 43, weekly7dResetsAt: now.addingTimeInterval(100), isStale: true)
        let reset = PedroOpsClaudeUsageReader.summary(from: expired, now: now)
        assert(reset.lastFiveHoursProgressPercent == 0 && reset.lastWeekProgressPercent == 43)

        let output = """
        __HOST__
        {"cpu":0,"memory":{"used":19000000000,"total":33000000000},"rootfs":{"used":10000000000,"total":68000000000}}
        __GUESTS__
        [{"vmid":200,"name":"batocera","type":"qemu","status":"running","cpu":0.1,"mem":13000000000,"maxmem":12900000000,"disk":0,"maxdisk":34000000000}]
        __THERMALS__
        cpu_percent=7
        gpu_driver=vfio-pci
        gpu_name=GTX 1050 Ti
        gpu_guest=VM 200 · batocera
        """
        let snapshot = PedroProxmoxSnapshotParser.parse(output: output)
        assert(snapshot.host?.cpuUsagePercent == 7, "Use sampled CPU instead of the pvesh process's first zero sample")
        assert(snapshot.host?.gpuDriver == "vfio-pci" && snapshot.host?.gpuTemperature == nil)
        let vm = snapshot.virtualMachines[0]
        assert(vm.identityLabel == "VM 200")
        assert(vm.memoryValue == "13.0 GB", "QEMU resident memory is not guest utilization")
        assert(vm.storageValue == "34 GB", "QEMU virtual disk capacity is not used space")
        let invalid = PedroProxmoxSnapshotParser.parse(output: "__HOST__\n{}\n__GUESTS__\n[]\n__THERMALS__\n")
        assert(invalid.host == nil && invalid.errorMessage != nil)
    }

    static func testConcurrentAlertDismissalsPersist() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("alerts-transaction-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        let alerts = (0..<20).map { index in
            PedroOpsAlert(id: "test-\(index)", source: "test", product: "test", title: "test", severity: .info,
                          stateHash: "fixed", status: "active", detail: nil, metrics: [],
                          firstSeenAt: now, lastSeenAt: now, lastChangedAt: now)
        }
        DispatchQueue.concurrentPerform(iterations: alerts.count) { index in
            PedroOpsAlertsProvider.persistDismissal(alertIDs: [alerts[index].id], visibleAlerts: alerts, userHome: home.path, now: now)
        }
        var state = PedroOpsAlertsProvider.loadState(userHome: home.path)
        assert(state.dismissed.count == alerts.count, "Parallel dismissals must not overwrite one another")
        let snapshot = PedroOpsAlertsProvider.reconcile(alerts: alerts, persistedState: &state, now: now)
        assert(snapshot.alerts.isEmpty, "Reopening the feed must keep dismissed alerts hidden")
    }

    static func testDefaultSSHTargetsUseVaultEndpoints() {
        let targets = PedroOpsSnapshotBuilder.defaultTargets

        assert(targets[0].hostAlias == "user@192.0.2.10", "Expected reserved example Linux endpoint")
        assert(targets[1].hostAlias == "user@192.0.2.20", "Expected reserved example NAS endpoint")
    }

    static func testStatusCardsIncludeDefaultHosts() {
        let cards = PedroOpsSnapshotBuilder().statusCards(results: [:])

        assert(cards.map(\.id) == ["x99", "truenas"], "Expected X99 and TrueNAS status cards")
        assert(cards.allSatisfy { $0.state == .unknown }, "Missing SSH results should stay unknown, not fake healthy")
    }

    static func testMacCardsIncludePercentUsageTiles() {
        let snapshot = PedroOpsMacSnapshot(
            hostName: "pedro-mac",
            cpuUsagePercent: 42,
            gpuUsagePercent: 33,
            memoryUsagePercent: 51,
            storageUsagePercent: 58,
            uptime: "2d 4h",
            thermalState: "Nominal"
        )
        let cards = PedroOpsSnapshotBuilder().macCards(snapshot: snapshot)

        assert(cards.map(\.id) == ["mac-cpu", "mac-gpu", "mac-ram", "mac-ssd"], "Expected CPU, GPU, RAM and SSD cards")
        assert(cards[0].metrics.contains(PedroOpsMetric(label: "Uso", value: "42%", detail: nil)))
        assert(cards[1].metrics.contains(PedroOpsMetric(label: "Uso", value: "33%", detail: nil)))
        assert(cards[2].metrics.contains(PedroOpsMetric(label: "Uso", value: "51%", detail: nil)))
        assert(cards[3].metrics.contains(PedroOpsMetric(label: "Uso", value: "58%", detail: nil)))
    }

    static func testDynamicCardWidthFillsUpToThreeVisibleCards() {
        let availableWidth: Double = 440
        let spacing: Double = 8

        assert(PedroOpsCardLayout.cardWidth(cardCount: 1, availableWidth: availableWidth, spacing: spacing) == 440)
        assert(PedroOpsCardLayout.cardWidth(cardCount: 2, availableWidth: availableWidth, spacing: spacing) == 216)
        assert(PedroOpsCardLayout.cardWidth(cardCount: 3, availableWidth: availableWidth, spacing: spacing) == 141)
        assert(PedroOpsCardLayout.cardWidth(cardCount: 4, availableWidth: availableWidth, spacing: spacing) == 141)
    }

    static func testMacLayoutUsesFourEqualCards() {
        let availableWidth: Double = 500
        let spacing: Double = 6

        assert(PedroOpsTabKind.mac.visibleCardLimit == 4, "Mac should fit four equal cards")
        assert(PedroOpsCardLayout.cardWidth(cardCount: 4, availableWidth: availableWidth, spacing: spacing, visibleLimit: 4) == 120)
    }

    static func testCardLayoutExpandsVerticallyToAvailableNotchHeight() {
        assert(PedroOpsCardLayout.cardHeight(availableHeight: 90) == 90, "Cards must never exceed the available height")
        assert(PedroOpsCardLayout.cardHeight(availableHeight: 108) == 108, "Alert cards must fit below their toolbar")
        assert(PedroOpsCardLayout.cardHeight(availableHeight: 0) == 0)
        assert(PedroOpsCardLayout.cardHeight(availableHeight: 124) == 124, "Cards should fill taller notch content")
        assert(PedroOpsCardLayout.contentHeight(totalHeight: 116) == 102, "Content height should subtract vertical padding")
    }

    static func testCardLayoutReservesCompactHeaderHeight() {
        assert(
            PedroOpsCardLayout.bodyHeight(totalHeight: 160, headerHeight: 26, spacing: 6) == 128,
            "Cards below a compact header should use only the remaining visible height"
        )
    }

    static func testMacTabTitle() {
        assert(PedroOpsTabKind.mac.title == "Mac", "Expected Mac tab title")
        assert(PedroOpsTabKind.mac.subtitle == "Status local", "Expected Mac tab subtitle")
    }

    static func testUnavailableSSHResultBecomesWarningCard() {
        let result = PedroOpsSSHResult(hostID: "x99", isReachable: false, output: "", errorMessage: "Host unreachable")
        let cards = PedroOpsSnapshotBuilder().statusCards(results: ["x99": result])
        let x99 = cards.first { $0.id == "x99" }

        assert(x99?.state == .warning, "Unavailable SSH should become a warning card")
        assert(x99?.metrics.first?.label == "Conexão", "Warning card should start with connection state")
        assert(x99?.metrics.first?.value == "Offline", "Warning card should say Offline")
    }

    static func testUnresolvedSSHAliasBecomesConfigWarning() {
        let result = PedroOpsSSHResult(
            hostID: "x99",
            isReachable: false,
            output: "",
            errorMessage: "ssh: Could not resolve hostname x99: nodename nor servname provided, or not known"
        )
        let cards = PedroOpsSnapshotBuilder().statusCards(results: ["x99": result])
        let x99 = cards.first { $0.id == "x99" }

        assert(x99?.state == .warning, "Unresolved SSH alias should stay a warning")
        assert(x99?.metrics.first?.value == "Alias ausente", "Unresolved SSH alias should be classified as config missing")
        assert(x99?.footnote?.contains("Tailscale") == true, "Config warning should mention Tailscale/DNS")
    }

    static func testSSHOutputParserExtractsHostMetrics() {
        let output = """
        hostname=x99
        uptime=up 12 days
        load=1.20 0.90 0.42
        memory=12G / 32G
        disk=48%
        temp=44 C
        """

        let metrics = PedroOpsSnapshotBuilder.metrics(fromSSHOutput: output)

        assert(metrics.contains(PedroOpsMetric(label: "Hostname", value: "x99", detail: nil)))
        assert(metrics.contains(PedroOpsMetric(label: "Uptime", value: "up 12 days", detail: nil)))
        assert(metrics.contains(PedroOpsMetric(label: "Carga", value: "1.20 0.90 0.42", detail: nil)))
        assert(metrics.contains(PedroOpsMetric(label: "Memória", value: "38%", detail: "12/32 GB", progressPercent: 38)))
        assert(metrics.contains(PedroOpsMetric(label: "Disco", value: "48%", detail: nil, progressPercent: 48)))
        assert(metrics.contains(PedroOpsMetric(label: "Temp", value: "44°C", detail: nil)))
    }

    static func testSSHOutputParserExtractsBothX99GPUs() {
        let output = """
        gpu=0|Quadro P6000|7|2048|24576|61
        gpu=1|NVIDIA GeForce RTX 3070 Ti|34|4096|8192|67
        """

        let metrics = PedroOpsSnapshotBuilder.metrics(fromSSHOutput: output)

        assert(metrics.contains(PedroOpsMetric(
            label: "GPU 0 · Quadro P6000",
            value: "7%",
            detail: "61°C",
            progressPercent: 7,
            secondaryValue: "2/24 GB",
            secondaryProgressPercent: 8
        )))
        assert(metrics.contains(PedroOpsMetric(
            label: "GPU 1 · RTX 3070 Ti",
            value: "34%",
            detail: "67°C",
            progressPercent: 34,
            secondaryValue: "4/8 GB",
            secondaryProgressPercent: 50
        )))
    }

    static func testSSHOutputParserExtractsTrueNASPools() {
        let output = """
        hostname=truenas
        pools=ArchivePool 7.27T 628G 8%, PrimaryPool 29.1T 3.56T 12%, boot-pool 111G 3.20G 2%
        memory=26Gi / 251Gi
        """

        let metrics = PedroOpsSnapshotBuilder.metrics(fromSSHOutput: output)

        assert(metrics.contains(PedroOpsMetric(label: "Pools", value: "Principal 12%", detail: nil, progressPercent: 12, secondaryValue: "Arquivo 8%", secondaryProgressPercent: 8)))
        assert(metrics.contains(PedroOpsMetric(label: "Memória", value: "10%", detail: "28/270 GB", progressPercent: 10)))
    }

    static func testStatusCardsKeepTemperatureVisible() {
        let output = """
        hostname=X99-DUAL
        uptime=up 7 days
        cpu=2%
        gpu=14%|55°C
        load=1.51 1.75 1.78
        memory=26Gi / 251Gi
        disk=13% used
        temp=50/42°C
        """
        let result = PedroOpsSSHResult(hostID: "x99", isReachable: true, output: output, errorMessage: nil)
        let cards = PedroOpsSnapshotBuilder().statusCards(results: ["x99": result])
        let visibleLabels = cards[0].metrics.prefix(3).map(\.label)

        assert(visibleLabels.contains("CPU"), "Expected CPU usage to stay in the visible status metrics")
        assert(visibleLabels.contains("GPU"), "Expected GPU usage to stay in the visible status metrics")
        assert(visibleLabels.contains("Temp"), "Expected temperature to stay in the visible status metrics")
    }

    static func testStatusCardsKeepBothX99GPUsVisible() {
        let output = """
        hostname=X99-DUAL
        cpu=2%
        gpu=0|Quadro P6000|7|2048|24576|61
        gpu=1|NVIDIA GeForce RTX 3070 Ti|34|4096|8192|67
        temp=50/42°C
        """
        let result = PedroOpsSSHResult(hostID: "x99", isReachable: true, output: output, errorMessage: nil)
        let cards = PedroOpsSnapshotBuilder().statusCards(results: ["x99": result])
        let visibleLabels = cards[0].metrics.prefix(3).map(\.label)

        assert(visibleLabels == ["CPU", "GPU 0 · Quadro P6000", "GPU 1 · RTX 3070 Ti"], "Expected CPU and both GPUs to be prioritized in the X99 card")
    }

    static func testStatusCardsKeepPoolsVisibleForTrueNAS() {
        let output = """
        hostname=truenas
        uptime=up 2 days
        load=0.51 0.75 0.78
        memory=18Gi / 64Gi
        disk=12% used
        pools=ArchivePool 7.27T 628G 8%, PrimaryPool 29.1T 3.56T 12%, boot-pool 111G 3.20G 2%
        temp=43 C
        """
        let result = PedroOpsSSHResult(hostID: "truenas", isReachable: true, output: output, errorMessage: nil)
        let cards = PedroOpsSnapshotBuilder().statusCards(results: ["truenas": result])
        let truenas = cards.first { $0.id == "truenas" }
        let visibleLabels = truenas?.metrics.prefix(3).map(\.label) ?? []

        assert(visibleLabels.contains("Pools"), "Expected TrueNAS pools to stay in the visible status metrics")
    }

    static func testSSHRemoteCommandQuotesProbeScript() {
        let command = PedroOpsSSHRunner.remoteCommand(for: "printf 'ok now'")

        assert(command == "sh -lc 'printf '\\''ok now'\\'''", "Expected remote SSH command to preserve shell quoting")
    }

    static func testProxmoxProbeParserExtractsHostAndGuests() {
        let output = """
        __HOST__
        {"cpu":0.125,"cpuinfo":{"cores":12,"cpus":24,"model":"Intel Xeon E5-2670 v3"},"memory":{"used":8589934592,"total":34359738368},"rootfs":{"used":6871947673,"total":68719476736},"uptime":172800,"pveversion":"pve-manager/9.2.11/test","loadavg":["0.20","0.30","0.40"]}
        __GUESTS__
        [{"cpu":0.25,"disk":5368709120,"id":"lxc/104","maxcpu":6,"maxdisk":42949672960,"maxmem":8589934592,"mem":4294967296,"name":"lab-apps","status":"running","type":"lxc","uptime":86400,"vmid":104}]
        __THERMALS__
        cpu_temp=39
        gpu_name=GTX 1050 Ti
        gpu_memory_gb=4
        gpu_temp=33
        """

        let snapshot = PedroProxmoxSnapshotParser.parse(output: output)

        assert(snapshot.host?.cpuUsagePercent == 13, "Expected rounded Proxmox CPU usage")
        assert(snapshot.host?.memoryUsagePercent == 25, "Expected Proxmox RAM usage")
        assert(snapshot.host?.storageUsagePercent == 10, "Expected Proxmox SSD usage")
        assert(snapshot.host?.cpuTemperature == 39, "Expected CPU package temperature")
        assert(snapshot.host?.gpuName == "GTX 1050 Ti", "Expected Proxmox GPU model")
        assert(snapshot.host?.gpuMemoryGB == 4, "Expected Proxmox GPU memory")
        assert(snapshot.host?.gpuTemperature == 33, "Expected GPU temperature")
        assert(snapshot.guests.first?.name == "lab-apps", "Expected live CT name")
        assert(snapshot.guests.first?.cpuUsagePercent == 25, "Expected CT CPU usage")
        assert(snapshot.guests.first?.memoryUsagePercent == 50, "Expected CT RAM usage")
    }

    static func testProxmoxSnapshotSeparatesContainersAndVMs() {
        let guests = [
            PedroProxmoxGuest(id: 100, name: "qdrant", kind: .container, status: .running, cpuUsagePercent: 1, memoryUsagePercent: 20, storageUsagePercent: 10, uptime: 120),
            PedroProxmoxGuest(id: 200, name: "windows", kind: .virtualMachine, status: .stopped, cpuUsagePercent: 0, memoryUsagePercent: 0, storageUsagePercent: 40, uptime: 0)
        ]
        let snapshot = PedroProxmoxSnapshot(host: nil, guests: guests, errorMessage: nil)

        assert(snapshot.containers.map(\.id) == [100], "Expected LXC guests in the CT guide")
        assert(snapshot.virtualMachines.map(\.id) == [200], "Expected QEMU guests in the VM guide")
    }

    static func testCardContentWidthAccountsForPadding() {
        let width = PedroOpsCardLayout.contentWidth(totalWidth: 120)

        assert(width == 106, "Expected card content width to subtract internal padding")
    }

    static func testCodexUsageReaderUsesRealUserHome() {
        let path = PedroOpsCodexUsageReader.databasePath(userHome: "/Users/pedro")

        assert(path == "/Users/pedro/.codex/state_5.sqlite", "Expected Codex usage reader to use the real user home")
    }

    static func testCodexUsageReaderFallsBackFromSandboxHome() {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-sandbox-home-test-\(UUID().uuidString)")
        let sandboxHome = rootURL.appendingPathComponent("container")
        let realHome = rootURL.appendingPathComponent("real-user")
        let realCodexDirectory = realHome.appendingPathComponent(".codex")
        let realSessionsDirectory = realCodexDirectory.appendingPathComponent("sessions")
        try! FileManager.default.createDirectory(at: sandboxHome, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: realSessionsDirectory, withIntermediateDirectories: true)
        try! Data().write(to: realCodexDirectory.appendingPathComponent("state_5.sqlite"))
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let databasePath = PedroOpsCodexUsageReader.databasePath(
            userHome: sandboxHome.path,
            fallbackHomes: [realHome.path]
        )
        let sessionsPath = PedroOpsCodexUsageReader.sessionsDirectory(
            userHome: sandboxHome.path,
            fallbackHomes: [realHome.path]
        )

        assert(
            databasePath == realCodexDirectory.appendingPathComponent("state_5.sqlite").path,
            "Expected Codex database lookup to fall back from the sandbox container"
        )
        assert(
            sessionsPath == realSessionsDirectory.path,
            "Expected Codex sessions lookup to fall back from the sandbox container"
        )
    }

    static func testCodexUsageReaderSummarizesThreadsDatabase() {
        let now = Date(timeIntervalSince1970: 1_783_080_000)
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-state-test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let database = openTemporarySQLiteDatabase(at: databaseURL)
        defer { sqlite3_close(database) }

        executeSQLite(
            """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                updated_at INTEGER NOT NULL,
                tokens_used INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO threads VALUES ('recent-a', \(Int(now.timeIntervalSince1970) - 60), 1200);
            INSERT INTO threads VALUES ('recent-b', \(Int(now.timeIntervalSince1970) - 6 * 60 * 60), 2200);
            INSERT INTO threads VALUES ('old', \(Int(now.timeIntervalSince1970) - 8 * 24 * 60 * 60), 9999);
            """,
            in: database
        )

        let summary = PedroOpsCodexUsageReader.summary(
            databasePath: databaseURL.path,
            now: now,
            sessionsDirectory: "/tmp/missing-codex-sessions-\(UUID().uuidString)"
        )

        assert(summary.lastFiveHoursTokens == 1200, "Expected 5h token window from Codex threads")
        assert(summary.lastWeekTokens == 3400, "Expected weekly token window from Codex threads")
        assert(summary.sessionCount == 2, "Expected weekly session count from Codex threads")
        assert(summary.source == "Limites indisponíveis", "Session totals must not be presented as account quota")
    }

    static func testCodexSessionStateTracksTaskLifecycle() {
        let working = PedroAgentSessionProvider.codexState(
            fromEventTypes: ["user_message", "task_started", "token_count"]
        )
        let completed = PedroAgentSessionProvider.codexState(
            fromEventTypes: ["task_started", "agent_message", "task_complete"]
        )
        let restarted = PedroAgentSessionProvider.codexState(
            fromEventTypes: ["task_started", "task_complete", "task_started"]
        )

        assert(working == .working, "Expected an unfinished Codex task to be working")
        assert(completed == .completed, "Expected task_complete to mark a Codex task completed")
        assert(restarted == .working, "Expected a later task_started event to restore working state")
    }

    static func testCodexSessionOpenerBuildsExactThreadURL() {
        let url = PedroAgentSessionOpener.codexURL(threadID: "019f-test")

        assert(url?.absoluteString == "codex://threads/019f-test", "Expected exact Codex desktop thread deep link")
    }

    static func testAgentBridgeDecodesPermissionEvent() {
        let fixture = """
        {"eventID":"event-1","provider":"codex","kind":"permissionRequest","sessionID":"session-1","threadID":"thread-1","requestID":"request-1","title":"Shell","prompt":"npm test","cwd":"/tmp/project","model":"gpt-5","terminalBundleIdentifier":"com.apple.Terminal","createdAt":1784771400000,"expiresAt":1784771520000}
        """

        let event = PedroAgentBridge.decodeEvent(Data(fixture.utf8))

        assert(event?.kind == .permissionRequest, "Expected permission request bridge event")
        assert(event?.provider == .codex, "Expected Codex bridge provider")
        assert(event?.requestID == "request-1", "Expected bridge request correlation id")
        assert(event?.prompt == "npm test", "Expected bridge prompt")
    }

    static func testAgentBridgeWritesApprovalResponse() {
        let userHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-bridge-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: userHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: userHome) }

        try! PedroAgentBridge.respond(
            to: "request-allow",
            decision: .allow,
            userHome: userHome.path
        )
        let responseURL = PedroAgentBridge.responsesDirectory(userHome: userHome.path)
            .appendingPathComponent("request-allow.json")
        let response = try! String(contentsOf: responseURL, encoding: .utf8)

        assert(response.contains("\"decision\":\"allow\""), "Expected native allow response file")
    }

    static func testAgentBridgePermissionOverridesCodexSessionState() {
        let now = Date(timeIntervalSince1970: 1_784_771_400)
        let session = PedroAgentSession(
            id: "codex.thread-1",
            provider: .codex,
            title: "Build app",
            project: "project",
            state: .working,
            model: "gpt-5",
            branch: "main",
            updatedAt: now,
            preview: nil,
            threadID: "thread-1",
            terminalBundleIdentifier: "com.openai.codex",
            approval: nil
        )
        let fixture = """
        {"eventID":"event-2","provider":"codex","kind":"permissionRequest","sessionID":"thread-1","threadID":"thread-1","requestID":"request-2","title":"Shell","prompt":"npm test","cwd":"/tmp/project","createdAt":1784771400000,"expiresAt":1784771520000}
        """
        let event = PedroAgentBridge.decodeEvent(Data(fixture.utf8))!

        let merged = PedroAgentSessionProvider.merge(
            sessions: [session],
            bridgeEvents: [event],
            now: now
        )

        assert(merged[0].state == .waitingApproval, "Expected permission event to request attention")
        assert(merged[0].approval?.requestID == "request-2", "Expected permission response correlation")
    }

    static func testAgentMonitorConsumesEachEventOnlyOnce() {
        var state = PedroAgentMonitorState.empty

        assert(state.consume(eventID: "event-once"), "Expected a new event to be consumed")
        assert(!state.consume(eventID: "event-once"), "Expected duplicate events to stay silent")
    }

    static func testEntitlementsUseHomeRelativeAbsolutePathsForPedroOpsData() {
        let entitlementsURL = URL(fileURLWithPath: "boringNotch/boringNotch.entitlements")
        let content = try! String(contentsOf: entitlementsURL, encoding: .utf8)

        assert(!content.contains("<key>com.apple.security.app-sandbox</key>"), "Pedro Edition must run its local SSH and agent CLIs outside the App Store sandbox")
        assert(content.contains("<string>/.codex/</string>"), "Sandbox exception must point at the real ~/.codex directory")
        assert(content.contains("<string>/.pedroops/</string>"), "Sandbox exception must allow the Claude cookie cache")
        assert(!content.contains("<string>.codex/</string>"), "Home-relative sandbox exceptions need a leading slash")
    }

    static func testClaudeUsageParserExtractsFiveHourAndWeeklyLimits() {
        let payload = """
        {
          "five_hour": {
            "utilization": 24.0,
            "resets_at": "2026-07-03T10:59:59.826197+00:00"
          },
          "seven_day": {
            "utilization": 14.0,
            "resets_at": "2026-07-09T21:59:59.826220+00:00"
          },
          "limits": [
            {"kind":"session","percent":24,"resets_at":"2026-07-03T10:59:59.826197+00:00","is_active":true},
            {"kind":"weekly_all","percent":14,"resets_at":"2026-07-09T21:59:59.826220+00:00","is_active":false}
          ]
        }
        """

        let usage = PedroOpsClaudeUsageReader.parseUsageData(Data(payload.utf8), now: Date(timeIntervalSince1970: 1_783_060_000))

        assert(usage?.session5hPercent == 24, "Expected Claude 5h utilization")
        assert(usage?.weekly7dPercent == 14, "Expected Claude weekly utilization")
        assert(usage?.session5hResetsAt != nil, "Expected Claude 5h reset date")
        assert(usage?.weekly7dResetsAt != nil, "Expected Claude weekly reset date")
        assert(usage?.isStale == false, "Fresh API payload should not be stale")
    }

    static func testClaudeUsageSummaryUsesPercentDisplays() {
        let usage = ClaudeUsage(
            session5hPercent: 24,
            session5hResetsAt: Date(timeIntervalSince1970: 1_783_060_000),
            weekly7dPercent: 14,
            weekly7dResetsAt: Date(timeIntervalSince1970: 1_783_600_000),
            isStale: false,
            lastUpdated: Date(timeIntervalSince1970: 1_783_050_000),
            errorMessage: nil
        )

        let summary = PedroOpsClaudeUsageReader.summary(from: usage, historySessionCount: 3, now: usage.lastUpdated)
        let snapshot = PedroOpsUsageSnapshot(apps: [
            PedroOpsUsageAppSnapshot(
                id: "claude",
                title: "Claude",
                bundleIdentifier: "com.anthropic.claudefordesktop",
                iconName: "sparkles",
                isRunning: true,
                windowCount: 1,
                isFrontmost: false,
                lastFiveHoursTokens: summary.lastFiveHoursTokens,
                lastWeekTokens: summary.lastWeekTokens,
                sessionCount: summary.sessionCount,
                usageSource: summary.source,
                lastFiveHoursDisplay: summary.lastFiveHoursDisplay,
                lastWeekDisplay: summary.lastWeekDisplay,
                lastFiveHoursDetail: summary.lastFiveHoursDetail,
                lastWeekDetail: summary.lastWeekDetail,
                lastFiveHoursProgressPercent: summary.lastFiveHoursProgressPercent,
                lastWeekProgressPercent: summary.lastWeekProgressPercent,
                isUsageStale: summary.isStale
            )
        ])

        let card = PedroOpsSnapshotBuilder().usageCards(snapshot: snapshot)[0]

        assert(card.metrics.contains(PedroOpsMetric(label: "5h", value: "24%", detail: summary.lastFiveHoursDetail, progressPercent: 24)))
        assert(card.metrics.contains(PedroOpsMetric(label: "Semana", value: "14%", detail: summary.lastWeekDetail, progressPercent: 14)))
        assert(card.metrics.count == 2, "Claude card should not show session count")
        assert(card.state == .active, "Fresh Claude API usage should be active")
    }

    static func testSSHArgumentsUseExplicitUserKey() {
        let target = PedroOpsSSHTarget(id: "truenas", title: "TrueNAS", hostAlias: "user@192.0.2.20", iconName: "externaldrive.fill")
        let arguments = PedroOpsSSHRunner.arguments(
            for: target,
            userHome: "/Users/pedro",
            identityExists: true,
            remoteCommand: "printf ok"
        )

        assert(arguments.contains("-i"), "Expected SSH to receive an explicit identity file")
        assert(arguments.contains("/Users/pedro/.ssh/id_ed25519"), "Expected SSH to use the real user's private key")
        assert(arguments.contains("-o"), "Expected SSH options")
        assert(arguments.contains("UserKnownHostsFile=/Users/pedro/.ssh/known_hosts"), "Expected SSH to use the real user's known_hosts")
        assert(arguments.contains("HOME=/Users/pedro") == false, "HOME should be set through process environment, not passed as an SSH arg")
    }

    static func testAlienwareSSHTargetUsesX99Bridge() {
        let target = PedroOpsSnapshotBuilder.alienwareTarget
        let arguments = PedroOpsSSHRunner.arguments(
            for: target,
            userHome: "/Users/pedro",
            identityExists: true,
            remoteCommand: PedroOpsSSHRunner.alienwareRemoteCommand()
        )

        assert(target.hostAlias == "user@windows.example.invalid", "Expected the Alienware display endpoint")
        assert(arguments.contains("user@192.0.2.10"), "Expected SSH transport through X99")
        assert(arguments.last?.contains("id_ed25519_alienware_worker") == true, "Expected the validated X99 Alienware identity")
        assert(arguments.last?.contains("EncodedCommand") == true, "Expected an encoded PowerShell probe")
    }

    static func testAlienwareStatusCardBuildsSeparately() {
        let target = PedroOpsSnapshotBuilder.alienwareTarget
        let output = """
        hostname=Alienware-M16
        model=Alienware m16 R1
        uptime=2d 4h
        cpu=11%
        cpu_model=13th Gen Intel(R) Core(TM) i9-13900HX
        cpu_clock=2.4 GHz
        memory=17179869184 / 34359738368
        disk=1360000000000 / 2000000000000
        battery=82%|2
        gpu=0|NVIDIA GeForce RTX 4080 Laptop GPU|24|5341|12282|73
        """
        let result = PedroOpsSSHResult(hostID: target.id, isReachable: true, output: output, errorMessage: nil)
        let cards = PedroOpsSnapshotBuilder().statusCards(
            results: [target.id: result],
            targets: [target]
        )

        assert(cards.map(\.id) == ["alienware"], "Expected a dedicated Alienware card")
        assert(cards[0].metrics.first?.label.hasPrefix("GPU") == true, "Expected readable GPU first")
        assert(cards[0].metrics.contains { $0.label.hasPrefix("GPU 0") }, "Expected RTX metrics")
        assert(cards[0].metrics.contains(PedroOpsMetric(label: "Memória", value: "50%", detail: "17/34 GB", progressPercent: 50)))
        assert(cards[0].metrics.contains(PedroOpsMetric(label: "Processador", value: "i9-13900HX")))
        assert(cards[0].metrics.contains(PedroOpsMetric(label: "Disco", value: "68%", detail: "1.4 TB/2.0 TB", progressPercent: 68)))
        assert(cards[0].metrics.contains(PedroOpsMetric(label: "Bateria", value: "82%", detail: "na tomada", progressPercent: 82)))
    }

    static func testClaudeHistoryCountsRecentDistinctSessions() {
        let now = Date(timeIntervalSince1970: 1_783_059_000)
        let recentTimestamp = Int(now.addingTimeInterval(-60 * 60).timeIntervalSince1970 * 1000)
        let oldTimestamp = Int(now.addingTimeInterval(-8 * 24 * 60 * 60).timeIntervalSince1970 * 1000)
        let content = """
        {"sessionId":"session-a","timestamp":\(recentTimestamp)}
        {"sessionId":"session-a","timestamp":\(recentTimestamp)}
        {"sessionId":"session-b","timestamp":\(recentTimestamp)}
        {"sessionId":"old-session","timestamp":\(oldTimestamp)}
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-history-test-\(UUID().uuidString).jsonl")
        try! content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let count = PedroOpsClaudeUsageReader.recentHistorySessionCount(in: url, now: now)

        assert(count == 2, "Expected recent Claude history to count distinct session ids")
    }

    private static func openTemporarySQLiteDatabase(at url: URL) -> OpaquePointer {
        var database: OpaquePointer?
        let result = sqlite3_open(url.path, &database)
        assert(result == SQLITE_OK, "Expected temporary SQLite database to open")
        return database!
    }

    private static func executeSQLite(_ sql: String, in database: OpaquePointer) {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &error)
        if let error {
            let message = String(cString: error)
            sqlite3_free(error)
            assertionFailure("SQLite failed: \(message)")
        }
        assert(result == SQLITE_OK, "Expected SQLite statement to execute")
    }
}
