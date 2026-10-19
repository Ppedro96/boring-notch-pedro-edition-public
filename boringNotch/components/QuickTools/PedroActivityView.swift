import SwiftUI
import Defaults

struct PedroActivityView: View {
    @ObservedObject private var manager = PedroActivityManager.shared
    @ObservedObject private var transfers = PedroTransferService.shared
    @Default(.hideDotIntegration) private var hideDot
    @State private var filter = "dot"

    private var showingDot: Bool { !hideDot && filter == "dot" }

    private var filtered: [PedroActivityEvent] { manager.events.filter { showingDot ? $0.isDot : !$0.isDot } }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    if hideDot {
                        Text("Transferências").font(.system(size: 13, weight: .semibold))
                    } else {
                        Picker("Atividade", selection: $filter) {
                            Text("Dot").tag("dot")
                            Text("Transferencias").tag("transfer")
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 225)
                    }
                    Spacer(minLength: 0)
                    if !showingDot {
                        Button { transfers.chooseFiles() } label: { Image(systemName: "plus") }
                            .help("Copiar arquivos para uma pasta ou NAS montado")
                            .disabled(transfers.choosingFiles)
                    }
                    Button { manager.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Atualizar")
                    Button { manager.dismiss(filtered) } label: { Image(systemName: "checkmark.circle") }
                        .help("Limpar todos desta lista no Notch").disabled(filtered.isEmpty)
                }
                .buttonStyle(.plain).font(.system(size: 14)).frame(height: 25)
                if filtered.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: showingDot ? "circle.dotted" : "arrow.down.doc").font(.system(size: 24)).foregroundStyle(.secondary)
                        Text(showingDot ? "Nenhum aviso do Dot" : "Nenhuma transferencia").font(.system(size: 13, weight: .medium))
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(filtered) { event in
                                activityCard(event)
                                    .frame(width: max(1, (geometry.size.width - CGFloat(min(filtered.count, 3) - 1) * 8) / CGFloat(min(filtered.count, 3))),
                                           height: max(1, geometry.size.height - 31))
                            }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear { manager.refresh() }
    }

    private func activityCard(_ event: PedroActivityEvent) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: event.isDot ? "circle.dotted" : "arrow.down.doc").foregroundStyle(tint(event))
                Text(event.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Button { manager.dismiss([event]) } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                    .help("Dispensar no Notch")
            }
            Text(event.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack {
                Text(event.state.title).font(.system(size: 11, weight: .medium)).foregroundStyle(tint(event)).lineLimit(1)
                Spacer(minLength: 0)
                if let progress = event.progress {
                    Text("\(Int(progress))%").font(.system(size: 18, weight: .semibold)).monospacedDigit()
                }
                if transfers.activeIDs.contains(event.id) {
                    Button { transfers.cancel(event.id) } label: { Image(systemName: "stop.fill") }.help("Cancelar copia")
                }
                if event.isDot || event.safeURL != nil || event.outputPath != nil {
                    Button { manager.open(event) } label: { Image(systemName: "arrow.up.right") }.help("Abrir origem ou resultado")
                }
            }
            if let progress = event.progress {
                ProgressView(value: progress, total: 100).tint(tint(event)).frame(height: 3)
            }
        }
        .buttonStyle(.plain).padding(10)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.09)))
        .help(event.title + "\n" + event.detail + "\n" + event.updatedAt.formatted())
    }

    private func tint(_ event: PedroActivityEvent) -> Color {
        switch event.state {
        case .running: .cyan
        case .waiting: .orange
        case .completed: .green
        case .failed: .red
        case .cancelled, .unknown: .gray
        }
    }
}
