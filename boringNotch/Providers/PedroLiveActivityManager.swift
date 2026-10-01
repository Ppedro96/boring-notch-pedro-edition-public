import Combine
import EventKit
import Foundation

@MainActor
final class PedroLiveActivityManager: ObservableObject {
    static let shared = PedroLiveActivityManager()

    @Published private(set) var activeItem: PedroLiveActivity?

    private let defaults: UserDefaults
    private var queue = PedroLiveActivityQueue()
    private var stackIncidentTracker = PedroStackIncidentTracker()
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var lastStackCardIDs = Set<String>()
    private var didReceiveStackSnapshot = false
    private var lastCalendarRefreshDay: Date?

    private enum Keys {
        static let focusEndAt = "pedroLiveActivityFocusEndAt"
        static let dailyPulseDay = "pedroLiveActivityLastDailyPulse"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func start() {
        guard timer == nil else { return }

        NotificationCenter.default.publisher(for: .pedroStackDidRefresh)
            .compactMap { $0.object as? PedroStackSnapshot }
            .sink { [weak self] snapshot in
                self?.processStack(snapshot)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .pedroAgentSessionsDidChange)
            .sink { [weak self] _ in
                self?.refreshAgentActivities()
            }
            .store(in: &cancellables)

        CalendarManager.shared.$events
            .sink { [weak self] events in
                self?.refreshCalendarActivity(events: events)
            }
            .store(in: &cancellables)

        restoreFocus()
        PedroActivityManager.shared.$events
            .sink { [weak self] events in self?.refreshExternalActivities(events) }
            .store(in: &cancellables)
        refreshAgentActivities()
        refreshCalendarIfAuthorized()
        publishActive()

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        cancellables.removeAll()
    }

    private func refreshExternalActivities(_ events: [PedroActivityEvent]) {
        let now = Date()
        queue.remove { $0.kind == .externalActivity }
        for event in events {
            let expiration = event.updatedAt.addingTimeInterval(event.state.isFinished ? 10 : 3600)
            guard expiration > now else { continue }
            queue.upsert(PedroLiveActivity(id: "external." + event.id, stateKey: event.fingerprint,
                kind: .externalActivity, title: event.isDot ? "Dot" : "Transferencia",
                detail: event.progress.map { "\(Int($0))%" } ?? event.state.title,
                symbolName: event.isDot ? "circle.dotted" : "arrow.down.doc",
                tint: event.state == .failed ? .red : event.state == .waiting ? .orange : event.state == .completed ? .green : .blue,
                priority: event.state == .waiting ? .agentAttention : .information,
                createdAt: event.updatedAt, expiresAt: expiration), now: now)
        }
        publishActive(now: now)
    }

    func startFocus(minutes: Int) {
        let duration = max(1, minutes)
        let now = Date()
        let endAt = now.addingTimeInterval(TimeInterval(duration * 60))
        defaults.set(endAt.timeIntervalSince1970, forKey: Keys.focusEndAt)
        queue.upsert(
            PedroLiveActivity(
                id: "focus.current",
                stateKey: String(Int(endAt.timeIntervalSince1970)),
                kind: .focus,
                title: "Foco",
                detail: "\(duration) min",
                symbolName: "timer",
                tint: .violet,
                priority: .timely,
                createdAt: now,
                expiresAt: endAt,
                countdownEndAt: endAt
            ),
            now: now
        )
        publishActive(now: now)
    }

    func cancelFocus() {
        defaults.removeObject(forKey: Keys.focusEndAt)
        queue.remove(id: "focus.current")
        publishActive()
    }

    var isFocusRunning: Bool {
        guard let endAt = focusEndDate else { return false }
        return endAt > Date()
    }

