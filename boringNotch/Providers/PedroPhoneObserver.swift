import Foundation

/// One persistent local helper. Its local D-Bus and SSH event streams are independent.
final class PedroPhoneObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var stopped = false

    func start(receive: @escaping @Sendable (Data) -> Void, ended: @escaping @Sendable () -> Void) {
        let task = Process(), output = Pipe(), inputPipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/node")
        task.arguments = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/pedro-notch/kde-phone.cjs").path, "watch"]
        task.standardOutput = output; task.standardInput = inputPipe; task.standardError = FileHandle.nullDevice
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        do { try task.run() } catch { lock.unlock(); ended(); return }
        process = task; input = inputPipe.fileHandleForWriting
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buffer = Data()
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                if buffer.count > 1_048_576 { task.terminate(); break }
                while let index = buffer.firstIndex(of: 10) {
                    let line = Data(buffer.prefix(upTo: index)); buffer.removeSubrange(...index)
                    receive(line)
                }
            }
            task.waitUntilExit()
            guard let self else { return }
            self.lock.lock(); let notify = !self.stopped; self.process = nil; self.input = nil; self.lock.unlock()
            if notify { ended() }
        }
    }
    func refresh() { write("{\"command\":\"refresh\"}\n") }
    func setNativeNotifications(_ enabled: Bool) { write("{\"nativeNotifications\":\(enabled)}\n") }
    private func write(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        try? input?.write(contentsOf: Data(value.utf8))
    }
    func stop() {
        lock.lock(); stopped = true
        let task = process
        try? input?.close(); input = nil; process = nil
        lock.unlock()
        if task?.isRunning == true { task?.terminate() }
    }
    deinit { stop() }
}
