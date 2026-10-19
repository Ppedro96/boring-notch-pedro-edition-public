import Foundation

/// One owned stdio child. Python owns SSH reconnect/cache; Swift only restarts a crashed bridge.
@MainActor final class PedroContinuityTransport {
    enum Failure: LocalizedError {
        case unavailable, rejected(String)
        var errorDescription: String? {
            switch self { case .unavailable: return "Continuidade indisponível"; case .rejected(let text): return text }
        }
    }
    var onEvent: ((Data) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var verifiedGroup: pid_t?
    private var launchToken = ""
    private var bufferedWrites: [(String, Data)] = []
    private var cleanup: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<PedroContinuityPayload, Error>] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]
    private let writer = DispatchQueue(label: "notch.continuity.writer")
    private var restart: Task<Void, Never>?
    private var stopped = true
    private var generation = 0
    private var failures = 0
    private var script: URL?
    private var config: URL?
    func start(script: URL, config: URL) {
        guard stopped else { return }
        self.script = script; self.config = config; stopped = false; launch()
    }
    private func launch() {
        guard !stopped, let script, let config else { return }
        generation += 1; let version = generation
        let p = Process(), out = Pipe(), err = Pipe(), stdin = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        // Isolate the bridge and its SSH child in an owned process group. Python's
        // finally cleanup is not guaranteed after SIGTERM during a long request.
        // The private handshake prevents any script/SSH descendant from starting
        // before native code has verified and retained ownership of the group.
        launchToken = UUID().uuidString
        let launcher = "import json,os,runpy,sys\ntry: os.setsid()\nexcept PermissionError: pass\nprint(json.dumps({'event':'_bridge_ready','token':sys.argv[1],'pid':os.getpid(),'group':os.getpgrp()}),flush=True)\nassert sys.stdin.buffer.readline()==b'ready\\n'\nsys.argv=sys.argv[2:];sys.path.insert(0,os.path.dirname(sys.argv[0]));runpy.run_path(sys.argv[0],run_name='__main__')"
        p.arguments = ["-c", launcher, launchToken, script.path, "--stdio", "--config", config.path]
        p.standardInput = stdin; p.standardOutput = out; p.standardError = err
        let reader = PedroContinuityLineReader { [weak self] data in
            Task { @MainActor in guard let self, self.generation == version else { return }; self.receive(data) }
        }
        out.fileHandleForReading.readabilityHandler = { handle in reader.append(handle.availableData) }
        err.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        p.terminationHandler = { [weak self] _ in
            out.fileHandleForReading.readabilityHandler = nil; err.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self, self.generation == version, !self.stopped else { return }
                self.beginCleanup(); self.lost(); self.scheduleRestart()
            }
        }
        do { try p.run(); process = p; input = stdin.fileHandleForWriting }
        catch { lost(); scheduleRestart() }
    }
    private func scheduleRestart() {
        failures += 1
        restart = Task { [weak self] in
            guard let self else { return }
            await cleanup?.value
            guard !Task.isCancelled, !stopped else { return }
            try? await Task.sleep(for: .seconds(min(5, Double(failures))))
            guard !Task.isCancelled else { return }; launch()
        }
    }
    private func lost() {
        input = nil; process = nil; bufferedWrites.removeAll()
        for continuation in pending.values { continuation.resume(throwing: Failure.unavailable) }
        pending.removeAll(); for task in deadlines.values { task.cancel() }; deadlines.removeAll()
        onEvent?(Data("{\"event\":\"connection\",\"state\":\"offline\"}".utf8))
    }
    /// Ownership survives the leader's exit; a live group can still contain SSH.
    private func beginCleanup() {
        let child = process, group = verifiedGroup
        verifiedGroup = nil
        guard child != nil || group != nil else { return }
        if let group { kill(-group, SIGTERM) }
        else if let child, child.isRunning { child.terminate() }
        cleanup = Task.detached(priority: .utility) {
            if let group {
                for _ in 0..<20 {
                    if kill(-group, 0) != 0 { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                // Signal the verified group even after its direct leader has exited.
                if kill(-group, 0) == 0 { kill(-group, SIGKILL) }
                for _ in 0..<20 {
                    if kill(-group, 0) != 0 { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            } else if let child, child.isRunning {
                try? await Task.sleep(for: .seconds(1))
                if child.isRunning { child.terminate(); kill(child.processIdentifier, SIGKILL) }
            }
            child?.waitUntilExit()
        }
    }
    func stop() {
        stopped = true; generation += 1; restart?.cancel()
        try? input?.close()
        beginCleanup()
        lost()
    }
    func request(_ request: PedroContinuityPayload, timeout: Double = 60) async throws -> PedroContinuityPayload {
        guard let input, !stopped else { throw Failure.unavailable }
        let id = UUID().uuidString
        var envelope = request; envelope["id"] = .string(id); envelope["timeout"] = .number(timeout)
        var data = try JSONEncoder().encode(envelope); data.append(10)
        guard data.count <= 1_048_576 else { throw Failure.rejected("Conteúdo excede o limite") }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            deadlines[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout + 2))
                guard !Task.isCancelled, let self, let pending = self.pending.removeValue(forKey: id) else { return }
                self.deadlines.removeValue(forKey: id); pending.resume(throwing: Failure.unavailable)
            }
            if verifiedGroup == nil { bufferedWrites.append((id, data)) }
            else { write(data, id: id, to: input) }
        }
    }
    private func write(_ data: Data, id: String, to input: FileHandle) {
        writer.async { [weak self] in
            do { try input.write(contentsOf: data) }
            catch { Task { @MainActor in
                guard let self, let continuation = self.pending.removeValue(forKey: id) else { return }
                self.deadlines.removeValue(forKey: id)?.cancel(); continuation.resume(throwing: error)
            } }
        }
    }
    private func receive(_ data: Data) {
        guard let frame = try? JSONDecoder().decode(PedroContinuityPayload.self, from: data) else { return }
        if frame["event"]?.string == "_bridge_ready" {
            guard verifiedGroup == nil, let process, let input,
                  frame["token"]?.string == launchToken,
                  frame["pid"]?.number == Double(process.processIdentifier),
                  frame["group"]?.number == Double(process.processIdentifier),
                  getpgid(process.processIdentifier) == process.processIdentifier else { return }
            verifiedGroup = process.processIdentifier
            write(Data("ready\n".utf8), id: "", to: input)
            let buffered = bufferedWrites; bufferedWrites.removeAll()
            for (id, bytes) in buffered where pending[id] != nil { write(bytes, id: id, to: input) }
            return
        }
        if frame["event"] != nil { onEvent?(data); return }
        guard let id = frame["id"]?.string, let continuation = pending.removeValue(forKey: id) else { return }
        deadlines.removeValue(forKey: id)?.cancel(); failures = 0
        if frame["ok"]?.bool == true { continuation.resume(returning: frame) }
        else { continuation.resume(throwing: Failure.rejected(frame["error"]?.string ?? "Falha na continuidade")) }
    }
}
private final class PedroContinuityLineReader: @unchecked Sendable {
    private var buffer = Data()
    private let receive: (Data) -> Void
    init(receive: @escaping (Data) -> Void) { self.receive = receive }
    func append(_ bytes: Data) {
        buffer.append(bytes)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]; if line.count <= 1_048_576 { receive(Data(line)) }
            buffer.removeSubrange(...newline)
        }
        if buffer.count > 1_048_576 { buffer.removeAll() }
    }
}
