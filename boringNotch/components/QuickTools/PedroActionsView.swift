import SwiftUI

struct PedroActionsView: View {
    @ObservedObject private var manager = PedroMoonlightManager.shared
    @AppStorage("pedroActionsSectionV1") private var section = "moonlight"

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 6) {
                HStack {
                    Picker("Controle de computadores", selection: $section) {
                        Text("Moonlight").tag("moonlight")
                        Text("Mesa contínua").tag("desk")
                    }.pickerStyle(.segmented).labelsHidden().frame(width: min(310, geometry.size.width))
                    Spacer(minLength: 0)
                }.frame(height: 26)
                Group {
                    if section == "desk" { PedroContinuousDeskView() }
                    else { moonlight }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }.clipped()
    }
    private var moonlight: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Text("Moonlight").font(.system(size: 14, weight: .semibold))
                Text("\(manager.hosts.count)").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let feedback = manager.feedback {
                    Text(feedback)
                        .font(.system(size: 12))
                        .foregroundStyle(manager.isError ? .orange : .secondary)
                        .lineLimit(1)
                        .help(feedback)
                }
                Button { manager.openMoonlight() } label: {
                    Image(systemName: "arrow.up.forward.app").frame(width: 27, height: 27)
                }
                .help("Abrir Moonlight e gerenciar máquinas")
                Button { manager.refresh() } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 27, height: 27)
                }
                .help("Atualizar máquinas pareadas")
            }
            .frame(height: 27)
            .buttonStyle(.plain)

            GeometryReader { geometry in
                if manager.hosts.isEmpty {
                    VStack(spacing: 7) {
                        Image(systemName: "display.trianglebadge.exclamationmark").font(.system(size: 24))
                        Text(manager.applicationURL == nil ? "Moonlight não instalado" : "Nenhuma máquina pareada")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let width = PedroOpsCardLayout.cardWidth(cardCount: manager.hosts.count,
                                                            availableWidth: geometry.size.width, spacing: 7)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(manager.hosts) { host in
                                hostButton(host)
                                    .frame(width: width, height: geometry.size.height)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { manager.refresh() }
    }

    private func hostButton(_ host: PedroMoonlightHost) -> some View {
        Button { manager.launch(host, app: host.preferredApp) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: host.symbol)
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(host.symbol == "display" ? .cyan : .mint)
                    Spacer(minLength: 0)
                    Image(systemName: manager.launchingID == host.id ? "hourglass" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(host.name)
                    .font(.system(size: 19, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.75)
                HStack(spacing: 4) {
                    Text(host.preferredApp.isEmpty ? "Sem aplicativo salvo" : host.preferredApp)
                    Spacer(minLength: 0)
                    Text(host.address)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(host.apps.isEmpty || manager.launchingID != nil)
        .help("Conectar a \(host.name) · \(host.preferredApp)")
        .contextMenu {
            ForEach(host.apps, id: \.self) { app in
                Button("Abrir \(app)") { manager.launch(host, app: app) }
            }
            Divider()
            Menu("Qualidade") {
                ForEach(PedroMoonlightProfile.allCases, id: \.rawValue) { profile in
                    Button {
                        manager.setProfile(profile, for: host)
                    } label: {
                        if manager.profile(for: host) == profile {
                            Label(profile.title, systemImage: "checkmark")
                        } else {
                            Text(profile.title)
                        }
                    }
                }
            }
        }
    }
}
