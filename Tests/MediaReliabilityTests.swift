import AppKit
import Foundation

@main struct MediaReliabilityTests {
    @MainActor static func main() async throws {
        func update(_ json: String) throws -> NowPlayingUpdate {
            try JSONDecoder().decode(NowPlayingUpdate.self, from: Data(json.utf8))
        }
        var state = try update(#"{"payload":{"title":"Track A","artist":"Artist","album":"Album","bundleIdentifier":"test.player","duration":200,"elapsedTime":10,"playing":true,"artworkData":"Y292ZXI="}}"#)
            .applying(to: PlaybackState(bundleIdentifier: ""), now: Date(timeIntervalSince1970: 100))
        let art = state.artwork
        state = try update(#"{"diff":true,"payload":{"elapsedTime":12}}"#).applying(to: state, now: Date(timeIntervalSince1970: 102))
        precondition(state.artwork == art && state.title == "Track A", "A progress delta must preserve its cover")
        let paused = try update(#"{"diff":true,"payload":{"playing":false}}"#).applying(to: state, now: Date(timeIntervalSince1970: 104))
        precondition(paused.currentTime == 14 && paused.artwork == art)
        let stillPaused = try update(#"{"diff":true,"payload":{"playing":false}}"#).applying(to: paused, now: Date(timeIntervalSince1970: 108))
        precondition(stillPaused.currentTime == 14, "Repeated pause events must not advance time")
        let nextTrack = try update(#"{"diff":true,"payload":{"title":"Track B"}}"#).applying(to: state)
        precondition(nextTrack.artwork == nil && nextTrack.currentTime == 0, "A new track must not retain the old cover or position")
        let nextApp = try update(#"{"diff":true,"payload":{"parentApplicationBundleIdentifier":"test.browser"}}"#).applying(to: state)
        precondition(nextApp.artwork == nil, "A browser helper switch must invalidate the previous cover")
        let reset = try update(#"{"diff":false,"payload":{}}"#).applying(to: state)
        precondition(reset.artwork == nil && reset.title.isEmpty && !reset.isPlaying)
        var changed = state; changed.volume = 0.8
        precondition(changed != state, "Volume changes must be published")
        changed = state; changed.playbackRate = 1.5
        precondition(changed != state, "Playback speed changes must be published")

        let request = try WebSocketURLBuilder.authenticatedRequest(to: URL(string: "ws://127.0.0.1:1/api/v1/ws?keep=x%2By&token=old")!, token: "test+a/b?c&d=e")
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        precondition(components.queryItems!.filter { $0.name == "token" }.map(\.value) == ["test+a/b?c&d=e"])
        precondition(components.percentEncodedQuery!.contains("test%2Ba"))
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test+a/b?c&d=e")
        precondition(WebSocketURLBuilder.buildURL(from: "file:///tmp/test") == nil)
        do {
            _ = try WebSocketURLBuilder.authenticatedRequest(to: request.url!, token: "")
            preconditionFailure("An empty token must be rejected")
        } catch YouTubeMusicError.authenticationRequired { }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("arquivo com espaços 📎.txt")
        try Data("attachment".utf8).write(to: file)
        let board = NSPasteboard(name: .init("test.shelf." + UUID().uuidString))
        defer { board.releaseGlobally() }
        precondition(board.writeObjects([ShelfFileDragWriter.make(url: file)!]))
        let read = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        precondition(read == [file], "A receiver must read the original file URL, including Unicode and spaces")
        precondition(board.string(forType: .string) == nil, "A file must not become a plain path in a message composer")
        precondition(ShelfFileDragWriter.make(url: URL(string: "https://example.invalid")!) == nil)

        func solid(_ color: NSColor, width: Int, height: Int) -> NSImage {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(color.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return NSImage(cgImage: context.makeImage()!, size: .zero)
        }
        func color(_ image: NSImage) async -> NSColor? {
            await withCheckedContinuation { continuation in image.averageColor { continuation.resume(returning: $0) } }
        }
        let result = await color(solid(.red, width: 2400, height: 2400))
        precondition(result!.redComponent > 0.95 && result!.greenComponent < 0.05)
        let dark = await color(solid(.black, width: 1, height: 4000))
        precondition(abs(dark!.usingColorSpace(.sRGB)!.redComponent - 0.5) < 0.02, "Dark and very narrow covers must remain valid")
        print("MediaReliabilityTests: incremental covers, track/app switches, pause timing, volume, token encoding, native file attachments and sampled colors passed")
    }
}
