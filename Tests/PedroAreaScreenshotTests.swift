import Foundation

@main
struct PedroAreaScreenshotTests {
    static func main() async throws {
        precondition(PedroAreaScreenshot.arguments == ["-i", "-s", "-c", "-x", "-d"])
        precondition(PedroAreaScreenshot().executableURL.path == "/usr/sbin/screencapture")
        let success = try await PedroAreaScreenshot(executableURL: URL(fileURLWithPath: "/usr/bin/true")).capture()
        precondition(success == 0)
        let cancelled = try await PedroAreaScreenshot(executableURL: URL(fileURLWithPath: "/usr/bin/false")).capture()
        precondition(cancelled != 0)
        do {
            _ = try await PedroAreaScreenshot(executableURL: URL(fileURLWithPath: "/nonexistent/screencapture")).capture()
            preconditionFailure("Launch errors must be reported without hanging")
        } catch {}
        print("PedroAreaScreenshotTests passed")
    }
}
