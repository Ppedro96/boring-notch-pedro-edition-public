import Foundation

@main
struct PedroClipboardStackTests {
    static func main() {
        testClipboardHistoryDeduplicatesAndMovesLatestToFront()
        testClipboardHistoryKeepsPinnedItemsBeyondRegularLimit()
        testClipboardHistoryDropsExpiredRegularItems()
        testStackSnapshotDecodesReadOnlySections()
        testStackSectionsKeepExpectedOrder()
        testStackFreshnessDoesNotPretendOffline()
        testFinishedBackupTasksStayActiveWithoutNewRootSnapshot()
        testPrimarySSHCardsUseLocalProduction()
        testLocalProductionNeverFallsBackToVPS()
        testLocalProductionDistinguishesStoppedAndMissingContainers()
        testLocalFeedDropsLegacyHostsAndKeepsOperationalData()
        testLiveActivityQueuePrefersHigherPriority()
        testLiveActivityQueueDeduplicatesUnchangedState()
        testLiveActivityQueueReopensWhenStateChanges()
        testLiveActivityQueuePrunesExpiredItems()
        testStackIncidentTrackerRequiresConsecutiveOfflineReadings()
        testStackIncidentTrackerDoesNotRecoverAnUnreportedBlip()
        print("PedroClipboardStackTests passed")
    }

    static func testStackFreshnessDoesNotPretendOffline() {
        let now = Date()
        let card = PedroStackCard(id: "core.supa", title: "Supabase", subtitle: "Online", state: .active,
                                  icon: "server.rack", metrics: [], updatedAt: now)
        assert(card.checkingFreshness(now: now).state == .active)
        assert(card.checkingFreshness(now: now.addingTimeInterval(301)).state == .warning)
        assert(card.checkingFreshness(now: now, feedUnavailable: true).state == .warning)
        assert(card.checkingFreshness(now: now, feedUnavailable: true).subtitle.contains("Última leitura"))
    }

    static func testClipboardHistoryDeduplicatesAndMovesLatestToFront() {
        let now = Date(timeIntervalSince1970: 1_783_166_400)
        let older = PedroClipboardItem.text(
            "primeiro",
            sourceBundleIdentifier: "com.apple.TextEdit",
            capturedAt: now.addingTimeInterval(-60)
        )
        let newer = PedroClipboardItem.text(
            "segundo",
            sourceBundleIdentifier: "com.apple.Safari",
            capturedAt: now
        )

        var history = PedroClipboardHistory()
        history.insert(older, now: now)
        history.insert(newer, now: now)
        history.insert(
            PedroClipboardItem.text(
                "primeiro",
                sourceBundleIdentifier: "com.apple.Terminal",
                capturedAt: now.addingTimeInterval(1)
            ),
            now: now.addingTimeInterval(1)
        )

        assert(history.items.count == 2, "Repeated clipboard payloads should be deduplicated")
        assert(history.items[0].displayText == "primeiro", "Latest duplicate should move to the front")
        assert(history.items[0].sourceBundleIdentifier == "com.apple.Terminal", "Latest duplicate should refresh source metadata")
    }

    static func testClipboardHistoryKeepsPinnedItemsBeyondRegularLimit() {
        let now = Date(timeIntervalSince1970: 1_783_166_400)
        let pinned = PedroClipboardItem.text(
            "fixado",
            sourceBundleIdentifier: nil,
            capturedAt: now.addingTimeInterval(-120),
            isPinned: true
        )
        let regular = (0..<4).map { index in
            PedroClipboardItem.text(
                "item \(index)",
                sourceBundleIdentifier: nil,
                capturedAt: now.addingTimeInterval(TimeInterval(index))
            )
        }

        var history = PedroClipboardHistory(items: [pinned])
        regular.forEach { history.insert($0, now: now, regularLimit: 2) }

        assert(history.items.contains(where: { $0.id == pinned.id }), "Pinned items should not count toward the regular limit")
        assert(history.items.filter { !$0.isPinned }.count == 2, "Regular history should respect its configured limit")
    }

    static func testClipboardHistoryDropsExpiredRegularItems() {
        let now = Date(timeIntervalSince1970: 1_783_166_400)
        let expired = PedroClipboardItem.text(
            "antigo",
            sourceBundleIdentifier: nil,
            capturedAt: now.addingTimeInterval(-15 * 24 * 60 * 60)
        )
        let pinnedExpired = PedroClipboardItem.text(
            "antigo fixado",
            sourceBundleIdentifier: nil,
            capturedAt: now.addingTimeInterval(-15 * 24 * 60 * 60),
            isPinned: true
        )
        let current = PedroClipboardItem.text(
            "atual",
            sourceBundleIdentifier: nil,
            capturedAt: now
        )

        var history = PedroClipboardHistory(items: [expired, pinnedExpired])
        history.insert(current, now: now, retentionDays: 14)

        assert(!history.items.contains(where: { $0.id == expired.id }), "Expired regular items should be removed")
        assert(history.items.contains(where: { $0.id == pinnedExpired.id }), "Pinned items should survive age-based cleanup")
    }

