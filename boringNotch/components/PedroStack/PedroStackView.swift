import SwiftUI

struct PedroStackView: View {
    @ObservedObject private var provider = PedroStackProvider.shared
    @State private var section: PedroStackSection = .cloud
    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var cards: [PedroStackCard] {
        provider.snapshot.cards(for: section)
    }

    var body: some View {
        VStack(spacing: 7) {
            sectionPicker

            if cards.isEmpty {
                VStack(spacing: 5) {
                    if provider.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: section.icon)
                            .font(.system(size: 20, weight: .semibold))
                    }
                    Text(provider.isLoading ? "Atualizando" : "Sem dados nesta seção")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    let width = cardWidth(in: geometry.size.width, count: cards.count)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 7) {
                            ForEach(cards) { card in
                                cardView(card)
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
        .onAppear {
            provider.start()
        }
        .onReceive(refreshTimer) { _ in provider.refresh() }
    }

    private var sectionPicker: some View {
        HStack(spacing: 2) {
            ForEach(PedroStackSection.allCases) { item in
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

    private func cardView(_ card: PedroStackCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(stateColor(card.state).opacity(0.17))
                    Image(systemName: card.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(stateColor(card.state))
                }
                .frame(width: 27, height: 27)

                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title)
                        .font(.system(size: 13.5, weight: .bold))
                        .lineLimit(1)
                    Text(card.subtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Circle()
                    .fill(stateColor(card.state))
                    .frame(width: 7, height: 7)
            }

            Spacer(minLength: 0)

            HStack(spacing: 5) {
                ForEach(Array(card.metrics.prefix(3).enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.displayLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(item.label)
                        Text(item.displayValue)
                            .font(.system(size: 21, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.68)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private func cardWidth(in availableWidth: CGFloat, count: Int) -> CGFloat {
        let visibleCount = max(1, min(3, count))
        return max(126, (availableWidth - CGFloat(visibleCount - 1) * 7) / CGFloat(visibleCount))
    }

    private func stateColor(_ state: PedroStackState) -> Color {
        switch state {
        case .active: .green
        case .warning: .yellow
        case .offline: .red
        case .unknown: .gray
        }
    }
}
