import SwiftUI

struct PedroProxmoxView: View {
    @ObservedObject private var provider = PedroProxmoxProvider.shared
    @State private var section: PedroProxmoxSection = .host
    private let refreshTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var guests: [PedroProxmoxGuest] {
        switch section {
        case .host: []
        case .containers: provider.snapshot.containers
        case .virtualMachines: provider.snapshot.virtualMachines
        }
    }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                nodePicker
                    .frame(width: 182)
                sectionPicker
            }

            ZStack(alignment: .topTrailing) {
                if let error = provider.snapshot.errorMessage, provider.snapshot.host == nil {
                    errorState(error)
                } else if section == .host {
                    hostContent
                } else if guests.isEmpty {
                    emptyState
                } else {
                    guestContent
                }

                if provider.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.top, 4)
                        .padding(.trailing, 5)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            provider.start()
        }
        .onReceive(refreshTimer) { _ in provider.refresh() }
        .onDisappear { provider.stop() }
    }

    private var nodePicker: some View {
        HStack(spacing: 2) {
            ForEach(PedroProxmoxNode.allCases) { node in
                Button {
                    provider.select(node)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "server.rack")
                        Text(node.title)
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(provider.selectedNode == node ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(provider.selectedNode == node ? Color.white.opacity(0.13) : .clear)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Proxmox \(node.title)")
                .help(node.target.hostAlias)
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
    }

    private var sectionPicker: some View {
        HStack(spacing: 2) {
            ForEach(PedroProxmoxSection.allCases) { item in
                Button {
                    section = item
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.icon)
                        Text(item.title)
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(section == item ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(section == item ? Color.white.opacity(0.13) : .clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    private var hostContent: some View {
        if let host = provider.snapshot.host {
            GeometryReader { geometry in
                let cards = hostCards(host)
                let width = cardWidth(in: geometry.size.width, count: cards.count, visibleLimit: 4)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 7) {
                        ForEach(cards) { card in
                            PedroProxmoxHostCardView(card: card)
                                .frame(width: width, height: geometry.size.height)
                        }
                    }
                }
            }
        } else {
            emptyState
        }
    }

    private var guestContent: some View {
        GeometryReader { geometry in
            let width = cardWidth(in: geometry.size.width, count: guests.count)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 7) {
                    ForEach(guests) { guest in
                        PedroProxmoxGuestCardView(guest: guest)
                            .frame(width: width, height: geometry.size.height)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 5) {
            Image(systemName: section.icon)
                .font(.system(size: 21, weight: .semibold))
            Text(provider.isLoading && provider.snapshot.host == nil ? "Carregando \(provider.selectedNode.title)" : section == .virtualMachines ? "Nenhuma VM neste nó" : section == .containers ? "Nenhum CT neste nó" : "Sem dados nesta guia")
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.yellow)
            Text("\(provider.selectedNode.title) indisponível")
                .font(.system(size: 13, weight: .bold))
            Text(message)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func hostCards(_ host: PedroProxmoxHost) -> [PedroProxmoxHostCard] {
        [
            PedroProxmoxHostCard(
                id: "cpu",
                title: "CPU",
                value: "\(host.cpuUsagePercent)%",
                detail: "\(host.cpuCores)c/\(host.cpuThreads)t · \(temperatureLabel(host.cpuTemperature))",
                icon: "cpu.fill",
                tint: .green,
                help: "\(host.name) · \(host.cpuModel) · \(host.version)"
            ),
            PedroProxmoxHostCard(
                id: "ram",
                title: "RAM",
                value: "\(host.memoryUsagePercent)%",
                detail: host.memoryLabel,
                icon: "memorychip.fill",
                tint: .blue
            ),
            PedroProxmoxHostCard(
                id: "ssd",
                title: "SSD",
                value: "\(host.storageUsagePercent)%",
                detail: host.storageLabel,
                icon: "internaldrive.fill",
                tint: .orange
            ),
            PedroProxmoxHostCard(
                id: "gpu",
                title: "GPU",
                value: host.gpuName ?? "--",
                detail: host.gpuDriver == "vfio-pci"
                    ? (host.gpuGuest ?? "Dedicada a uma VM")
                    : [host.gpuMemoryGB.map { "\($0) GB" }, host.gpuTemperature.map { "\($0)°C" }].compactMap { $0 }.joined(separator: " · "),
                icon: "display",
                tint: .mint,
                stateColor: host.gpuDriver == "vfio-pci" ? .mint : (host.gpuTemperature == nil ? .yellow : .green),
                help: host.gpuDriver == "vfio-pci" ? "Passthrough: o host não tem acesso aos sensores da GPU. \(host.gpuMemoryGB ?? 0) GB de VRAM." : "Sensores da GPU no host"
            )
        ]
    }

    private func temperatureLabel(_ value: Int?) -> String {
        value.map { "\($0)°C" } ?? "--°C"
    }

    private func cardWidth(in availableWidth: CGFloat, count: Int, visibleLimit: Int = 3) -> CGFloat {
        let visibleCount = max(1, min(visibleLimit, count))
        return max(104, (availableWidth - CGFloat(visibleCount - 1) * 7) / CGFloat(visibleCount))
    }
}

private struct PedroProxmoxHostCard: Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let icon: String
    let tint: Color
    var stateColor: Color = .green
    var help: String = "Leitura atual do host"
}

private struct PedroProxmoxHostCardView: View {
    let card: PedroProxmoxHostCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: card.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(card.tint)
                    .frame(width: 27, height: 27)
                    .background(card.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                Text(card.title)
                    .font(.system(size: 13.5, weight: .bold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Circle()
                    .fill(card.stateColor)
                    .frame(width: 7, height: 7)
                    .help(card.help)
            }

            Spacer(minLength: 0)

            Text(card.value)
                .font(.system(size: card.id == "gpu" ? 18 : 27, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(card.id == "gpu" ? 0.86 : 0.72)
            Text(card.detail)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct PedroProxmoxGuestCardView: View {
    let guest: PedroProxmoxGuest

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: guest.kind == .container ? "shippingbox.fill" : "macwindow.on.rectangle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(stateColor)
                    .frame(width: 27, height: 27)
                    .background(stateColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))

                VStack(alignment: .leading, spacing: 1) {
                    Text(guest.name)
                        .font(.system(size: 13.5, weight: .bold))
                        .lineLimit(1)
                    Text("\(guest.identityLabel) · \(guest.status.label)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
                Circle()
                    .fill(stateColor)
                    .frame(width: 7, height: 7)
            }

            Spacer(minLength: 0)

            HStack(spacing: 5) {
                metric(label: "CPU", value: guest.cpuLabel)
                metric(label: guest.kind == .virtualMachine ? "RAM host" : "RAM", value: guest.memoryValue)
                metric(label: guest.kind == .virtualMachine ? "Disco virtual" : "SSD", value: guest.storageValue)
            }

            Text(guest.kind == .virtualMachine ? "\(Int((guest.memoryTotalBytes / 1_000_000_000).rounded())) GB de RAM configurada" : "RAM \(guest.memoryLabel)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private func metric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stateColor: Color {
        switch guest.status {
        case .running: .green
        case .stopped: .red
        case .unknown: .yellow
        }
    }
}