    static func testStackSnapshotDecodesReadOnlySections() {
        let payload = """
        {
          "generated_at": "2026-07-23T03:25:36Z",
          "sections": {
            "cloud": [{
              "id": "cloud.vps1",
              "title": "VPS1",
              "subtitle": "Online",
              "state": "active",
              "icon": "server.rack",
              "metrics": [{"label": "RAM", "value": "14", "unit": "%"}],
              "updated_at": "2026-07-23T03:00:20Z"
            }],
            "core": [],
            "operation": [{
              "id": "operation.wpp",
              "title": "WPP SaaS",
              "subtitle": "1/3 conectadas",
              "state": "warning",
              "icon": "message.fill",
              "metrics": [{"label": "Conectadas", "value": "1/3", "unit": null}],
              "updated_at": "2026-07-23T03:25:36Z"
            }],
            "backup": []
          },
          "source_health": {"main": true, "pool": true}
        }
        """

        let snapshot = try! PedroStackSnapshot.decoder.decode(
            PedroStackSnapshot.self,
            from: Data(payload.utf8)
        )

        assert(snapshot.cards(for: .cloud).first?.title == "VPS1", "Cloud cards should decode")
        assert(snapshot.cards(for: .operation).first?.metrics.first?.displayValue == "1/3", "Operation metrics should decode")
        assert(snapshot.sourceHealth.main && snapshot.sourceHealth.pool, "Source health should be preserved")
    }

    static func testStackSectionsKeepExpectedOrder() {
        assert(
            PedroStackSection.allCases == [.cloud, .core, .operation, .backup],
            "Stack segments should keep the existing order"
        )
        assert(PedroStackSection.cloud.title == "Local")
        assert(PedroStackSection.cloud.icon == "server.rack")
        assert(PedroStackSection.operation.title == "Operação", "Operation should keep its Portuguese label")
    }

    static func testFinishedBackupTasksStayActiveWithoutNewRootSnapshot() {
        let now = Date(timeIntervalSince1970: 1_784_718_000)
        let output = """
        PrimaryPool|FINISHED|1784700000|true|14|DAY
        ArchivePool|FINISHED|1784701800|true|14|DAY
        """

        let cards = PedroStackProvider.backupCards(from: output, now: now)

        assert(cards.count == 2, "Both configured backup tasks should be represented")
        assert(cards.allSatisfy { $0.state == .active }, "Finished backup tasks should stay green")
        assert(
            cards.allSatisfy { $0.subtitle == "Backup concluído" },
            "Backup cards should describe the actual task result"
        )
    }

    static let productionOutput = """
    __HOST__
    {"cpu":0.02,"cpuinfo":{"cores":6,"cpus":12,"model":"AMD Ryzen 5 3600"},"memory":{"used":5800000000,"total":16692400128},"rootfs":{"used":5044244480,"total":39520157696}}
    __GUESTS__
    [{"vmid":104,"node":"lab","name":"lab-apps","type":"lxc","status":"running","maxmem":8000,"mem":4000,"maxdisk":10000,"disk":1000},{"vmid":111,"node":"pveo2","name":"insight-apps","type":"lxc","status":"running","cpu":0.04,"maxmem":12000,"mem":6000,"maxdisk":10000,"disk":3500},{"vmid":112,"node":"pveo2","name":"insight-pool","type":"lxc","status":"running","cpu":0.01,"maxmem":2000,"mem":500,"maxdisk":10000,"disk":2600}]
    __THERMALS__
    node_name=pveo2
    cpu_percent=3
    """

    static func testPrimarySSHCardsUseLocalProduction() {
        let result = PedroOpsSSHResult(
            hostID: "proxmox-pveo2",
            isReachable: true,
            output: productionOutput,
            errorMessage: nil
        )
        let now = Date(timeIntervalSince1970: 1_784_718_000)
        let cards = PedroStackProvider.productionCards(
            from: result,
            now: now
        )
        assert(cards.map(\.id) == ["local.pve02", "local.ct111", "local.ct112"])
        assert(cards.map(\.title) == ["PVE02", "CT111 · Apps", "CT112 · POOL"])
        assert(cards.allSatisfy { $0.state == .active && $0.updatedAt == now })
        assert(cards[0].metrics.map(\.displayValue) == ["3%", "35%", "13%"])
        assert(cards[1].metrics.map(\.displayValue) == ["4%", "50%", "35%"])
        assert(cards[2].metrics.map(\.displayValue) == ["1%", "25%", "26%"])
        assert(cards.allSatisfy { $0.metrics.map(\.label) == ["CPU", "RAM", "Disco"] })
        assert(PedroProxmoxNode.pveo2.target.sshHostAlias == "root@192.0.2.50")
        assert(PedroProxmoxNode.pveo2.target.identityFileName == "id_ed25519_secondary")
    }

