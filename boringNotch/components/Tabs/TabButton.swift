//
//  TabButton.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-24.
//

import SwiftUI

struct TabButton: View {
    let label: String
    let icon: String
    let selected: Bool
    let onClick: () -> Void
    
    var body: some View {
        Button(action: onClick) {
            InsightSemanticIcon(name: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 25, height: 25)
                .contentShape(Capsule())
        }
        .accessibilityLabel(Text(label))
        .buttonStyle(PlainButtonStyle())
    }
}

#Preview {
    TabButton(label: "Home", icon: "tray.fill", selected: true) {
        print("Tapped")
    }
}

/// Shared functional icons; custom marks inherit the same tint as native symbols.
struct InsightSemanticIcon: View {
    let name: String
    var body: some View {
        if name == "insight.alienware" {
            InsightAlienwareMark().fill(style: FillStyle(eoFill: true))
                .frame(width: 16, height: 17)
        } else {
            Image(systemName: name)
        }
    }
}

/// Alienware mark from Simple Icons (CC0); brand rights remain with Dell.
/// https://github.com/simple-icons/simple-icons/blob/a15887b787e9eb9cdc3ddfd1a13b1b0228d2bf6c/icons/alienware.svg
private struct InsightAlienwareMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 20.38200, y: 9.40540))
        path.addCurve(to: CGPoint(x: 20.12250, y: 7.39460), control1: CGPoint(x: 20.31710, y: 8.75680), control2: CGPoint(x: 20.25230, y: 8.04320))
        path.addCurve(to: CGPoint(x: 19.60360, y: 5.44860), control1: CGPoint(x: 19.99280, y: 6.74590), control2: CGPoint(x: 19.86310, y: 6.09730))
        path.addCurve(to: CGPoint(x: 19.21440, y: 4.54060), control1: CGPoint(x: 19.47390, y: 5.12430), control2: CGPoint(x: 19.34410, y: 4.80000))
        path.addCurve(to: CGPoint(x: 18.76040, y: 3.63240), control1: CGPoint(x: 19.08470, y: 4.21620), control2: CGPoint(x: 18.89010, y: 3.95680))
        path.addCurve(to: CGPoint(x: 18.17660, y: 2.78920), control1: CGPoint(x: 18.56580, y: 3.37300), control2: CGPoint(x: 18.37120, y: 3.04860))
        path.addCurve(to: CGPoint(x: 17.46310, y: 2.07570), control1: CGPoint(x: 17.98200, y: 2.52970), control2: CGPoint(x: 17.72260, y: 2.27020))
        path.addCurve(to: CGPoint(x: 15.90630, y: 0.97300), control1: CGPoint(x: 17.00910, y: 1.68650), control2: CGPoint(x: 16.49010, y: 1.29730))
        path.addCurve(to: CGPoint(x: 14.02530, y: 0.25950), control1: CGPoint(x: 15.32250, y: 0.64860), control2: CGPoint(x: 14.67390, y: 0.38920))
        path.addCurve(to: CGPoint(x: 12.01430, y: 0.00000), control1: CGPoint(x: 13.37650, y: 0.06490), control2: CGPoint(x: 12.72780, y: 0.00000))
        path.addCurve(to: CGPoint(x: 10.00350, y: 0.25950), control1: CGPoint(x: 11.30080, y: 0.00000), control2: CGPoint(x: 10.65220, y: 0.06490))
        path.addCurve(to: CGPoint(x: 8.18740, y: 0.97300), control1: CGPoint(x: 9.35500, y: 0.38920), control2: CGPoint(x: 8.77120, y: 0.64860))
        path.addCurve(to: CGPoint(x: 6.50090, y: 2.14050), control1: CGPoint(x: 7.53870, y: 1.29730), control2: CGPoint(x: 7.01980, y: 1.68650))
        path.addCurve(to: CGPoint(x: 5.78740, y: 2.85410), control1: CGPoint(x: 6.24140, y: 2.33510), control2: CGPoint(x: 6.04690, y: 2.59450))
        path.addLine(to: CGPoint(x: 5.20360, y: 3.63240))
        path.addCurve(to: CGPoint(x: 4.74960, y: 4.54050), control1: CGPoint(x: 5.07390, y: 3.95680), control2: CGPoint(x: 4.87930, y: 4.21620))
        path.addLine(to: CGPoint(x: 4.36040, y: 5.51350))
        path.addCurve(to: CGPoint(x: 3.84140, y: 7.45950), control1: CGPoint(x: 4.16580, y: 6.16220), control2: CGPoint(x: 3.97120, y: 6.81080))
        path.addCurve(to: CGPoint(x: 3.58200, y: 9.47030), control1: CGPoint(x: 3.71170, y: 8.10810), control2: CGPoint(x: 3.64680, y: 8.75680))
        path.addCurve(to: CGPoint(x: 3.58200, y: 11.41630), control1: CGPoint(x: 3.51710, y: 10.18380), control2: CGPoint(x: 3.58200, y: 10.76760))
        path.addCurve(to: CGPoint(x: 3.77660, y: 13.42700), control1: CGPoint(x: 3.58200, y: 12.06490), control2: CGPoint(x: 3.64680, y: 12.71350))
        path.addLine(to: CGPoint(x: 3.97120, y: 14.40000))
        path.addCurve(to: CGPoint(x: 4.29550, y: 15.37300), control1: CGPoint(x: 4.03600, y: 14.72430), control2: CGPoint(x: 4.16580, y: 15.04860))
        path.addCurve(to: CGPoint(x: 6.17650, y: 18.87570), control1: CGPoint(x: 4.74950, y: 16.60540), control2: CGPoint(x: 5.46310, y: 17.77300))
        path.addCurve(to: CGPoint(x: 7.34410, y: 20.49730), control1: CGPoint(x: 6.56580, y: 19.45950), control2: CGPoint(x: 6.95500, y: 19.97840))
        path.addCurve(to: CGPoint(x: 8.57660, y: 22.05410), control1: CGPoint(x: 7.73330, y: 21.01630), control2: CGPoint(x: 8.12250, y: 21.60000))
        path.addCurve(to: CGPoint(x: 9.29010, y: 22.76760), control1: CGPoint(x: 8.77120, y: 22.31350), control2: CGPoint(x: 9.03060, y: 22.50810))
        path.addCurve(to: CGPoint(x: 10.13330, y: 23.35130), control1: CGPoint(x: 9.54950, y: 22.96220), control2: CGPoint(x: 9.80910, y: 23.15680))
        path.addCurve(to: CGPoint(x: 11.04140, y: 23.80540), control1: CGPoint(x: 10.39280, y: 23.54590), control2: CGPoint(x: 10.71710, y: 23.67570))
        path.addCurve(to: CGPoint(x: 11.49550, y: 23.93510), control1: CGPoint(x: 11.17120, y: 23.87030), control2: CGPoint(x: 11.36580, y: 23.93510))
        path.addCurve(to: CGPoint(x: 12.01450, y: 24.00000), control1: CGPoint(x: 11.69010, y: 23.93510), control2: CGPoint(x: 11.81980, y: 24.00000))
        path.addCurve(to: CGPoint(x: 12.53330, y: 23.93510), control1: CGPoint(x: 12.20900, y: 24.00000), control2: CGPoint(x: 12.33870, y: 24.00000))
        path.addCurve(to: CGPoint(x: 12.98730, y: 23.80540), control1: CGPoint(x: 12.72790, y: 23.93510), control2: CGPoint(x: 12.85770, y: 23.87030))
        path.addCurve(to: CGPoint(x: 13.89550, y: 23.35140), control1: CGPoint(x: 13.31170, y: 23.67570), control2: CGPoint(x: 13.63600, y: 23.54590))
        path.addCurve(to: CGPoint(x: 14.73870, y: 22.76760), control1: CGPoint(x: 14.15500, y: 23.15680), control2: CGPoint(x: 14.47930, y: 22.96220))
        path.addCurve(to: CGPoint(x: 15.45230, y: 22.05410), control1: CGPoint(x: 14.99820, y: 22.57300), control2: CGPoint(x: 15.25770, y: 22.31360))
        path.addCurve(to: CGPoint(x: 16.68470, y: 20.49730), control1: CGPoint(x: 15.90630, y: 21.53510), control2: CGPoint(x: 16.29550, y: 21.01620))
        path.addCurve(to: CGPoint(x: 17.85230, y: 18.87570), control1: CGPoint(x: 17.07390, y: 19.97830), control2: CGPoint(x: 17.46310, y: 19.39460))
        path.addCurve(to: CGPoint(x: 19.73330, y: 15.37300), control1: CGPoint(x: 18.56580, y: 17.77300), control2: CGPoint(x: 19.27930, y: 16.60540))
        path.addCurve(to: CGPoint(x: 20.05770, y: 14.40000), control1: CGPoint(x: 19.86310, y: 15.04860), control2: CGPoint(x: 19.99280, y: 14.72430))
        path.addCurve(to: CGPoint(x: 20.25230, y: 13.42700), control1: CGPoint(x: 20.12250, y: 14.07570), control2: CGPoint(x: 20.25230, y: 13.75140))
        path.addCurve(to: CGPoint(x: 20.44680, y: 11.41620), control1: CGPoint(x: 20.38200, y: 12.77840), control2: CGPoint(x: 20.44680, y: 12.12970))
        path.addCurve(to: CGPoint(x: 20.38200, y: 9.40540), control1: CGPoint(x: 20.44680, y: 10.76760), control2: CGPoint(x: 20.44680, y: 10.05410))
        path.closeSubpath()
        path.move(to: CGPoint(x: 4.81440, y: 12.06490))
        path.addCurve(to: CGPoint(x: 10.91170, y: 17.90270), control1: CGPoint(x: 4.81440, y: 12.06490), control2: CGPoint(x: 8.51170, y: 12.90810))
        path.addCurve(to: CGPoint(x: 4.81440, y: 12.06490), control1: CGPoint(x: 10.84680, y: 17.90270), control2: CGPoint(x: 4.49010, y: 17.77300))
        path.closeSubpath()
        path.move(to: CGPoint(x: 13.18200, y: 17.90270))
        path.addCurve(to: CGPoint(x: 19.27930, y: 12.06490), control1: CGPoint(x: 15.51710, y: 12.90810), control2: CGPoint(x: 19.27930, y: 12.06490))
        path.addCurve(to: CGPoint(x: 13.18200, y: 17.90270), control1: CGPoint(x: 19.60360, y: 17.77290), control2: CGPoint(x: 13.18200, y: 17.90270))
        path.closeSubpath()
        let scale = min(rect.width, rect.height) / 24
        return path.applying(CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: (rect.width - 24 * scale) / 2,
                                            y: (rect.height - 24 * scale) / 2)))
    }
}
