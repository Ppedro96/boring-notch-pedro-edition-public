import AppKit
import Foundation

extension Notification.Name {
    static let pedroAgentSessionsDidChange = Notification.Name("pedroAgentSessionsDidChange")
}

struct PedroAgentMonitorState: Codable, Equatable {
    var handledEventIDs: [String]
    var didSeedExistingEvents: Bool

    static let empty = PedroAgentMonitorState(
        handledEventIDs: [],
        didSeedExistingEvents: false
    )

    mutating func consume(eventID: String) -> Bool {
        guard !handledEventIDs.contains(eventID) else { return false }
        handledEventIDs.append(eventID)
        if handledEventIDs.count > 500 {
            handledEventIDs.removeFirst(handledEventIDs.count - 500)
        }
        return true
    }

    mutating func seed(eventIDs: [String]) {
        for eventID in eventIDs {
            _ = consume(eventID: eventID)
        }
        didSeedExistingEvents = true
    }
}

final class PedroAgentMonitor {
    static let shared = PedroAgentMonitor()
    static let soundEnabledKey = "pedroAgentSoundEnabled"
    static let soundNameKey = "pedroAgentSoundName"
    static let availableSoundNames = ["Glass", "Ping", "Pop"]

    private var timer: Timer?
    private var state: PedroAgentMonitorState
    private var visibleEventIDs = Set<String>()
    private var activeSound: NSSound?

    private init() {
        state = Self.loadState()
    }

    func start() {
        guard timer == nil else { return }
        UserDefaults.standard.register(defaults: [
            Self.soundEnabledKey: true,
            Self.soundNameKey: "Glass"
        ])
        poll()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        try? FileManager.default.removeItem(at: PedroAgentBridge.heartbeatURL())
    }

    private func poll(now: Date = Date()) {
        try? PedroAgentBridge.writeHeartbeat(now: now)
        let events = PedroAgentBridge.activeEvents(now: now)
        let nextVisibleEventIDs = Set(events.map(\.eventID))

        if !state.didSeedExistingEvents {
            state.seed(eventIDs: events.map(\.eventID))
            Self.saveState(state)
        } else {
            var stateChanged = false
            for event in events.sorted(by: { $0.createdAt < $1.createdAt }) {
                guard state.consume(eventID: event.eventID) else { continue }
                stateChanged = true
                if shouldPlaySound(for: event) {
                    playConfiguredSound()
                }
            }
            if stateChanged {
                Self.saveState(state)
            }
        }

        guard nextVisibleEventIDs != visibleEventIDs else { return }
        visibleEventIDs = nextVisibleEventIDs
        NotificationCenter.default.post(name: .pedroAgentSessionsDidChange, object: nil)
    }

    private func shouldPlaySound(for event: PedroAgentBridgeEvent) -> Bool {
        guard UserDefaults.standard.bool(forKey: Self.soundEnabledKey) else { return false }
        return event.kind == .permissionRequest ||
            event.kind == .question ||
            event.kind == .completed
    }

    private func playConfiguredSound() {
        let configured = UserDefaults.standard.string(forKey: Self.soundNameKey) ?? "Glass"
        let soundName = Self.availableSoundNames.contains(configured) ? configured : "Glass"
        let path = "/System/Library/Sounds/\(soundName).aiff"
        activeSound = NSSound(contentsOfFile: path, byReference: true)
        activeSound?.play()
    }

    private static func stateURL() -> URL {
        PedroAgentBridge.baseDirectory().appendingPathComponent("monitor_state.json")
    }

    private static func loadState() -> PedroAgentMonitorState {
        guard let data = try? Data(contentsOf: stateURL()),
              let state = try? JSONDecoder().decode(PedroAgentMonitorState.self, from: data) else {
            return .empty
        }
        return state
    }

    private static func saveState(_ state: PedroAgentMonitorState) {
        let url = stateURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