    static func testLocalProductionNeverFallsBackToVPS() {
        for result in [
            PedroOpsSSHResult(hostID: "proxmox-pveo2", isReachable: false, output: "", errorMessage: "Timeout"),
            PedroOpsSSHResult(hostID: "proxmox-pveo2", isReachable: true, output: "hostname=old-vps", errorMessage: nil),
            PedroOpsSSHResult(hostID: "proxmox-pveo2", isReachable: true, output: productionOutput.replacingOccurrences(of: "node_name=pveo2", with: "node_name=lab"), errorMessage: nil)
        ] {
            let cards = PedroStackProvider.productionCards(from: result)
            assert(cards.map(\.id) == ["local.pve02", "local.ct111", "local.ct112"])
            assert(cards.allSatisfy { $0.state == .warning && $0.updatedAt == nil })
            assert(cards.allSatisfy { $0.metrics.allSatisfy { $0.displayValue == "--" } })
        }
    }

    static func testLocalProductionDistinguishesStoppedAndMissingContainers() {
        let stopped = productionOutput.replacingOccurrences(of: "\"name\":\"insight-apps\",\"type\":\"lxc\",\"status\":\"running\"", with: "\"name\":\"insight-apps\",\"type\":\"lxc\",\"status\":\"stopped\"")
        let cards = PedroStackProvider.productionCards(from: PedroOpsSSHResult(hostID: "proxmox-pveo2", isReachable: true, output: stopped, errorMessage: nil))
        assert(cards[1].state == .offline && cards[1].subtitle == "Container parado")
        assert(cards[1].metrics.allSatisfy { $0.displayValue == "--" })
        assert(cards[0].state == .active && cards[2].state == .active)
        let missing = productionOutput.replacingOccurrences(of: "\"vmid\":111", with: "\"vmid\":114")
        let partial = PedroStackProvider.productionCards(from: PedroOpsSSHResult(hostID: "proxmox-pveo2", isReachable: true, output: missing, errorMessage: nil))
        assert(partial[1].state == .warning && partial[1].updatedAt == nil)
        let full = productionOutput.replacingOccurrences(of: "\"disk\":3500", with: "\"disk\":9000")
        let pressure = PedroStackProvider.productionCards(from: PedroOpsSSHResult(hostID: "proxmox-pveo2", isReachable: true, output: full, errorMessage: nil))
        assert(pressure[1].state == .warning, "Warn about actual local resource pressure")
    }

    static func testLocalFeedDropsLegacyHostsAndKeepsOperationalData() {
        let legacy = PedroStackCard(id: "cloud.vps1", title: "VPS1", subtitle: "Online", state: .active, icon: "cloud.fill", metrics: [], updatedAt: Date())
        let supabase = PedroStackCard(id: "core.supabase", title: "Supabase", subtitle: "2/2 projetos online", state: .offline, icon: "cylinder.split.1x2.fill", metrics: [PedroStackMetric(label: "Geral", value: "Offline", unit: nil), PedroStackMetric(label: "POOL", value: "Offline", unit: nil)], updatedAt: Date())
        let wpp = PedroStackCard(id: "operation.wpp", title: "WPP SaaS", subtitle: "1/5 conectadas", state: .active, icon: "message.fill", metrics: [], updatedAt: Date())
        let feed = PedroStackSnapshot(generatedAt: Date(), sections: PedroStackSections(cloud: [legacy], core: [supabase], operation: [wpp], backup: []), sourceHealth: .unavailable)
        let local = PedroStackProvider.localizingFeed(feed)
        assert(local.sections.cloud.isEmpty, "Never republish feed hardware cards, even if SSH arrives later")
        assert(local.sections.operation == feed.sections.operation && local.sourceHealth == feed.sourceHealth)
        assert(local.sections.core[0].subtitle == "Local · unificado")
        assert(local.sections.core[0].metrics.map(\.label) == ["SaaS", "POOL"])
        assert(local.sections.core[0].state == .offline, "Local labels must not manufacture healthy status")
    }

