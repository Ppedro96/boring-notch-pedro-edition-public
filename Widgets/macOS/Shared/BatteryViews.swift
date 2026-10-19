import SwiftUI

struct BatteryDevice: Codable, Identifiable {
    let id: String
    let name: String
    let kind: String
    let charge: Int?
    let charging: Bool
    let connected: Bool
    let updatedAt: Double
    func fresh(at date: Date) -> Bool { connected && date.timeIntervalSince1970 - updatedAt < 180 }
}
struct BatterySnapshot: Codable {
    let updatedAt: Double
    let devices: [BatteryDevice]
    static let empty = BatterySnapshot(updatedAt: 0, devices: [])
    static func read() -> BatterySnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = Bundle.main.bundleIdentifier?.hasSuffix(".widget") == true
            ? home.appendingPathComponent("batteries.json")
            : home.appendingPathComponent("Library/Containers/marketing.insight360.batteries.widget/Data/batteries.json")
        guard let data = try? Data(contentsOf: path), data.count < 16384,
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return .empty }
        return value
    }
    var phones: [BatteryDevice] {
        ["s23", "s25", "fold", "tablet"].compactMap { kind in devices.first { $0.kind == kind } }
    }
}
struct DeviceGlyph: View {
    let kind: String
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                if kind == "tablet" {
                    RoundedRectangle(cornerRadius: 3).stroke(lineWidth: 1.7).frame(width: w * 0.95, height: h * 0.65)
                    Circle().frame(width: 2, height: 2).offset(x: -w * 0.4)
                } else if kind == "fold" {
                    RoundedRectangle(cornerRadius: 3).stroke(lineWidth: 1.7).frame(width: w * 0.9, height: h * 0.87)
                    Rectangle().frame(width: 1, height: h * 0.76).opacity(0.6)
                    RoundedRectangle(cornerRadius: 1).fill(.primary.opacity(0.1)).frame(width: w * 0.36, height: h * 0.7).offset(x: -w * 0.23)
                } else if kind == "mac" {
                    RoundedRectangle(cornerRadius: 2).stroke(lineWidth: 1.5).frame(width: w * 0.85, height: h * 0.57).offset(y: -3)
                    Capsule().frame(width: w, height: 2).offset(y: h * 0.27)
                } else {
                    RoundedRectangle(cornerRadius: kind == "s23" ? 1.5 : 4).stroke(lineWidth: 1.7).frame(width: w * 0.64, height: h * 0.96)
                    Circle().frame(width: 1.5, height: 1.5).offset(y: -h * 0.36)
                    Text(kind == "s23" ? "S23" : "S25").font(.system(size: w * 0.23, weight: .bold, design: .rounded)).offset(y: h * 0.09)
                }
            }.frame(width: w, height: h)
        }
        .accessibilityHidden(true)
    }
}
struct BatteryTile: View {
    let device: BatteryDevice
    let date: Date
    let diameter: CGFloat
    var compact = false
    private var fresh: Bool { device.fresh(at: date) }
    private var tint: Color { !fresh ? .secondary : (device.charge ?? 100) <= 20 ? .red : .green }
    var body: some View {
        VStack(spacing: compact ? 3 : 5) {
            ZStack {
                Circle().stroke(.primary.opacity(0.12), lineWidth: 4)
                if let charge = device.charge {
                    Circle().trim(from: 0, to: CGFloat(min(100, max(0, charge))) / 100)
                        .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
                }
                DeviceGlyph(kind: device.kind).frame(width: diameter * 0.46, height: diameter * 0.53)
                    .foregroundStyle(fresh ? Color.primary : .secondary)
                if device.charging && fresh {
                    Image(systemName: "bolt.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.green)
                        .padding(3).background(.background, in: Circle()).offset(x: diameter * 0.32, y: diameter * 0.32)
                }
            }.frame(width: diameter, height: diameter)
            Text(device.charge.map { "\($0)%" } ?? "—").font(.system(size: compact ? 12 : 16, weight: .medium, design: .rounded)).monospacedDigit()
            Text(device.name).font(.system(size: compact ? 8 : 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            if !fresh && !compact { Text("Offline").font(.system(size: 8)).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
struct BatteriesPanel: View {
    let snapshot: BatterySnapshot
    let date: Date
    var compact = false
    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: compact ? 8 : 12) {
                if snapshot.phones.isEmpty {
                    Text("Dispositivos Galaxy").font(.headline)
                    Text("Abra o Insight Notch para receber as baterias.").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if compact {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        ForEach(snapshot.phones) { device in
                            BatteryTile(device: device, date: date, diameter: max(24, min(30, (geo.size.height - 66) / 2)), compact: true)
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(snapshot.phones) { device in
                            BatteryTile(device: device, date: date, diameter: max(36, min(58, (geo.size.width - 45) / 4 - 10)))
                        }
                    }.frame(maxHeight: .infinity)
                    if snapshot.updatedAt > 0 {
                        HStack(spacing: 3) {
                            Text("Leitura").font(.system(size: 9))
                            Text(Date(timeIntervalSince1970: snapshot.updatedAt), style: .relative).font(.system(size: 9))
                            Spacer()
                            Text("Galaxy").font(.system(size: 9, weight: .medium))
                        }.foregroundStyle(.secondary)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
