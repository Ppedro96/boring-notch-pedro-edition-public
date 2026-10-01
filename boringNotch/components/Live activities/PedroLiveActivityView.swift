import SwiftUI

struct PedroLiveActivityView: View {
    @EnvironmentObject private var vm: BoringViewModel

    let item: PedroLiveActivity

    private let wingWidth: CGFloat = 126

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: item.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 14, height: 14)

                    Text(item.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(width: wingWidth, alignment: .trailing)
                .padding(.trailing, 8)

                Rectangle()
                    .fill(.black)
                    .frame(width: max(0, vm.closedNotchSize.width - 20))

                HStack(spacing: 5) {
                    Circle()
                        .fill(tint)
                        .frame(width: 5, height: 5)

                    Text(detail(at: context.date))
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(width: wingWidth, alignment: .leading)
                .padding(.leading, 8)
            }
            .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(item.title), \(detail(at: context.date))")
        }
    }

    private var tint: Color {
        switch item.tint {
        case .blue: .cyan
        case .green: .green
        case .orange: .orange
        case .red: .red
        case .violet: .purple
        }
    }

    private func detail(at date: Date) -> String {
        guard let endAt = item.countdownEndAt else { return item.detail }
        let remaining = endAt.timeIntervalSince(date)

        if item.kind == .calendar {
            guard remaining > 0 else { return "Agora" }
            return "Em \(max(1, Int(ceil(remaining / 60)))) min"
        }

        guard remaining > 0 else { return "Concluído" }
        let totalSeconds = Int(ceil(remaining))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