    private var focusEndDate: Date? {
        let timestamp = defaults.double(forKey: Keys.focusEndAt)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    private func restoreFocus() {
        guard let endAt = focusEndDate else { return }
        guard endAt > Date() else {
            defaults.removeObject(forKey: Keys.focusEndAt)
            return
        }
        let now = Date()
        queue.upsert(
            PedroLiveActivity(
                id: "focus.current",
                stateKey: String(Int(endAt.timeIntervalSince1970)),
                kind: .focus,
                title: "Foco",
                detail: "Em andamento",
                symbolName: "timer",
                tint: .violet,
                priority: .timely,
                createdAt: now,
                expiresAt: endAt,
                countdownEndAt: endAt
            ),
            now: now
        )
    }

    private func tick() {
        let now = Date()
        if let endAt = focusEndDate, endAt <= now {
            defaults.removeObject(forKey: Keys.focusEndAt)
            queue.remove(id: "focus.current")
            queue.upsert(
                PedroLiveActivity(
                    id: "focus.completed.\(Int(endAt.timeIntervalSince1970))",
                    kind: .dailyPulse,
                    title: "Foco concluído",
                    detail: "Hora de respirar",
                    symbolName: "checkmark.circle.fill",
                    tint: .green,
                    priority: .information,
                    createdAt: now,
                    expiresAt: now.addingTimeInterval(6)
                ),
                now: now
            )
        }

        let today = Calendar.current.startOfDay(for: now)
        if lastCalendarRefreshDay != today {
            refreshCalendarIfAuthorized()
        }
        refreshCalendarActivity(events: CalendarManager.shared.events, now: now)
        publishActive(now: now)
    }

    private func processStack(_ snapshot: PedroStackSnapshot) {
        let now = Date()
        let cards = PedroStackSection.allCases.flatMap(snapshot.cards(for:))
        let currentIDs = Set(cards.map(\.id))

        for card in cards {
            let activityID = "stack.\(card.id)"
            switch stackIncidentTracker.transition(cardID: card.id, state: card.state) {
            case .incident:
                queue.upsert(
                    PedroLiveActivity(
                        id: activityID,
                        stateKey: "offline",
                        kind: .stackIncident,
                        title: card.title,
                        detail: "Serviço offline",
                        symbolName: card.icon,
                        tint: .red,
                        priority: .stackCritical,
                        createdAt: now
                    ),
                    now: now
                )
            case .recovery:
                queue.upsert(
                    PedroLiveActivity(
                        id: activityID,
                        stateKey: "recovered.\(Int(now.timeIntervalSince1970))",
                        kind: .stackRecovery,
                        title: card.title,
                        detail: "Online novamente",
                        symbolName: "checkmark.circle.fill",
                        tint: .green,
                        priority: .recovery,
                        createdAt: now,
                        expiresAt: now.addingTimeInterval(6)
                    ),
                    now: now
                )
            case .clear:
                queue.remove(id: activityID)
            case .none:
                break
            }
        }

        for staleID in lastStackCardIDs.subtracting(currentIDs) {
            stackIncidentTracker.remove(cardID: staleID)
            queue.remove(id: "stack.\(staleID)")
        }

        lastStackCardIDs = currentIDs
        if !didReceiveStackSnapshot {
            didReceiveStackSnapshot = true
            enqueueDailyPulseIfNeeded(snapshot: snapshot, now: now)
        }
        publishActive(now: now)
    }

    private func enqueueDailyPulseIfNeeded(snapshot: PedroStackSnapshot, now: Date) {
        let day = Self.dayKey(for: now)
        guard defaults.string(forKey: Keys.dailyPulseDay) != day else { return }

        let cards = PedroStackSection.allCases.flatMap(snapshot.cards(for:))
        let activeCount = cards.filter { $0.state == .active }.count
        let attentionCount = cards.filter { $0.state == .warning || $0.state == .offline }.count
        let detail = attentionCount == 0
            ? "\(activeCount) serviços operacionais"
            : "\(activeCount) online, \(attentionCount) em atenção"
        queue.upsert(
            PedroLiveActivity(
                id: "daily-pulse.\(day)",
                kind: .dailyPulse,
                title: "Status",
                detail: detail,
                symbolName: attentionCount == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                tint: attentionCount == 0 ? .green : .orange,
                priority: .information,
                createdAt: now,
                expiresAt: now.addingTimeInterval(7)
            ),
            now: now
        )
        defaults.set(day, forKey: Keys.dailyPulseDay)
    }

    private func refreshAgentActivities() {
        let now = Date()
        let sessions = PedroAgentSessionProvider.sessions(now: now)
        let attentionSessions = sessions.filter { $0.state.needsAttention }
        let activeIDs = Set(attentionSessions.map { "agent.\($0.id)" })

        queue.remove {
            $0.kind == .agentApproval && !activeIDs.contains($0.id)
        }

        for session in attentionSessions {
            let detail = session.state == .waitingQuestion
                ? "Aguardando resposta"
                : "Aguardando aprovação"
            queue.upsert(
                PedroLiveActivity(
                    id: "agent.\(session.id)",
                    stateKey: "\(session.state.rawValue).\(session.approval?.requestID ?? "")",
                    kind: .agentApproval,
                    title: session.provider.title,
                    detail: detail,
                    symbolName: session.provider.iconName,
                    tint: .orange,
                    priority: .agentAttention,
                    createdAt: session.updatedAt,
                    expiresAt: session.approval?.expiresAt
                ),
                now: now
            )
        }
        publishActive(now: now)
    }

    private func refreshCalendarIfAuthorized() {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else { return }
        lastCalendarRefreshDay = Calendar.current.startOfDay(for: Date())
        Task {
            await CalendarManager.shared.updateCurrentDate(Date())
        }
    }

    private func refreshCalendarActivity(events: [EventModel], now: Date = Date()) {
        let candidate = events
            .filter {
                $0.type.isEvent &&
                    !$0.isAllDay &&
                    $0.attendance != .declined &&
                    $0.end > now &&
                    $0.start <= now.addingTimeInterval(10 * 60)
            }
            .sorted { $0.start < $1.start }
            .first

        let candidateID = candidate.map { "calendar.\($0.id)" }
        queue.remove { $0.kind == .calendar && $0.id != candidateID }
        guard let event = candidate else {
            publishActive(now: now)
            return
        }

        let minutes = max(0, Int(ceil(event.start.timeIntervalSince(now) / 60)))
        let detail = event.start <= now ? "Agora" : "Em \(minutes) min"
        queue.upsert(
            PedroLiveActivity(
                id: "calendar.\(event.id)",
                stateKey: String(Int(event.start.timeIntervalSince1970)),
                kind: .calendar,
                title: event.title,
                detail: detail,
                symbolName: "calendar",
                tint: .blue,
                priority: .timely,
                createdAt: now,
                expiresAt: event.end,
                countdownEndAt: event.start
            ),
            now: now
        )
        publishActive(now: now)
    }

    private func publishActive(now: Date = Date()) {
        activeItem = queue.active(now: now)
    }

    private static func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
