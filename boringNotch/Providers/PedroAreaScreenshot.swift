import Foundation

struct PedroAreaScreenshot {
    // No output path: macOS writes the selected rectangle directly to the clipboard.
    static let arguments = ["-i", "-s", "-c", "-x"]
    let executableURL: URL

    struct Result: Sendable {
        enum Outcome { case copied, cancelled, failed }

        let status: Int32
        let diagnostic: String

        func outcome(hasNewImage: Bool) -> Outcome {
            if status == 0, hasNewImage { return .copied }
            // Escape exits without an image or a diagnostic; other failures must be visible.
            if status != 0, diagnostic.isEmpty, !hasNewImage { return .cancelled }
            return .failed
        }
    }

    init(executableURL: URL = URL(fileURLWithPath: "/usr/sbin/screencapture")) {
        self.executableURL = executableURL
    }

    func capture() async throws -> Result {
        let executableURL = executableURL
        return try await Task.detached {
            let process = Process()
            let errors = Pipe()
            process.executableURL = executableURL
            process.arguments = Self.arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            try process.run()
            try errors.fileHandleForWriting.close()
            // Drain stderr while the selector runs so diagnostics cannot fill the pipe.
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Result(
                status: process.terminationStatus,
                diagnostic: String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }.value
    }
}
