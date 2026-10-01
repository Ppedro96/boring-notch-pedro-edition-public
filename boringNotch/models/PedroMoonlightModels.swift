import Foundation

struct PedroMoonlightHost: Identifiable, Equatable {
    let id: String
    let name: String
    let address: String
    let apps: [String]

    var preferredApp: String { apps.first { $0.lowercased() == "desktop" } ?? apps.first ?? "" }
    var symbol: String { name.localizedCaseInsensitiveContains("batocera") ? "gamecontroller.fill" : "display" }

    func arguments(app: String, profile: PedroMoonlightProfile = .current) -> [String]? {
        guard apps.contains(app), !id.isEmpty else { return nil }
        // UUID preserves Moonlight's own address selection and paired identity.
        return ["stream", id, app] + profile.arguments
    }
}

enum PedroMoonlightProfile: String, CaseIterable {
    case current, light, fullHD
    var title: String {
        switch self {
        case .current: "Configuração do Moonlight"
        case .light: "Leve · 1280×800 · 60 fps"
        case .fullHD: "1080p · 60 fps"
        }
    }
    var arguments: [String] {
        switch self {
        case .current: []
        case .light: ["--resolution", "1280x800", "--fps", "60", "--bitrate", "8000", "--video-codec", "H.264"]
        case .fullHD: ["--resolution", "1920x1080", "--fps", "60", "--bitrate", "20000"]
        }
    }
}

enum PedroMoonlightCatalog {
    static let bundleID = "com.moonlight-stream.Moonlight"

    static func parse(_ preferences: [String: Any]) -> [PedroMoonlightHost] {
        let count = min(max(0, (preferences["hosts.size"] as? NSNumber)?.intValue ?? 0), 100)
        guard count > 0 else { return [] }
        var seen = Set<String>()
        return (1...count).compactMap { index in
            let prefix = "hosts.\(index)."
            guard let id = preferences[prefix + "uuid"] as? String, !id.isEmpty,
                  let name = preferences[prefix + "hostname"] as? String, !name.isEmpty,
                  let certificate = preferences[prefix + "srvcert"] as? Data, !certificate.isEmpty,
                  seen.insert(id).inserted else { return nil }
            let appCount = min(max(0, (preferences[prefix + "apps.size"] as? NSNumber)?.intValue ?? 0), 500)
            var apps: [String] = []
            if appCount > 0 {
                for appIndex in 1...appCount {
                    let key = prefix + "apps.\(appIndex)."
                    guard (preferences[key + "hidden"] as? NSNumber)?.boolValue != true,
                          let app = preferences[key + "name"] as? String, !app.isEmpty,
                          !apps.contains(app) else { continue }
                    apps.append(app)
                }
            }
            let address = ["manualaddress", "localaddress", "remoteaddress"]
                .compactMap { preferences[prefix + $0] as? String }.first { !$0.isEmpty } ?? ""
            return PedroMoonlightHost(id: id, name: name, address: address, apps: apps)
        }
    }
}
