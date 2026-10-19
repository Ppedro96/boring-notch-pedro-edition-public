import Foundation

@main
struct PedroAreaScreenshotTests {
    static func main() async throws {
        precondition(PedroAreaScreenshot.arguments == ["-i", "-s", "-c", "-x"])
        precondition(PedroAreaScreenshot().executableURL.path == "/usr/sbin/screencapture")
        let success = try await PedroAreaScreenshot(executableURL: URL(fileURLWithPath: "/usr/bin/true")).capture()
        precondition(success.status == 0)
        precondition(success.outcome(hasNewImage: true) == .copied)
        precondition(success.outcome(hasNewImage: false) == .failed, "Missing image must not look successful")
        let cancelled = try await PedroAreaScreenshot(executableURL: URL(fileURLWithPath: "/usr/bin/false")).capture()
        precondition(cancelled.status != 0)
        precondition(cancelled.outcome(hasNewImage: false) == .cancelled)
        precondition(cancelled.outcome(hasNewImage: true) == .failed, "A failed capture must not claim another app's image")
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let executable = fixture.appendingPathComponent("capture-error")
        try "#!/bin/sh\nprintf 'capture error: not authorized\\n' >&2\nexit 1\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let failed = try await PedroAreaScreenshot(executableURL: executable).capture()
        precondition(failed.status == 1)
        precondition(failed.diagnostic == "capture error: not authorized")
        precondition(failed.outcome(hasNewImage: false) == .failed, "Permission failures are not Escape")
        try "#!/bin/sh\ni=0\nwhile [ $i -lt 5000 ]; do printf 'capture diagnostic\\n' >&2; i=$((i+1)); done\nexit 1\n".write(to: executable, atomically: true, encoding: .utf8)
        let largeDiagnostic = try await PedroAreaScreenshot(executableURL: executable).capture()
        precondition(largeDiagnostic.diagnostic.utf8.count > 65536, "Drain stderr without blocking the helper")
        do {
            _ = try await PedroAreaScreenshot(executableURL: URL(fileURLWithPath: "/nonexistent/screencapture")).capture()
            preconditionFailure("Launch errors must be reported without hanging")
        } catch {}
        print("PedroAreaScreenshotTests passed")
    }
}
