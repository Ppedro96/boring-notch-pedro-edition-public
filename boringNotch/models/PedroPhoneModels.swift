import Foundation
import Combine
import CryptoKit

struct PedroPhoneNotification: Decodable, Identifiable, Equatable {
    let id: String
    let app: String
    let title: String
    let text: String
    var replyID: String? = nil
    var silent: Bool? = nil
    var canReply: Bool { !(replyID ?? "").isEmpty }
    func fingerprint(deviceID: String) -> String {
        SHA256.hash(data: Data([deviceID, id, app, title, text].joined(separator: "\u{0}").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

struct PedroPhoneMedia: Decodable, Equatable {
    let players: [String]
    let player: String
    let title: String
    let artist: String
    let playing: Bool
    let artwork: String?
    var isAvailable: Bool { !players.isEmpty && !player.isEmpty }
}

struct PedroPhone: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let paired: Bool
    let reachable: Bool
    let charge: Int?
    let charging: Bool
    let notifications: [PedroPhoneNotification]
    let notificationsAvailable: Bool
    let canRing: Bool
    let canShare: Bool
    let canShareFiles: Bool
    let via: String?
    var media: PedroPhoneMedia? = nil
    var disconnected: PedroPhone {
        PedroPhone(id: id, name: name, paired: paired, reachable: false, charge: nil, charging: false,
                   notifications: [], notificationsAvailable: false, canRing: false, canShare: false,
                   canShareFiles: canShareFiles, via: via, media: nil)
    }
    var isConnected: Bool { paired && reachable }
    var tabName: String {
        let prefix = "Galaxy "
        let shortName = name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
        return shortName == "Tab S8 Plus" ? "Tab S8+" : shortName
    }
    var batteryPercentage: Int? {
        guard isConnected, let charge, (0...100).contains(charge) else { return nil }
        return charge
    }
    var batteryText: String { batteryPercentage.map { "\($0)%" } ?? "--" }
    var isCharging: Bool { isConnected && charging }
    var statusDescription: String {
        guard isConnected else { return paired ? "Desconectado" : "Nao pareado" }
        return batteryText + (isCharging ? " - Carregando" : "")
    }
}

struct PedroPhoneSnapshot: Decodable {
    let devices: [PedroPhone]?
    let error: String?
}

struct PedroPhoneTransferUpdate: Decodable {
    let phase: String
    var bytes: Int64?
    var total: Int64?
    var detail: String?
    var isFinished: Bool { ["completed", "failed", "cancelled", "unknown", "submitted"].contains(phase) }
    var canCancel: Bool { ["queued", "staging"].contains(phase) }
    var percentage: Double? {
        guard ["staging", "sending", "completed"].contains(phase), let bytes, let total, total > 0 else { return nil }
        return min(phase == "completed" ? 100 : 99, max(0, Double(bytes) / Double(total) * 100))
    }
    var title: String {
        switch phase {
        case "queued": "Na fila"
        case "staging": "Mac > X99"
        case "verifying": "Verificando"
        case "sending": "Enviando ao aparelho"
        case "completed": "Enviado"
        case "submitted": "Entregue ao KDE"
        case "cancelled": "Cancelado"
        case "unknown": "Sem confirmacao"
        default: "Falhou"
        }
    }
}

struct PedroPhoneTransfer: Identifiable {
    let id: String
    let source: URL
    let deviceID: String
    let deviceName: String
    var update = PedroPhoneTransferUpdate(phase: "queued")
}

final class PedroPhoneTransferProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if running?.isRunning == true { running?.terminate() }
    }

    func run(device: String, file: URL, receive: @Sendable (PedroPhoneTransferUpdate) -> Void) -> PedroPhoneTransferUpdate {
        let script = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/pedro-notch/kde-file-transfer.cjs")
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/node")
        task.arguments = [script.path, "send", device, file.path]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); return .init(phase: "cancelled") }
        process = task
        do { try task.run() } catch {
            process = nil; lock.unlock()
            return .init(phase: "failed", detail: "Nao foi possivel iniciar o envio")
        }
        lock.unlock()
        var buffer = Data(), last: PedroPhoneTransferUpdate?
        while true {
            let data = pipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            buffer.append(data)
            guard buffer.count <= 65536 else { task.terminate(); break }
            while let index = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: index)
                buffer.removeSubrange(...index)
                if let update = try? JSONDecoder().decode(PedroPhoneTransferUpdate.self, from: line),
                   ["queued", "staging", "verifying", "sending", "completed", "failed", "cancelled", "unknown", "submitted"].contains(update.phase) {
                    last = update; receive(update)
                }
            }
        }
        task.waitUntilExit()
        lock.lock(); process = nil; let wasCancelled = cancelled; lock.unlock()
        if let last, last.isFinished { return last }
        return .init(phase: wasCancelled ? "cancelled" : "failed", detail: wasCancelled ? "Copia cancelada" : "Integracao interrompida; conclusao nao confirmada")
    }
}

enum PedroPhoneBridge {
    static func run(_ arguments: [String], input: Data? = nil) -> Data {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let script = home.appendingPathComponent(".local/share/pedro-notch/kde-phone.cjs")
        guard FileManager.default.fileExists(atPath: script.path) else {
            return Data("{\"error\":\"Integracao KDE Connect nao instalada\"}".utf8)
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/node")
        process.arguments = [script.path] + arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let inputPipe = input.map { _ in Pipe() }
        process.standardInput = inputPipe ?? Pipe()
        do { try process.run() } catch {
            return Data("{\"error\":\"Nao foi possivel iniciar a integracao\"}".utf8)
        }
        if let input, let inputPipe {
            try? inputPipe.fileHandleForWriting.write(contentsOf: input)
            try? inputPipe.fileHandleForWriting.close()
        }
        // Read while the helper runs, so a notification batch cannot fill the pipe.
        DispatchQueue.global().asyncAfter(deadline: .now() + 9) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }
}

/// Baselines each device without replaying its old inbox on launch/reconnect.
struct PedroPhoneNotificationLedger {
    private var initialized: Set<String> = []
    private var seen: [String: Set<String>] = [:]
    mutating func additions(_ phone: PedroPhone) -> [PedroPhoneNotification] {
        guard phone.isConnected else { return [] }
        let previous = seen[phone.id] ?? []
        let current = Set(phone.notifications.map { $0.fingerprint(deviceID: phone.id) })
        seen[phone.id] = previous.union(current)
        if seen[phone.id, default: []].count > 2000 { seen[phone.id] = current }
        guard initialized.insert(phone.id).inserted == false else { return [] }
        return phone.notifications.filter { !previous.contains($0.fingerprint(deviceID: phone.id)) && $0.silent != true }
    }
}


/// Short-lived action result; replacing it cancels the prior dismissal deadline.
@MainActor
final class PedroPhoneFeedback: ObservableObject {
    @Published private(set) var message: String?
    private var expiration: Task<Void, Never>?

    func show(_ message: String, duration: Duration = .seconds(4)) {
        expiration?.cancel()
        self.message = message
        expiration = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    func dismiss() {
        expiration?.cancel()
        expiration = nil
        message = nil
    }
}
