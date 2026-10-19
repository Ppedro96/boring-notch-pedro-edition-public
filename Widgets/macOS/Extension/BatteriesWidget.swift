import SwiftUI
import WidgetKit

struct BatteriesEntry: TimelineEntry { let date: Date; let snapshot: BatterySnapshot }
struct BatteriesProvider: TimelineProvider {
    func placeholder(in context: Context) -> BatteriesEntry { .init(date: Date(), snapshot: .empty) }
    func getSnapshot(in context: Context, completion: @escaping (BatteriesEntry) -> Void) {
        completion(.init(date: Date(), snapshot: .read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<BatteriesEntry>) -> Void) {
        let now = Date(), snapshot = BatterySnapshot.read()
        completion(Timeline(entries: [.init(date: now, snapshot: snapshot),
            .init(date: now.addingTimeInterval(180), snapshot: snapshot)], policy: .after(now.addingTimeInterval(300))))
    }
}
struct BatteryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BatteriesEntry
    var body: some View {
        BatteriesPanel(snapshot: entry.snapshot, date: entry.date, compact: family == .systemSmall)
            .containerBackground(.background, for: .widget)
            .widgetURL(URL(string: "insightbatteries://open"))
    }
}
struct InsightBatteriesWidget: Widget {
    let kind = "InsightGalaxyBatteries"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BatteriesProvider()) { BatteryWidgetView(entry: $0) }
            .configurationDisplayName("Galaxy · Uma linha")
            .description("S23 Ultra, S25 Ultra, Z Fold6 e Tab S8+. O widget de Baterias da Apple continua independente.")
            .supportedFamilies([.systemMedium])
    }
}

struct CompactBatteriesWidget: Widget {
    let kind = "InsightGalaxyBatteriesCompact"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BatteriesProvider()) { BatteryWidgetView(entry: $0) }
            .configurationDisplayName("Galaxy · Duas linhas")
            .description("Os quatro Samsung em duas linhas, com ícones próprios.")
            .supportedFamilies([.systemSmall])
    }
}
@main struct BatteriesWidgetBundle: WidgetBundle {
    var body: some Widget { InsightBatteriesWidget(); CompactBatteriesWidget() }
}
