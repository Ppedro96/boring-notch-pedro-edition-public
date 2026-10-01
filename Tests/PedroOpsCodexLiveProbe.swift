import Foundation

@main
struct PedroOpsCodexLiveProbe {
    static func main() {
        guard let output = PedroOpsCodexAppServerClient.fetch(timeout: 8) else {
            print("Codex app-server probe: no response")
            return
        }

        if let limits = PedroOpsCodexAppServerClient.parseRateLimits(from: output) {
            let windows = limits.windows
                .sorted { $0.key < $1.key }
                .map { "\($0.key)m=\($0.value.usedPercent)%" }
                .joined(separator: ", ")
            print("Codex app-server probe: \(windows)")
        } else {
            print("Codex app-server probe: response could not be parsed")
        }
    }
}
