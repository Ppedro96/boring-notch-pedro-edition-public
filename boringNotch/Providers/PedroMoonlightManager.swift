import AppKit
import Combine

@MainActor
final class PedroMoonlightManager: ObservableObject {
    static let shared = PedroMoonlightManager()
    @Published private(set) var hosts: [PedroMoonlightHost] = []
    @Published private(set) var feedback: String?
    @Published private(set) var isError = false
    @Published private(set) var launchingID: String?
    private var launchedApps: [String: NSRunningApplication] = [:]

    func profile(for host: PedroMoonlightHost) -> PedroMoonlightProfile {
        if let raw = UserDefaults.standard.string(forKey: "pedroMoonlightProfile." + host.id),
           let profile = PedroMoonlightProfile(rawValue: raw) { return profile }
        return host.name.localizedCaseInsensitiveContains("2012") ? .light : .current
    }

    func setProfile(_ profile: PedroMoonlightProfile, for host: PedroMoonlightHost) {
        UserDefaults.standard.set(profile.rawValue, forKey: "pedroMoonlightProfile." + host.id)
        objectWillChange.send()
    }

    var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: PedroMoonlightCatalog.bundleID)
    }

    func refresh() {
        // Read only the Moonlight domain; never copy its pairing keys into our storage.
        CFPreferencesAppSynchronize(PedroMoonlightCatalog.bundleID as CFString)
        let values = CFPreferencesCopyMultiple(nil, PedroMoonlightCatalog.bundleID as CFString,
                                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:]
        hosts = PedroMoonlightCatalog.parse(values)
    }

    func openMoonlight() {
        guard let url = applicationURL else { fail("Moonlight não encontrado"); return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
            if error != nil { Task { @MainActor in self.fail("Não foi possível abrir o Moonlight") } }
        }
    }

    func launch(_ host: PedroMoonlightHost, app: String, allowNewInstance: Bool = false) {
        guard launchingID == nil else { return }
        guard let url = applicationURL else { fail("Moonlight não encontrado"); return }
        guard let arguments = host.arguments(app: app, profile: profile(for: host)) else {
            fail("Atualize os aplicativos no Moonlight"); return
        }
        let key = host.id + "/" + app
        if let running = launchedApps[key], !running.isTerminated {
            running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            feedback = "Moonlight aberto: \(host.name)"
            isError = false
            return
        }
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: PedroMoonlightCatalog.bundleID)
        if !allowNewInstance, let running = existing.first {
            let alert = NSAlert()
            alert.messageText = "O Moonlight já está aberto"
            alert.informativeText = "Voltar à janela atual ou abrir \(host.name)? A conexão atual não será encerrada."
            alert.addButton(withTitle: "Voltar à janela atual")
            alert.addButton(withTitle: "Abrir \(host.name)")
            alert.addButton(withTitle: "Cancelar")
            SharingStateManager.shared.beginInteraction()
            defer { SharingStateManager.shared.endInteraction() }
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                return
            }
            guard response == .alertSecondButtonReturn else { return }
        }
        launchingID = host.id
        feedback = "Abrindo \(host.name)…"
        isError = false
        let configuration = NSWorkspace.OpenConfiguration()
        // Launch Services otherwise discards arguments when an app is already running.
        configuration.createsNewApplicationInstance = true
        configuration.arguments = arguments
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
            Task { @MainActor in
                self.launchingID = nil
                if error != nil || application == nil {
                    self.fail("Não foi possível iniciar a conexão")
                } else {
                    self.launchedApps[key] = application
                    self.feedback = "Conexão enviada ao Moonlight"
                }
            }
        }
    }

    private func fail(_ message: String) { feedback = message; isError = true }
}
