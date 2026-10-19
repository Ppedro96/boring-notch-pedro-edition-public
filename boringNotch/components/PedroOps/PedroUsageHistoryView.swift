import SwiftUI
import AppKit

struct PedroUsageHistoryView: View {
    @ObservedObject private var reader = AgentUsageService.shared
    @State private var period = AgentPeriod.today
    @State private var detail = "Agentes"
    @AppStorage("pedroUsageUpdatePrices") private var updatesPrices = false
    private var usage: AgentPeriodUsage { reader.snapshot.usage(period) }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 9) {
                Picker("Período", selection: $period) {
                    Text("Hoje").tag(AgentPeriod.today)
                    Text("7 dias").tag(AgentPeriod.week)
                    Text("30 dias").tag(AgentPeriod.month)
                }.labelsHidden().pickerStyle(.segmented).controlSize(.small).frame(width: 190)
                Picker("Detalhes", selection: $detail) {
                    Text("Agentes").tag("Agentes")
                    Text("Modelos").tag("Modelos")
                    Text("Projetos").tag("Projetos")
                }.labelsHidden().pickerStyle(.segmented).controlSize(.small).frame(width: 215)
                Spacer(minLength: 0)
                Menu {
                    Toggle("Atualizar tabela de preços", isOn: $updatesPrices)
                    if let date = reader.pricesUpdated { Text("Tabela: \(date.formatted(date: .numeric, time: .omitted))") }
                    Button("Abrir OpenCode") {
                        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "ai.opencode.desktop") {
                            NSWorkspace.shared.open(app)
                        } else { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/OpenCode.app")) }
                    }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 20)
            }.frame(height: 21)
            if !reader.snapshot.loaded {
                HStack { ProgressView().controlSize(.small); Text("Lendo contadores locais…").font(.system(size: 12)) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if detail == "Agentes" {
                HStack(spacing: 7) {
                    ForEach(AgentProvider.allCases) { provider in
                        let totals = usage.byProvider[provider] ?? AgentTotals()
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: provider.symbol).foregroundStyle(.mint)
                                Text(provider.displayName).font(.system(size: 12, weight: .semibold))
                            }.font(.system(size: 12))
                            Text(tokens(totals.tokens.total)).font(.system(size: 17, weight: .semibold, design: .rounded))
                            HStack {
                                Text("tokens")
                                Spacer(minLength: 0)
                                Text("\(totals.requests) respostas")
                            }.font(.system(size: 8)).foregroundStyle(.secondary)
                            Text(totals.requests == 0 ? "Sem histórico no período" : "API equivalente: \(money(totals.cost))\(totals.unpriced > 0 ? " + sem preço" : "")")
                                .font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.7)
                            Text("Cache: \(tokens(totals.tokens.cacheRead)) · saída: \(tokens(totals.tokens.output))")
                                .font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
                        }.padding(6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            } else {
                let rows = detail == "Modelos" ? usage.models : usage.projects
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(rows) { row in
                            HStack {
                                Text(row.name).lineLimit(1).help(row.name)
                                Spacer()
                                Text(tokens(row.totals.tokens.total)).monospacedDigit().frame(width: 80, alignment: .trailing)
                                Text(row.totals.unpriced > 0 ? "Preço parcial" : money(row.totals.cost)).monospacedDigit().frame(width: 95, alignment: .trailing)
                            }.font(.system(size: 11)).padding(6)
                            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }.overlay { if rows.isEmpty { Text("Sem histórico no período").font(.system(size: 12)).foregroundStyle(.secondary) } }
            }
            Text("Valor estimado de API em US$ · separado da cobrança e dos limites da assinatura")
                .font(.system(size: 8)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }.onAppear { reader.syncWithPreferences() }
        .onChange(of: updatesPrices) { _, _ in reader.syncWithPreferences() }
    }

    private func tokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        return "\(count)"
    }
    private func money(_ value: Double) -> String { String(format: "US$ %.2f", value) }
}
