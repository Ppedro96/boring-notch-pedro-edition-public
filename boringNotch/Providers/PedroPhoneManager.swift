import AppKit
import Combine

@MainActor
final class PedroPhoneManager: ObservableObject {
    static let shared = PedroPhoneManager()
    @Published private(set) var phones: [PedroPhone] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isActing = false
    @Published private(set) var error: String?
    @Published private(set) var feedback: String?
    @Published private(set) var updatedAt: Date?
    @Published private(set) var transfers: [PedroPhoneTransfer] = []
    @Published var pendingFiles: [URL] = []
    @Published var showsTransfers = false
    private var activeTransfer: String?
    private var transferProcess: PedroPhoneTransferProcess?
    private var viewers = 0
    private var timer: Timer?
    private var dismissed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "pedroPhoneDismissedV1") ?? [])
    private var hiddenApps: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "pedroPhoneHiddenAppsV1") ?? [])

    func appear() {
        viewers += 1
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func disappear() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { timer?.invalidate(); timer = nil }
    }
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let data = await Task.detached(priority: .utility) { PedroPhoneBridge.run(["snapshot"]) }.value
            if let value = try? JSONDecoder().decode(PedroPhoneSnapshot.self, from: data), let devices = value.devices {
                phones = devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                error = value.error; updatedAt = Date()
            } else {
                error = (try? JSONDecoder().decode(PedroPhoneSnapshot.self, from: data))?.error ?? "KDE Connect indisponivel"
                phones = []
            }
            isRefreshing = false
        }
    }
    func notifications(for phone: PedroPhone) -> [PedroPhoneNotification] {
        phone.notifications.filter { !hiddenApps.contains($0.app) && !dismissed.contains($0.fingerprint(deviceID: phone.id)) }
    }
    func showsApp(_ app: String) -> Bool { !hiddenApps.contains(app) }
    func setShowsApp(_ app: String, _ value: Bool) {
        if value { hiddenApps.remove(app) } else { hiddenApps.insert(app) }
        UserDefaults.standard.set(Array(hiddenApps), forKey: "pedroPhoneHiddenAppsV1")
        objectWillChange.send()
    }
    var filterApps: [String] { Set(phones.flatMap { $0.notifications.map(\.app) }).union(hiddenApps).sorted() }
    func dismiss(_ items: [PedroPhoneNotification], phone: PedroPhone) {
        dismissed.formUnion(items.map { $0.fingerprint(deviceID: phone.id) })
        UserDefaults.standard.set(Array(dismissed), forKey: "pedroPhoneDismissedV1")
        objectWillChange.send()
    }
    func openKDE() { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/KDE Connect.app")) }
    func ring(_ phone: PedroPhone) { action(["ring", phone.id], feedback: "Toque solicitado") }
    func shareFile(_ phone: PedroPhone) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.title = "Enviar para " + phone.name
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        sendFiles(panel.urls, to: phone)
    }
    func prepareFiles(_ urls: [URL]) {
        pendingFiles = urls.filter { $0.isFileURL }
        showsTransfers = true
    }
    func prepareFiles(providers: [NSItemProvider]) {
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers.prefix(50) {
                if let url = await provider.extractFileURL() { urls.append(url) }
            }
            prepareFiles(urls)
        }
    }
    func sendPending(to phone: PedroPhone) {
        let files = pendingFiles
        pendingFiles = []
        sendFiles(files, to: phone)
    }
    func sendFiles(_ urls: [URL], to phone: PedroPhone) {
        guard phone.isConnected, phone.canShare, phone.canShareFiles else {
            feedback = "Aparelho sem conexao para envio"; return
        }
        showsTransfers = true
        for url in urls {
            guard url.isFileURL, let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else {
                feedback = "Selecione arquivos, nao pastas ou atalhos"; continue
            }
            guard transfers.filter({ !$0.update.isFinished }).count < 50 else { feedback = "Fila limitada a 50 arquivos"; break }
            let job = PedroPhoneTransfer(id: UUID().uuidString, source: url, deviceID: phone.id, deviceName: phone.tabName)
            transfers.append(job)
            recordTransfer(job)
        }
        startNextTransfer()
    }
    func cancelTransfer(_ id: String) {
        guard let index = transfers.firstIndex(where: { $0.id == id }), transfers[index].update.canCancel else { return }
        if activeTransfer == id { transferProcess?.cancel() }
        else { updateTransfer(id, .init(phase: "cancelled")) }
    }
    func clearFinishedTransfers() { transfers.removeAll { $0.update.isFinished } }
    private func startNextTransfer() {
        guard activeTransfer == nil, let job = transfers.first(where: { $0.update.phase == "queued" }) else { return }
        let runner = PedroPhoneTransferProcess()
        activeTransfer = job.id; transferProcess = runner
        updateTransfer(job.id, .init(phase: job.deviceID.hasPrefix("x99:") ? "staging" : "verifying", detail: "Conectando ao KDE"))
        Task {
            let result = await Task.detached(priority: .utility) {
                if !job.deviceID.hasPrefix("x99:") {
                    let data = PedroPhoneBridge.run(["share", job.deviceID, job.source.absoluteString])
                    let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    return PedroPhoneTransferUpdate(phase: value?["ok"] as? Bool == true ? "submitted" : "failed",
                        detail: value?["ok"] as? Bool == true ? "Entregue ao KDE; chegada nao confirmada" : value?["error"] as? String ?? "Envio nao confirmado")
                }
                return runner.run(device: job.deviceID, file: job.source) { update in
                    Task { @MainActor in self.updateTransfer(job.id, update) }
                }
            }.value
            updateTransfer(job.id, result)
            activeTransfer = nil; transferProcess = nil
            startNextTransfer()
        }
    }
    private func updateTransfer(_ id: String, _ update: PedroPhoneTransferUpdate) {
        guard let index = transfers.firstIndex(where: { $0.id == id }), !transfers[index].update.isFinished else { return }
        if update.phase == "staging", ["verifying", "sending"].contains(transfers[index].update.phase) { return }
        transfers[index].update = update
        recordTransfer(transfers[index])
    }
    private func recordTransfer(_ job: PedroPhoneTransfer) {
        let state: PedroActivityState = switch job.update.phase {
        case "completed": .completed
        case "failed": .failed
        case "cancelled": .cancelled
        case "unknown", "submitted": .unknown
        default: .running
        }
        PedroActivityManager.shared.record(.init(id: "phone-" + job.id, revision: job.update.phase, kind: "transfer",
            title: job.source.lastPathComponent, detail: job.deviceName + " - " + (job.update.detail ?? job.update.title),
            state: state, updatedAt: Date(), progress: job.update.percentage, url: nil, outputPath: nil))
    }
    func shareLink(_ phone: PedroPhone) {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else {
            feedback = "A area de transferencia nao contem um link HTTP(S)"; return
        }
        let alert = NSAlert()
        alert.messageText = "Enviar link para " + phone.name + "?"
        alert.informativeText = url.absoluteString
        alert.addButton(withTitle: "Enviar")
        alert.addButton(withTitle: "Cancelar")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        action(["share", phone.id, url.absoluteString], feedback: "Link enviado ao KDE Connect")
    }
    private func action(_ arguments: [String], feedback message: String) {
        guard !isActing else { return }
        isActing = true
        Task {
            let data = await Task.detached(priority: .utility) { PedroPhoneBridge.run(arguments) }.value
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            feedback = object?["ok"] as? Bool == true ? message : object?["error"] as? String ?? "Acao nao confirmada"
            isActing = false
            refresh()
        }
    }
}
