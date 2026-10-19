import AppKit
import Combine
import CoreAudio
import Darwin

struct PedroMixerApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    let objects: [AudioObjectID]
    let playing: Bool
    let bypassed: Bool
    var volume: Double
    var outputUID: String?
}

struct PedroMixerOutput: Identifiable, Equatable {
    let id: String
    let name: String
}

@MainActor
final class PedroAudioMixer: ObservableObject {
    static let shared = PedroAudioMixer()
    nonisolated static let maxVolume: Double = 2
    @Published private(set) var apps: [PedroMixerApp] = []
    @Published private(set) var outputs: [PedroMixerOutput] = []
    @Published private(set) var error: String?
    @Published private(set) var busy = Set<String>()
    private var engines: [String: GainEngine] = [:]
    private var generations: [String: Int] = [:]
    private var renderCounts: [String: UInt64] = [:]
    private var timer: Timer?
    private var defaultOutputUID: String?
    private let queue = DispatchQueue(label: "pedro.mixer.hal", qos: .userInitiated)
    private var refreshing = false
    private var lifecycle = 0
    private var savedVolumes: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: "pedroMixerVolumes") as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "pedroMixerVolumes") }
    }
    private var savedRoutes: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "pedroMixerRoutes") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "pedroMixerRoutes") }
    }

    func startIfEnabled() {
        if UserDefaults.standard.bool(forKey: "pedroMixerEnabled") { start() }
    }

    func start() {
        guard #available(macOS 14.4, *) else { error = "Mixer requer macOS 14.4 ou posterior"; return }
        UserDefaults.standard.set(true, forKey: "pedroMixerEnabled")
        guard timer == nil else { refresh(); return }
        lifecycle += 1
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        lifecycle += 1
        timer?.invalidate(); timer = nil
        for engine in engines.values { engine.stop() }
        engines.removeAll(); renderCounts.removeAll(); busy.removeAll()
        for id in generations.keys { generations[id, default: 0] += 1 }
    }

    func restoreAll() {
        // Invalidate pending tap creation before restoring the whole snapshot.
        // Resetting through individual setters can create a routed tap midway.
        lifecycle += 1
        for id in generations.keys { generations[id, default: 0] += 1 }
        for engine in engines.values { engine.gain = 1; engine.stop() }
        engines.removeAll()
        renderCounts.removeAll()
        busy.removeAll()
        savedVolumes = [:]
        savedRoutes = [:]
        apps = apps.map { value in
            var app = value
            app.volume = 1
            app.outputUID = nil
            return app
        }
        error = nil
    }

    func setVolume(_ volume: Double, id: String) {
        guard let index = apps.firstIndex(where: { $0.id == id }), !apps[index].bypassed else { return }
        let value = volume.isFinite ? min(Self.maxVolume, max(0, volume)) : 1
        apps[index].volume = value
        savedVolumes[id] = value
        if let engine = engines[id], value != 1 || apps[index].outputUID != nil {
            engine.gain = Float(value)
        } else { reconcile(apps[index]) }
    }

    func setOutput(_ uid: String?, id: String) {
        guard let index = apps.firstIndex(where: { $0.id == id }), !apps[index].bypassed else { return }
        apps[index].outputUID = uid
        savedRoutes[id] = uid
        reconcile(apps[index])
    }

    func refresh() {
        guard #available(macOS 14.4, *), !refreshing, timer != nil || apps.isEmpty else { return }
        refreshing = true
        let stamp = lifecycle
        queue.async { [weak self] in
            let snapshot = Self.discover()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshing = false
                guard stamp == self.lifecycle else { return }
                self.outputs = snapshot.outputs
                self.defaultOutputUID = snapshot.defaultUID
                self.apps = snapshot.apps.map { value in
                    var app = value
                    app.volume = self.savedVolumes[app.id] ?? 1
                    app.outputUID = self.savedRoutes[app.id]
                    return app
                }
                let wanted = Set(self.apps.map(\.id))
                for id in Array(self.engines.keys) where !wanted.contains(id) {
                    self.generations[id, default: 0] += 1
                    self.engines.removeValue(forKey: id)?.stop()
                    self.renderCounts[id] = nil
                }
                for app in self.apps { self.reconcile(app) }
            }
        }
    }

    private func reconcile(_ app: PedroMixerApp) {
        guard #available(macOS 14.4, *), !app.bypassed else { return }
        let effectiveUID = app.outputUID.flatMap { uid in outputs.contains(where: { $0.id == uid }) ? uid : nil } ?? defaultOutputUID
        if app.volume == 1 && (app.outputUID == nil || app.outputUID == defaultOutputUID) {
            generations[app.id, default: 0] += 1
            engines.removeValue(forKey: app.id)?.stop()
            renderCounts[app.id] = nil
            return
        }
        guard let uid = effectiveUID else { return }
        if let engine = engines[app.id], engine.tappedObjects == app.objects, engine.outputDeviceUID == uid {
            engine.gain = Float(app.volume)
            let cycles = engine.renderCycles
            if app.playing, let previous = renderCounts[app.id], previous == cycles {
                engines.removeValue(forKey: app.id)?.stop()
                savedVolumes[app.id] = 1
                savedRoutes[app.id] = nil
                if let index = apps.firstIndex(where: { $0.id == app.id }) {
                    apps[index].volume = 1; apps[index].outputUID = nil
                }
                renderCounts[app.id] = nil
                error = "\(app.name): caminho de áudio interrompido; saída original restaurada"
            } else { renderCounts[app.id] = cycles }
            return
        }
        guard !busy.contains(app.id) else { return }
        generations[app.id, default: 0] += 1
        let generation = generations[app.id]!
        let stamp = lifecycle
        engines.removeValue(forKey: app.id)?.stop()
        renderCounts[app.id] = nil
        busy.insert(app.id)
        queue.async { [weak self] in
            let engine = TapGainEngine(objects: app.objects, gain: Float(app.volume), outputDeviceUID: uid)
            Task { @MainActor [weak self] in
                guard let self else { engine?.stop(); return }
                guard stamp == self.lifecycle, self.generations[app.id] == generation else { engine?.stop(); return }
                self.busy.remove(app.id)
                guard
                      let current = self.apps.first(where: { $0.id == app.id }),
                      current.volume != 1 || current.outputUID != nil else { engine?.stop(); return }
                let currentUID = current.outputUID.flatMap { output in
                    self.outputs.contains(where: { $0.id == output }) ? output : nil
                } ?? self.defaultOutputUID
                guard currentUID == uid, current.objects == app.objects else {
                    engine?.stop()
                    self.reconcile(current)
                    return
                }
                if let engine {
                    engine.gain = Float(current.volume)
                    self.engines[app.id] = engine
                    self.error = nil
                } else {
                    self.error = "\(app.name): não foi possível controlar áudio. Confira Gravação de Áudio do Sistema nos Ajustes."
                    self.savedVolumes[app.id] = 1
                    self.savedRoutes[app.id] = nil
                    if let index = self.apps.firstIndex(where: { $0.id == app.id }) {
                        self.apps[index].volume = 1; self.apps[index].outputUID = nil
                    }
                }
            }
        }
    }

    nonisolated static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T,
                                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }

    private nonisolated static func list(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard values.withUnsafeMutableBytes({ AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!) }) == noErr else { return [] }
        return values
    }

    @available(macOS 14.4, *)
    private nonisolated static func discover() -> (apps: [PedroMixerApp], outputs: [PedroMixerOutput], defaultUID: String?) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var defaultDevice = AudioObjectID(0)
        _ = read(system, kAudioHardwarePropertyDefaultOutputDevice, &defaultDevice)
        var defaultUID: CFString = "" as CFString
        _ = read(defaultDevice, kAudioDevicePropertyDeviceUID, &defaultUID)
        let outputs = list(system, kAudioHardwarePropertyDevices).compactMap { device -> PedroMixerOutput? in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
            var uid: CFString = "" as CFString
            var name: CFString = "" as CFString
            guard read(device, kAudioDevicePropertyDeviceUID, &uid), read(device, kAudioObjectPropertyName, &name),
                  !(name as String).contains("Pedro Notch Mixer") else { return nil }
            return PedroMixerOutput(id: uid as String, name: name as String)
        }
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var grouped: [String: PedroMixerApp] = [:]
        for object in list(system, kAudioHardwarePropertyProcessObjectList) {
            var pid: pid_t = 0
            guard read(object, kAudioProcessPropertyPID, &pid), pid != getpid() else { continue }
            var bundle: CFString = "" as CFString
            _ = read(object, kAudioProcessPropertyBundleID, &bundle)
            let bundleID = bundle as String
            var owner = running.first(where: { $0.processIdentifier == pid || $0.bundleIdentifier == bundleID ||
                ($0.bundleIdentifier.map { bundleID.hasPrefix($0 + ".") } ?? false) })
            if owner == nil {
                var parent = pid
                for _ in 0..<8 {
                    var info = proc_bsdinfo()
                    guard proc_pidinfo(parent, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { break }
                    parent = pid_t(info.pbi_ppid)
                    if let match = running.first(where: { $0.processIdentifier == parent }) { owner = match; break }
                    if parent <= 1 { break }
                }
            }
            guard let owner, let id = owner.bundleIdentifier else { continue }
            var audible: UInt32 = 0
            _ = read(object, kAudioProcessPropertyIsRunningOutput, &audible)
            let bypass = ["us.zoom.xos", "com.apple.logic10", "com.ableton.live", "com.microsoft.teams2"].contains(id)
            if let previous = grouped[id] {
                grouped[id] = PedroMixerApp(id: id, name: previous.name, icon: previous.icon,
                    objects: (previous.objects + [object]).sorted(), playing: previous.playing || audible != 0,
                    bypassed: bypass, volume: 1, outputUID: nil)
            } else {
                grouped[id] = PedroMixerApp(id: id, name: owner.localizedName ?? id, icon: owner.icon,
                    objects: [object], playing: audible != 0, bypassed: bypass, volume: 1, outputUID: nil)
            }
        }
        return (grouped.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
                outputs, (defaultUID as String).isEmpty ? nil : defaultUID as String)
    }
}
