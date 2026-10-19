import AppKit
import Foundation

// Replace only the application-wide cache dependency; exercise the real HTTP/socket clients.
final class ImageService {
    static let shared = ImageService()
    func fetchImageData(from url: URL) async throws -> Data { try await URLSession.shared.data(from: url).0 }
}
actor SocketEvents {
    var messages = 0
    var disconnects = 0
    func message() { messages += 1 }
    func disconnect() { disconnects += 1 }
}
@main struct MediaSocketIntegrationTests {
    @MainActor static func main() async throws {
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["node", "Tests/MediaSocketTestServer.cjs"]
        let output = Pipe(); server.standardOutput = output
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        let port = Int(String(data: output.fileHandleForReading.availableData, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines))!
        let base = "http://127.0.0.1:\(port)"
        func control(_ command: [String: Any]) async throws {
            var request = URLRequest(url: URL(string: base + "/control")!)
            request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: command)
            _ = try await URLSession.shared.data(for: request)
        }
        func stats() async throws -> [String: Any] {
            let data = try await URLSession.shared.data(from: URL(string: base + "/stats")!).0
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        func wait(_ message: String, _ condition: @MainActor () async -> Bool) async throws {
            for _ in 0..<120 {
                if await condition() { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            preconditionFailure(message)
        }
        let events = SocketEvents()
        let socket = YouTubeMusicWebSocketClient(onMessage: { _ in await events.message() }, onDisconnect: { await events.disconnect() })
        let ws = WebSocketURLBuilder.buildURL(from: base)!
        try await socket.connect(to: ws, with: "fixture+a/b?c&d=e")
        try await wait("Initial socket handshake") { await events.messages > 0 }
        for _ in 0..<15 { try await socket.connect(to: ws, with: "fixture+a/b?c&d=e") }
        try await wait("Replacement socket must stay alive") { await events.messages > 1 }
        try await Task.sleep(for: .milliseconds(100))
        let connected = await socket.isConnected
        let unexpectedDisconnects = await events.disconnects
        precondition(connected)
        precondition(unexpectedDisconnects == 0, "Replaced sockets must not disconnect their successor")
        await socket.disconnect()
        try await Task.sleep(for: .milliseconds(50))
        let intentionalDisconnects = await events.disconnects
        precondition(intentionalDisconnects == 0, "Intentional disconnects must stay silent")

        var running = true
        var controller: YouTubeMusicController? = YouTubeMusicController(configuration: .init(baseURL: base, bundleIdentifier: "fixture.player", reconnectDelay: 0.05...0.2, updateInterval: 0.05), appIsRunning: { running }, observesWorkspace: false)
        try await wait("Initial player state and cover") { controller?.playbackState.artwork == Data("/cover/A".utf8) }
        for position in 11...20 { try await control(["song": ["elapsedSeconds": position]]) }
        try await Task.sleep(for: .milliseconds(100))
        let initial = try await stats()
        precondition((initial["covers"] as! [String: Int])["/cover/A"] == 1, "Progress events must not download the same cover again")
        let upgrades = initial["upgrades"] as! Int
        try await control(["drop": true])
        try await wait("Player reconnect after network interruption") { (try? await stats()["upgrades"] as? Int) ?? 0 > upgrades }
        try await control(["song": ["title": "Track B", "imageSrc": base + "/cover/slow"]])
        try await Task.sleep(for: .milliseconds(30))
        try await control(["song": ["title": "Track C", "imageSrc": base + "/cover/C"]])
        try await wait("New cover") { controller?.playbackState.artwork == Data("/cover/C".utf8) }
        try await Task.sleep(for: .milliseconds(450))
        precondition(controller?.playbackState.title == "Track C" && controller?.playbackState.artwork == Data("/cover/C".utf8), "A slow old cover must not overwrite the current track")
        running = false; controller?.appDidTerminate()
        try await control(["song": ["title": "Late event"]])
        try await Task.sleep(for: .milliseconds(100))
        precondition(controller?.playbackState.title != "Late event")
        running = true; await controller?.appDidLaunch()
        try await wait("Reopen player without recreating its controller") { controller?.playbackState.title == "Late event" }
        running = false; controller?.appDidTerminate()
        weak let released = controller
        controller = nil
        try await wait("Controller must release timers and reconnect tasks") { released == nil }
        try await control(["authDelay": 300])
        running = true
        var slowController: YouTubeMusicController? = YouTubeMusicController(configuration: .init(baseURL: base, bundleIdentifier: "fixture.player", reconnectDelay: 0.05...0.2, updateInterval: 0.05), appIsRunning: { running }, observesWorkspace: false)
        try await Task.sleep(for: .milliseconds(25))
        running = false; slowController?.appDidTerminate()
        running = true; await slowController?.appDidLaunch()
        try await wait("Rapid reopening during authentication must recover") { slowController?.playbackState.title == "Late event" }
        running = false; slowController?.appDidTerminate(); slowController = nil
        let stopped = try await stats()["upgrades"] as! Int
        try await Task.sleep(for: .milliseconds(350))
        let auth = YouTubeMusicAuthManager(httpClient: YouTubeMusicHTTPClient(baseURL: base))
        let obsoleteAuth = Task { try await auth.authenticate() }
        try await Task.sleep(for: .milliseconds(25))
        await auth.invalidateToken()
        let freshAuth = try await auth.authenticate()
        do {
            _ = try await obsoleteAuth.value
            preconditionFailure("Invalidated authentication must not restore an old token")
        } catch { }
        let cachedToken = await auth.currentToken
        precondition(cachedToken == freshAuth)
        let finalStats = try await stats()
        precondition(finalStats["upgrades"] as! Int == stopped, "Closing the player must cancel reconnect attempts")
        precondition(finalStats["rejected"] as! Int == 0, "Reserved token characters must survive the real handshake")
        print("MediaSocketIntegrationTests: authenticated handshake, 15 socket replacements, reconnect, cover deduplication, stale-cover cancellation, close/reopen during authentication and controller cleanup passed")
    }
}
