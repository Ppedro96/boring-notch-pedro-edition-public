import Foundation

@main
struct PedroStackProductionTests {
    static func main() {
        let cards = PedroStackProvider.loadProductionCards()
        precondition(cards.map(\.id) == ["local.pve02", "local.ct111", "local.ct112"])
        precondition(cards.allSatisfy { $0.state == .active || $0.state == .warning })
        precondition(cards.allSatisfy { $0.updatedAt != nil && $0.metrics.allSatisfy { $0.value != "--" } })
        for card in cards {
            print("\(card.title): \(card.subtitle), \(card.metrics.map { "\($0.label) \($0.displayValue)" }.joined(separator: ", "))")
        }
        print("PedroStackProductionTests live SSH passed")
    }
}
