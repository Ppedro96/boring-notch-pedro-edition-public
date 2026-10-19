import Foundation

enum PedroClaudeLocalFallback {
    static func summary(now: Date = Date(), home: String = PedroOpsUserHome.realPath) -> PedroOpsUsageWindowSummary? {
        let url = AgentClaudeAppUsage.historyURL(home: URL(fileURLWithPath: home))
        guard let data = try? Data(contentsOf: url),
              let samples = AgentClaudeAppUsage.samples(from: data),
              let limits = AgentClaudeAppUsage.limits(from: samples, now: now) else { return nil }
        let five = limits.windows.first { $0.scope == nil && $0.minutes == 300 }
        let week = limits.windows.first { $0.scope == nil && $0.minutes == 10_080 }
        let stale = now.timeIntervalSince(limits.observedAt) > AgentClaudeAppUsage.freshness
        func reset(_ date: Date?) -> String {
            date.map { "Reset estimado: " + $0.formatted(date: .omitted, time: .shortened) } ?? "Reset não informado"
        }
        return PedroOpsUsageWindowSummary(lastFiveHoursTokens: nil, lastWeekTokens: nil, sessionCount: nil,
            source: "Claude Desktop local · " + limits.observedAt.formatted(date: .omitted, time: .shortened),
            lastFiveHoursDisplay: five.map { "\(Int($0.usedPercent))%" }, lastWeekDisplay: week.map { "\(Int($0.usedPercent))%" },
            lastFiveHoursDetail: five.map { reset($0.resetsAt) } ?? "Sem janela",
            lastWeekDetail: week.map { reset($0.resetsAt) } ?? "Sem janela",
            lastFiveHoursProgressPercent: five.map { Int($0.usedPercent) },
            lastWeekProgressPercent: week.map { Int($0.usedPercent) }, isStale: stale)
        // Estimated resets stay descriptive: do not zero a quota from an inferred date.
    }
}
