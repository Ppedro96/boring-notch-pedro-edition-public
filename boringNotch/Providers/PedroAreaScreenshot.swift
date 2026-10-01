import Foundation

struct PedroAreaScreenshot {
    // No output path: macOS writes the selected rectangle directly to the clipboard.
    static let arguments = ["-i", "-s", "-c", "-x", "-d"]
    let executableURL: URL

    init(executableURL: URL = URL(fileURLWithPath: "/usr/sbin/screencapture")) {
        self.executableURL = executableURL
    }

    func capture() async throws -> Int32 {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = Self.arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
