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
        testPrimarySSHCardUsesCorrectVPS1Identity()
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
            "Stack segments should remain Cloud, Core, Operação and Backup"
        )
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

    static func testPrimarySSHCardUsesCorrectVPS1Identity() {
        let result = PedroOpsSSHResult(
            hostID: "vps1",
            isReachable: true,
            output: """
            hostname=srv635058
            uptime=03:52:46 up 15 days, 17:05
            load=0.17 0.16 0.17
            memory=4.6GB / 33.7GB
            disk=0.1/0.4 TB 17% used
            temp=
            """,
            errorMessage: nil
        )

        let card = PedroStackProvider.vps1Card(
            from: result,
            now: Date(timeIntervalSince1970: 1_784_718_000)
        )

        assert(card.id == "cloud.vps1-hostinger-kvm2", "The primary host should replace the VPS1 feed card")
        assert(card.title == "VPS1", "Hostinger VM 635058 should be labeled VPS1")
        assert(card.state == .active, "A reachable VPS1 should be active")
        assert(card.subtitle == "Online via SSH", "The card should identify the live SSH source")
        assert(card.metrics.map(\.displayValue) == ["14%", "17%", "0.17"], "VPS1 should expose RAM, SSD and load")
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
