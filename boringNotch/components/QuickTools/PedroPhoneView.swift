import SwiftUI
import UniformTypeIdentifiers

struct PedroPhoneView: View {
    @ObservedObject private var manager = PedroPhoneManager.shared
    @EnvironmentObject private var vm: BoringViewModel
    @State private var fileDropTargeted = false
    @AppStorage("pedroPhoneShowsAppsV1") private var showingApps = false
    @State private var replying: PedroPhoneNotification?
    @AppStorage("pedroSelectedPhoneV1") private var selectedID = ""
    private var phone: PedroPhone? { manager.phones.first { $0.id == selectedID } ?? manager.phones.first }

    var body: some View {
        VStack(spacing: 7) {
            if !manager.phones.isEmpty { deviceTabs }
            if let phone {
                HStack(alignment: .top, spacing: 10) {
                    PedroPhoneMediaView(phone: phone).frame(width: 180)
                    VStack(spacing: 5) {
                        contentHeader(phone)
                        Group {
                            if let replying {
                                PedroPhoneReplyComposer(notification: replying, phone: phone) { self.replying = nil }
                            } else if showingApps {
                                PedroAndroidAppsView(phone: phone)
                            } else if manager.showsTransfers {
                                transferPanel(phone)
                            } else {
                                notificationList(phone)
                            }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .bottom) {
                        if let feedback = manager.feedback, replying == nil {
                            HStack(spacing: 6) {
                                Text(feedback).font(.system(size: 10)).lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button { manager.dismissFeedback() } label: {
                                    Image(systemName: "xmark").font(.system(size: 10))
                                        .frame(width: 22, height: 24).contentShape(Rectangle())
                                }.help("Dispensar aviso").accessibilityLabel("Dispensar aviso")
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .frame(maxWidth: .infinity).frame(height: 38)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .help(feedback).padding(6)
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 7) {
                    HStack { Text("Celulares").font(.system(size: 12, weight: .semibold)); Spacer(); phoneTools }
                    Spacer(minLength: 0)
                    Image(systemName: "iphone").font(.system(size: 22)).foregroundStyle(.secondary)
                    Text(manager.error ?? "Nenhum celular conectado").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Abrir KDE Connect") { manager.openKDE() }.font(.system(size: 12))
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.buttonStyle(.plain)
        .contentShape(Rectangle())
        .overlay {
            RoundedRectangle(cornerRadius: 5).strokeBorder(Color.green.opacity(fileDropTargeted ? 0.7 : 0), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $fileDropTargeted) { providers in receiveFiles(providers) }
        .onChange(of: fileDropTargeted) { _, targeted in vm.dragDetectorTargeting = targeted }
        .onChange(of: phone?.id) { _, _ in replying = nil }
        .onAppear { manager.appear() }
        .onDisappear { manager.disappear() }
    }

    private func contentHeader(_ phone: PedroPhone) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Text(replying.map { "Responder · " + $0.app } ?? (showingApps ? "Apps em janelas" : manager.showsTransfers ? "Arquivos" : "Notificações"))
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if replying == nil, !manager.showsTransfers, !manager.notifications(for: phone).isEmpty {
                    Text(String(manager.notifications(for: phone).count))
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
            }.layoutPriority(1)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Circle().fill(phone.isConnected ? Color.green : .gray).frame(width: 5, height: 5)
                Text(replying != nil ? phone.tabName : (!phone.paired ? "Não pareado" : !phone.reachable ? "Desconectado" : phone.via.map { "Via " + $0 } ?? "Mac"))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.tail).help(phone.statusDescription)
                if let error = manager.error {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(.orange).help(error)
                }
            }.frame(maxWidth: 110, alignment: .trailing).layoutPriority(-1)
            HStack(spacing: 7) {
                if replying != nil {
                    Button { replying = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                            .frame(width: 26, height: 24).contentShape(Rectangle())
                    }.help("Fechar resposta").accessibilityLabel("Fechar resposta")
                } else {
                    Button { showingApps = false; manager.showsTransfers.toggle() } label: {
                        Image(systemName: manager.showsTransfers ? "bell" : "arrow.up.doc")
                            .font(.system(size: 12)).frame(width: 26, height: 24).contentShape(Rectangle())
                    }
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
                    .help(manager.showsTransfers ? "Ver notificações" : "Ver envios de arquivos")
                    .accessibilityLabel(manager.showsTransfers ? "Ver notificações" : "Ver arquivos")
                    Button { showingApps.toggle(); manager.showsTransfers = false } label: {
                        Image(systemName: showingApps ? "bell" : "macwindow").font(.system(size: 12)).frame(width: 26, height: 24)
                    }.help(showingApps ? "Ver notificações" : "Abrir apps em janelas próprias").accessibilityLabel("Apps em janelas")
                    phoneTools
                }
            }.fixedSize(horizontal: true, vertical: true)
        }.frame(height: 24)
    }

    @ViewBuilder private func notificationList(_ phone: PedroPhone) -> some View {
        let notifications = manager.notifications(for: phone)
        if notifications.isEmpty {
            Text(!phone.isConnected ? "Sem conexão com o aparelho" : phone.notificationsAvailable ? "Nenhuma nova notificação" : "Notificações não habilitadas no aparelho")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(notifications) { item in
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.app + " · " + item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                if !item.text.isEmpty {
                                    Text(item.text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if item.canReply {
                                Button { replying = item } label: {
                                    Image(systemName: "arrowshape.turn.up.left").font(.system(size: 12)).frame(width: 24, height: 24).contentShape(Rectangle())
                                }.help("Responder a " + item.title).disabled(manager.isActing)
                            }
                            Button { manager.dismiss([item], phone: phone) } label: {
                                Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 24, height: 24).contentShape(Rectangle())
                            }.help("Dispensar só no Notch")
                        }.padding(.horizontal, 1).padding(.vertical, 4)
                        .help(item.title + "\n" + item.text)
                    }
                }
            }
        }
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
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(manager.pendingFiles.count == 1 ? manager.pendingFiles[0].lastPathComponent : "\(manager.pendingFiles.count) arquivos")
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                        .help(manager.pendingFiles.map(\.lastPathComponent).joined(separator: "\n"))
                    Text("Para " + phone.tabName + (phone.via.map { " · Via " + $0 } ?? ""))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).layoutPriority(-1)
                Button { manager.sendPending(to: phone) } label: { Label("Enviar", systemImage: "paperplane.fill") }
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.green).fixedSize()
                    .disabled(!phone.isConnected || !phone.canShareFiles || !phone.canShare)
                Button { manager.pendingFiles = [] } label: {
                    Image(systemName: "xmark").font(.system(size: 10)).frame(width: 24, height: 24).contentShape(Rectangle())
                }.help("Descartar seleção").fixedSize()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
                                    Button { manager.cancelTransfer(job.id) } label: {
                                        Image(systemName: "stop.fill").font(.system(size: 11)).frame(width: 24, height: 24).contentShape(Rectangle())
                                    }.fixedSize()
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
        Menu {
            if let phone {
                Button { manager.openScreen(phone) } label: { Label("Abrir tela (scrcpy)", systemImage: "rectangle.on.rectangle") }
                    .disabled(manager.isActing)
                Divider()
                Button { manager.shareFile(phone) } label: { Label("Enviar arquivos…", systemImage: "square.and.arrow.up") }
                    .disabled(!phone.isConnected || !phone.canShare || manager.isActing)
                Button { manager.shareLink(phone) } label: { Label("Enviar link copiado", systemImage: "link") }
                    .disabled(!phone.isConnected || !phone.canShare || manager.isActing)
                Button { manager.ring(phone) } label: { Label("Localizar aparelho", systemImage: "bell.and.waves.left.and.right") }
                    .disabled(!phone.isConnected || !phone.canRing || manager.isActing)
                Divider()
                Menu("Filtrar aplicativos") {
                    ForEach(manager.filterApps, id: \.self) { app in
                        Toggle(app, isOn: Binding(get: { manager.showsApp(app) }, set: { manager.setShowsApp(app, $0) }))
                    }
                }.disabled(manager.filterApps.isEmpty)
                Button("Limpar notificações no Notch") { manager.dismiss(manager.notifications(for: phone), phone: phone) }
                    .disabled(manager.notifications(for: phone).isEmpty)
                if !manager.transfers.isEmpty { Button("Limpar envios finalizados") { manager.clearFinishedTransfers() } }
                Divider()
            }
            Menu(manager.nativeNotificationsEnabled ? "Avisos do macOS · ativos" : "Avisos do macOS · desativados") {
                Button("Testar aviso") { PedroPhoneNativeNotifications.shared.testNotification() }
                    .disabled(!manager.nativeNotificationsEnabled)
                Button("Ajustes de notificações") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                }
            }
            Button("Atualizar conexão") { manager.refresh() }
            Button("Abrir KDE Connect") { manager.openKDE() }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium))
                .frame(width: 16, height: 16)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).controlSize(.small)
        .frame(width: 26, height: 24).fixedSize()
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
        .help("Mais ações do celular").accessibilityLabel("Mais ações do celular")
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
