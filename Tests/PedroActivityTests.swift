import Foundation

@main
struct PedroActivityTests {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pedro-activity-tests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source.bin")
        let folder = root.appendingPathComponent("target")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let payload = Data(repeating: 42, count: 8 * 1024 * 1024 + 317)
        try payload.write(to: source)
        var lastBytes: Int64 = 0
        let copied = try PedroFileCopy.copy(source: source, destination: folder, cancellation: .init()) { bytes, total in
            precondition(bytes >= lastBytes && bytes <= total)
            lastBytes = bytes
        }
        let copiedData = try Data(contentsOf: copied)
        precondition(copiedData == payload)
        let second = try PedroFileCopy.copy(source: source, destination: folder, cancellation: .init()) { _, _ in }
        precondition(copied != second)
        let preservedData = try Data(contentsOf: copied)
        precondition(preservedData == payload)
        let cancelled = PedroTransferCancellation()
        cancelled.cancel()
        do {
            _ = try PedroFileCopy.copy(source: source, destination: folder, cancellation: cancelled) { _, _ in }
            fatalError("cancelled copy succeeded")
        } catch PedroTransferError.cancelled {}
        let remainingFiles = try fm.contentsOfDirectory(atPath: folder.path)
        precondition(remainingFiles.count == 2)
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: source)
        do {
            _ = try PedroFileCopy.copy(source: link, destination: folder, cancellation: .init()) { _, _ in }
            fatalError("symlink copied")
        } catch PedroTransferError.unsupported {}

        let suite = "pedro-activity-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = PedroActivityManager(defaults: defaults)
        var event = PedroActivityEvent(id: "test", revision: "1", kind: "dot", title: "Aviso", detail: "Teste",
            state: .completed, updatedAt: Date(), progress: nil, url: "https://example.com", outputPath: nil)
        manager.record(event)
        precondition(manager.events.count == 1)
        manager.dismiss([event])
        manager.record(event)
        precondition(manager.events.isEmpty)
        let restored = PedroActivityManager(defaults: defaults)
        precondition(restored.events.isEmpty)
        event.revision = "2"; event.updatedAt = Date()
        restored.record(event)
        precondition(restored.events.count == 1)
        var lateProgress = event
        lateProgress.updatedAt = event.updatedAt.addingTimeInterval(-1)
        lateProgress.state = .running
        restored.record(lateProgress)
        precondition(restored.events.first?.state == .completed)
        // Hiding Dot preserves its history and leaves transfers visible.
        let transfer = PedroActivityEvent(id: "transfer-test", revision: "1", kind: "transfer",
            title: "Copia", detail: "Teste", state: .completed, updatedAt: Date(),
            progress: nil, url: nil, outputPath: nil)
        restored.record(transfer)
        defaults.set(true, forKey: "hideDotIntegration")
        let hidden = PedroActivityManager(defaults: defaults)
        precondition(hidden.events.map(\.id) == [transfer.id])
        defaults.set(false, forKey: "hideDotIntegration")
        let shown = PedroActivityManager(defaults: defaults)
        precondition(Set(shown.events.map(\.id)) == Set([event.id, transfer.id]))
        event.progress = 101
        precondition(!event.isValid())
        event.url = "file:///etc/passwd"
        precondition(event.safeURL == nil)

        let disk = root.appendingPathComponent("events")
        try fm.createDirectory(at: disk, withIntermediateDirectories: true)
        event.progress = 30; event.url = nil
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(event).write(to: disk.appendingPathComponent("valid.json"))
        try fm.createSymbolicLink(at: disk.appendingPathComponent("link.json"), withDestinationURL: disk.appendingPathComponent("valid.json"))
        try Data("invalid".utf8).write(to: disk.appendingPathComponent("bad.json"))
        precondition(PedroActivityDisk.read(directory: disk).count == 1)

        let partial = root.appendingPathComponent("movie.mp4.crdownload")
        let final = root.appendingPathComponent("movie.mp4")
        try payload.write(to: partial)
        try payload.write(to: final)
        let download = PedroDownloadScanner.scan(directory: root).first!
        precondition(!download.confirmedFinished, "existing unrelated file is not proof")
        try fm.removeItem(at: final)
        let fresh = PedroDownloadScanner.scan(directory: root).first!
        try fm.moveItem(at: partial, to: final)
        precondition(fresh.confirmedFinished)

        func meeting(_ text: String) -> URL? { PedroMeetingLink.resolve(url: nil, location: nil, notes: text) }
        precondition(meeting("Reuniao https://meet.google.com/abc-defg-hij")?.host == "meet.google.com")
        precondition(meeting("https://us02web.zoom.us/j/123?pwd=xyz") != nil)
        precondition(meeting("https://teams.microsoft.com/l/meetup-join/abc") != nil)
        for bad in ["https://meet.google.com.evil.test/abc-defg-hij", "https://evilzoom.us/j/123", "http://zoom.us/j/123", "https://user:pass@zoom.us/j/123", "https://zoom.us/", "javascript:alert(1)"] {
            precondition(meeting(bad) == nil, bad)
        }
        let now = Date()
        precondition(PedroMeetingLink.status(start: now.addingTimeInterval(61), end: now.addingTimeInterval(3600), now: now) == "Em 2 min")
        precondition(PedroMeetingLink.status(start: now.addingTimeInterval(-60), end: now.addingTimeInterval(3600), now: now) == "Agora")
        precondition(PedroMeetingLink.status(start: now.addingTimeInterval(-3600), end: now, now: now) == nil)
        let n = PedroPhoneNotification(id: "1", app: "Test", title: "Title", text: "Body")
        precondition(n.fingerprint(deviceID: "a") != n.fingerprint(deviceID: "b"))
        func phone(_ name: String, charge: Int? = 80, charging: Bool = false, paired: Bool = true, reachable: Bool = true) -> PedroPhone {
            PedroPhone(id: "phone", name: name, paired: paired, reachable: reachable, charge: charge,
                charging: charging, notifications: [], notificationsAvailable: true, canRing: true,
                canShare: true, canShareFiles: false, via: "X99")
        }
        precondition(phone("Galaxy S23 Ultra").tabName == "S23 Ultra")
        precondition(phone("Galaxy S25 Ultra").tabName == "S25 Ultra")
        precondition(phone("Galaxy Z Fold6").tabName == "Z Fold6")
        precondition(phone("Galaxy Tab S8 Plus").tabName == "Tab S8+")
        precondition(phone("Personal tablet").tabName == "Personal tablet")
        precondition(phone("Test", charge: 0).batteryText == "0%")
        precondition(phone("Test", charge: 100, charging: true).statusDescription == "100% - Carregando")
        for value in [nil, -1, 101] as [Int?] {
            precondition(phone("Test", charge: value).batteryText == "--")
        }
        let offlinePhone = phone("Test", charging: true, reachable: false)
        precondition(offlinePhone.batteryText == "--" && !offlinePhone.isCharging)
        precondition(offlinePhone.statusDescription == "Desconectado")
        precondition(phone("Test", paired: false).statusDescription == "Nao pareado")
        precondition(PedroPhoneTransferUpdate(phase: "staging", bytes: 100, total: 100).percentage == 99)
        precondition(PedroPhoneTransferUpdate(phase: "sending", bytes: 100, total: 100).isFinished == false)
        precondition(PedroPhoneTransferUpdate(phase: "completed", bytes: 100, total: 100).percentage == 100)
        precondition(PedroPhoneTransferUpdate(phase: "staging").canCancel)
        precondition(!PedroPhoneTransferUpdate(phase: "sending").canCancel)
        precondition(PedroPhoneTransferUpdate(phase: "unknown").isFinished)
        print("PedroActivityTests passed: copy, cancellation, no overwrite, dismissal restart, stale update, downloads, meeting links, phone fingerprints and battery tabs")
    }
}
