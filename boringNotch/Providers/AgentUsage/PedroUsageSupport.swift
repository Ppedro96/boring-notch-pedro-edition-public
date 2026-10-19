import Foundation

// Adapter for the GPL usage reader. Existing agent hooks own notifications.
enum NotchAgentSupport {
    static let idleTurn: TimeInterval = 120
    static let defaultLimitThreshold: Double = 90
    static func isEnabled() -> Bool { true }
    static func providers() -> [AgentProvider] { AgentProvider.allCases }
    static func dailyBudget() -> Double? { nil }
    static func finishMinimum() -> TimeInterval? { nil }
    static func limitThreshold() -> Double? { nil }
    static func updatesPrices() -> Bool { UserDefaults.standard.bool(forKey: "pedroUsageUpdatePrices") }
}
