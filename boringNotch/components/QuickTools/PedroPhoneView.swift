import SwiftUI
import UniformTypeIdentifiers

struct PedroPhoneView: View {
    @ObservedObject private var manager = PedroPhoneManager.shared
    @EnvironmentObject private var vm: BoringViewModel
    @State private var fileDropTargeted = false
    @AppStorage("pedroSelectedPhoneV1") private var selectedID = ""
    private var phone: PedroPhone? { manager.phones.first { $0.id == selectedID } ?? manager.phones.first }

    var body: some View {
        VStack(spacing: 6) {
            if manager.phones.isEmpty {
                HStack {
                    Text("Celulares").font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 0)
                    phoneTools
                }.frame(height: 30)
            } else {
                deviceTabs
            }
            if let phone {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            Circle().fill(phone.isConnected ? Color.green : .gray).frame(width: 6, height: 6)
                            Text(!phone.paired ? "Nao pareado" : phone.reachable ? phone.via.map { "Via " + $0 } ?? "Conectado" : "Desconectado").font(.system(size: 11))
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(phone.batteryPercentage.map(String.init) ?? "--").font(.system(size: 34, weight: .semibold)).monospacedDigit()
                            Text("%").font(.system(size: 17)).foregroundStyle(.secondary)
                            if phone.isCharging { Image(systemName: "bolt.fill").foregroundStyle(.green) }
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: 15) {
                            Button { manager.ring(phone) } label: { Image(systemName: "bell.and.waves.left.and.right") }
                                .help("Tocar \(phone.name)").disabled(!phone.isConnected || !phone.canRing)
                            Button { manager.shareLink(phone) } label: { Image(systemName: "link") }
                                .help("Enviar link copiado").disabled(!phone.isConnected || !phone.canShare)
                            Button { manager.shareFile(phone) } label: { Image(systemName: "square.and.arrow.up") }
                                .help("Enviar arquivos para \(phone.name)").disabled(!phone.isConnected || !phone.canShare || !phone.canShareFiles)
                        }.font(.system(size: 16)).disabled(manager.isActing)
                    }.frame(width: 145, alignment: .leading).padding(.vertical, 4)
                    Divider().overlay(Color.white.opacity(0.1))
                    let notifications = manager.notifications(for: phone)
                    VStack(spacing: 4) {
                        HStack(spacing: 10) {
                            Text(manager.showsTransfers ? "Arquivos" : manager.feedback ?? "Notificacoes").font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary).lineLimit(1).help(manager.feedback ?? "Notificacoes")
                            Spacer(minLength: 0)
                            Button { manager.showsTransfers.toggle() } label: {
                                Image(systemName: manager.showsTransfers ? "bell" : "arrow.up.doc")
                            }.help(manager.showsTransfers ? "Ver notificacoes" : "Ver envios de arquivos")
                            phoneTools
                            if manager.showsTransfers {
                                Button { manager.clearFinishedTransfers() } label: { Image(systemName: "checkmark.circle") }
                                    .help("Limpar envios finalizados").disabled(!manager.transfers.contains { $0.update.isFinished })
                            } else {
                                Button { manager.dismiss(notifications, phone: phone) } label: { Image(systemName: "checkmark.circle") }
                                    .help("Limpar no Notch; manter no celular").disabled(notifications.isEmpty)
                            }
                        }
                        if manager.showsTransfers {
                            transferPanel(phone)
                        } else if notifications.isEmpty {
                            Text(!phone.isConnected ? "Sem conexao" : phone.notificationsAvailable ? "Nenhum aviso" : "Notificacoes nao habilitadas")
                                .font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ScrollView(.vertical) {
                                LazyVStack(alignment: .leading, spacing: 7) {
                                    ForEach(notifications) { item in
                                        HStack(alignment: .top, spacing: 8) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(item.app + " · " + item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                                Text(item.text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                                            }.frame(maxWidth: .infinity, alignment: .leading)
                                            Button { manager.dismiss([item], phone: phone) } label: { Image(systemName: "xmark").font(.system(size: 10)) }.help("Dispensar no Notch")
                                        }.help(item.title + "\n" + item.text)
                                    }
                                }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "iphone").font(.system(size: 25)).foregroundStyle(.secondary)
                    Text(manager.error ?? (manager.isRefreshing ? "Buscando celulares" : "Nenhum celular pareado"))
                        .font(.system(size: 13)).lineLimit(2).multilineTextAlignment(.center)
                    Button("Abrir KDE Connect") { manager.openKDE() }.font(.system(size: 12))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.buttonStyle(.plain)
        .contentShape(Rectangle())
        .overlay {
            RoundedRectangle(cornerRadius: 5).strokeBorder(Color.green.opacity(fileDropTargeted ? 0.7 : 0), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $fileDropTargeted) { providers in
            receiveFiles(providers)
        }
        .onChange(of: fileDropTargeted) { _, targeted in vm.dragDetectorTargeting = targeted }
        .onAppear { manager.appear() }
        .onDisappear { manager.disappear() }
    }

    private var deviceTabs: some View {
        GeometryReader { geometry in
            let visibleCount = min(4, manager.phones.count)
            let tabWidth = max(118, (geometry.size.width - CGFloat(visibleCount - 1) * 4) / CGFloat(visibleCount))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(manager.phones) { item in
                        PedroPhoneTab(phone: item, isSelected: phone?.id == item.id) {
                            selectedID = item.id
                        }
                        .frame(width: tabWidth, height: 30)
                        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                            selectedID = item.id
                            return receiveFiles(providers)
                        }
                    }
                }
            }
        }.frame(height: 30)
    }

    private func receiveFiles(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        vm.dropEvent = true
        manager.prepareFiles(providers: providers)
        return true
    }

    @ViewBuilder
    private func transferPanel(_ phone: PedroPhone) -> some View {
        if !manager.pendingFiles.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(manager.pendingFiles.count == 1 ? manager.pendingFiles[0].lastPathComponent : "\(manager.pendingFiles.count) arquivos")
                    .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    .help(manager.pendingFiles.map(\.lastPathComponent).joined(separator: "\n"))
                Text("Para " + phone.tabName + (phone.via.map { " · Via " + $0 } ?? ""))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                HStack {
                    Button { manager.sendPending(to: phone) } label: { Label("Enviar", systemImage: "paperplane.fill") }
                        .foregroundStyle(.green).disabled(!phone.isConnected || !phone.canShareFiles || !phone.canShare)
                    Spacer(minLength: 0)
                    Button { manager.pendingFiles = [] } label: { Image(systemName: "xmark") }.help("Descartar selecao")
                }.font(.system(size: 13, weight: .medium))
            }.padding(.vertical, 4).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else if manager.transfers.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "arrow.up.doc").font(.system(size: 22)).foregroundStyle(.secondary)
                Button { manager.shareFile(phone) } label: { Label("Enviar arquivos", systemImage: "plus") }
                    .font(.system(size: 13)).disabled(!phone.isConnected || !phone.canShareFiles || !phone.canShare)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 8) {
                    ForEach(manager.transfers.reversed()) { job in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                Image(systemName: transferIcon(job.update.phase)).foregroundStyle(transferColor(job.update.phase))
                                Text(job.source.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Spacer(minLength: 0)
                                if let percentage = job.update.percentage {
                                    Text("\(Int(percentage))%").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                                }
                                if job.update.canCancel {
                                    Button { manager.cancelTransfer(job.id) } label: { Image(systemName: "stop.fill").font(.system(size: 11)) }
                                        .help("Cancelar copia")
                                }
                            }
                            HStack(spacing: 4) {
                                Text(job.deviceName + " · " + job.update.title).lineLimit(1)
                                Spacer(minLength: 0)
                                if let bytes = job.update.bytes {
                                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).fixedSize()
                                }
                            }.font(.system(size: 11)).foregroundStyle(.secondary)
                            if !job.update.isFinished {
                                if let percentage = job.update.percentage { ProgressView(value: percentage, total: 100).tint(.green) }
                                else { ProgressView().controlSize(.mini).frame(height: 4) }
                            }
                        }.help(job.update.detail ?? job.update.title)
                    }
                }.padding(.vertical, 3)
            }
        }
    }

    private func transferIcon(_ phase: String) -> String {
        switch phase {
        case "completed": "checkmark.circle.fill"
        case "failed", "unknown": "exclamationmark.circle"
        case "cancelled": "stop.circle"
        case "submitted": "paperplane"
        default: "arrow.up.doc"
        }
    }
    private func transferColor(_ phase: String) -> Color {
        switch phase {
        case "completed": .green
        case "failed": .red
        case "unknown": .orange
        default: .secondary
        }
    }

    private var phoneTools: some View {
        HStack(spacing: 10) {
            if let error = manager.error {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(error)
            }
            Menu {
                ForEach(manager.filterApps, id: \.self) { app in
                    Toggle(app, isOn: Binding(get: { manager.showsApp(app) }, set: { manager.setShowsApp(app, $0) }))
                }
            } label: { Image(systemName: "line.3.horizontal.decrease") }
                .menuStyle(.borderlessButton).frame(width: 20).help("Filtrar aplicativos").disabled(manager.filterApps.isEmpty)
            Button { manager.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("Atualizar").disabled(manager.isRefreshing)
            Button { manager.openKDE() } label: { Image(systemName: "gearshape") }
                .help("Abrir KDE Connect e parear aparelhos")
        }.font(.system(size: 13)).fixedSize()
    }
}

private struct PedroPhoneTab: View {
    let phone: PedroPhone
    let isSelected: Bool
    let select: () -> Void

    private var batteryColor: Color {
        guard let charge = phone.batteryPercentage else { return .secondary }
        if charge <= 15 { return .red }
        if charge <= 30 { return .orange }
        return phone.isCharging ? .green : .primary
    }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 4) {
                Text(phone.tabName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(phone.batteryText)
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(batteryColor).fixedSize()
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.green)
                    .opacity(phone.isCharging ? 1 : 0).frame(width: 7)
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(isSelected ? 0.14 : 0.045), in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.white.opacity(isSelected ? 0.22 : 0), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(phone.name)
        .accessibilityValue(phone.statusDescription)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(phone.name + " - " + phone.statusDescription)
    }
}