    static func testLiveActivityQueuePrefersHigherPriority() {
        let now = Date(timeIntervalSince1970: 1_783_166_400)
        var queue = PedroLiveActivityQueue()
        queue.upsert(
            PedroLiveActivity(
                id: "pulse",
                kind: .dailyPulse,
                title: "Status",
                detail: "Tudo operacional",
                symbolName: "checkmark.circle.fill",
                priority: .information,
                createdAt: now,
                expiresAt: now.addingTimeInterval(10)
            ),
            now: now
        )
        queue.upsert(
            PedroLiveActivity(
                id: "stack.vps1",
                kind: .stackIncident,
                title: "VPS1",
                detail: "Offline",
                symbolName: "exclamationmark.triangle.fill",
                priority: .stackCritical,
                createdAt: now
            ),
            now: now
        )

        assert(queue.active(now: now)?.id == "stack.vps1", "Critical Stack incidents should win the closed notch")
    }

    static func testLiveActivityQueueDeduplicatesUnchangedState() {
        let now = Date(timeIntervalSince1970: 1_783_166_400)
        var queue = PedroLiveActivityQueue()
        let activity = PedroLiveActivity(
            id: "agent.codex.1",
            stateKey: "waiting-approval",
            kind: .agentApproval,
            title: "Codex",
            detail: "Aguardando aprovação",
            symbolName: "terminal.fill",
            priority: .agentAttention,
            createdAt: now
        )

        queue.upsert(activity, now: now)
        queue.upsert(activity, now: now.addingTimeInterval(2))

        assert(queue.items.count == 1, "Unchanged activities should not create duplicate queue entries")
        assert(queue.items[0].createdAt == now, "An unchanged state should keep its original presentation time")
    }

    static func testLiveActivityQueueReopensWhenStateChanges() {
        let now = Date(timeIntervalSince1970: 1_783_166_400)
        var queue = PedroLiveActivityQueue()
        queue.upsert(
            PedroLiveActivity(
                id: "stack.vps1",
                stateKey: "offline",
                kind: .stackIncident,
                title: "VPS1",
                detail: "Offline",
                symbolName: "exclamationmark.triangle.fill",
                priority: .stackCritical,
                createdAt: now
            ),
            now: now
        )
        queue.upsert(
            PedroLiveActivity(
                id: "stack.vps1",
                stateKey: "recovered",
                kind: .stackRecovery,
                title: "VPS1",
                detail: "Online novamente",
                symbolName: "checkmark.circle.fill",
                priority: .recovery,
                createdAt: now.addingTimeInterval(5),
                expiresAt: now.addingTimeInterval(11)
            ),
            now: now.addingTimeInterval(5)
        )

        assert(queue.items.count == 1, "A state change should replace the previous activity")
        assert(queue.items[0].kind == .stackRecovery, "A recovered service should reopen as a short recovery activity")
    }

    static func testLiveActivityQueuePrunesExpiredItems() {
        let now = Date(timeIntervalSince1970: 1_783_166_400)
        var queue = PedroLiveActivityQueue()
        queue.upsert(
            PedroLiveActivity(
                id: "pulse",
                kind: .dailyPulse,
                title: "Status",
                detail: "Tudo operacional",
                symbolName: "checkmark.circle.fill",
                priority: .information,
                createdAt: now,
                expiresAt: now.addingTimeInterval(5)
            ),
            now: now
        )

        assert(queue.active(now: now.addingTimeInterval(6)) == nil, "Expired activities should leave the closed notch")
        assert(queue.items.isEmpty, "Expired activities should be pruned from the queue")
    }

    static func testStackIncidentTrackerRequiresConsecutiveOfflineReadings() {
        var tracker = PedroStackIncidentTracker(requiredOfflineReadings: 2)

        let first = tracker.transition(cardID: "core.pool-api", state: .offline)
        let second = tracker.transition(cardID: "core.pool-api", state: .offline)
        let recovered = tracker.transition(cardID: "core.pool-api", state: .active)

        assert(first == .none, "A single failed probe must not create a closed-notch incident")
        assert(second == .incident, "Two consecutive failed probes should confirm the incident")
        assert(recovered == .recovery, "A confirmed incident should produce a short recovery state")
    }

    static func testStackIncidentTrackerDoesNotRecoverAnUnreportedBlip() {
        var tracker = PedroStackIncidentTracker(requiredOfflineReadings: 2)

        _ = tracker.transition(cardID: "core.pool-api", state: .offline)
        let healthy = tracker.transition(cardID: "core.pool-api", state: .active)

        assert(healthy == .clear, "A transient failed probe should clear silently when the service is healthy")
    }
}
