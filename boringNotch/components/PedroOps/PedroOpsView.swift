import SwiftUI
import AppKit

private enum PedroUsageMode: String, CaseIterable, Identifiable {
    case usage = "Uso"
    case sessions = "Sessoes"
    case history = "Histórico"

    var id: String { rawValue }
}

struct PedroOpsView: View {
    let tab: PedroOpsTabKind
    @ObservedObject private var network = PedroOpsNetworkProvider.shared

    @State private var cards: [PedroOpsCard] = []
    @State private var sessions: [PedroAgentSession] = []
    @State private var usageMode: PedroUsageMode = .usage
    @State private var alertSnapshot = PedroOpsAlertsSnapshot(alerts: [])
    @State private var alertFeedState: PedroOpsAlertFeedState = .missing
    @State private var isLoading = false
    @State private var sessionsAreLoading = false
    @State private var respondingRequestIDs = Set<String>()
    @State private var lastRemoteRefresh = Date.distantPast
    @State private var loadGeneration = 0
    @AppStorage(PedroAgentMonitor.soundEnabledKey) private var soundsEnabled = true
    @AppStorage(PedroAgentMonitor.soundNameKey) private var selectedSoundName = "Glass"
    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var visibleCards: [PedroOpsCard] {
        switch tab {
        case .usage: network.usageCards
        case .status: network.statusCards(for: PedroOpsSnapshotBuilder.defaultTargets)
        case .alienware: network.statusCards(for: [PedroOpsSnapshotBuilder.alienwareTarget])
        default: cards
        }
    }

    private var loadingNetworkCards: Bool {
        switch tab {
        case .usage: network.isLoadingUsage
        case .status: PedroOpsSnapshotBuilder.defaultTargets.contains { network.pending.contains("ssh." + $0.id) }
        case .alienware: network.pending.contains("ssh.alienware")
        default: isLoading
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if tab == .alerts {
                alertsContent
            } else if tab == .usage {
                usageContent
            } else {
                standardCardsContent
            }

            if loadingNetworkCards && tab != .usage {
                ProgressView()
                    .scaleEffect(0.45)
                    .frame(width: 18, height: 18)
                    .padding(.top, -2)
                    .padding(.trailing, -2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 0)
        .onAppear {
            loadCards()
            if tab == .usage && usageMode == .sessions {
                loadSessions()
            }
        }
        .onChange(of: tab) { _ in
            loadCards()
            if tab == .usage && usageMode == .sessions {
                loadSessions()
            }
        }
        .onReceive(refreshTimer) { _ in
            if tab == .mac {
                loadCards(showLoading: false)
            } else if tab == .alerts {
                if Date().timeIntervalSince(lastRemoteRefresh) >= 30 {
                    loadCards(showLoading: false)
                }
            } else if tab == .usage {
                if usageMode == .sessions { loadSessions(showLoading: false) }
                network.refreshUsage()
            } else if tab == .status || tab == .alienware {
                loadCards(showLoading: false)
            } else if Date().timeIntervalSince(lastRemoteRefresh) >= 15 {
                loadCards(showLoading: false)
            }
        }
        .onDisappear {
            loadGeneration += 1
            isLoading = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .pedroAgentSessionsDidChange)) { _ in
            guard tab == .usage, usageMode == .sessions else { return }
            loadSessions(showLoading: false)
        }
        .onChange(of: usageMode) { _, mode in
            if tab == .usage, mode == .sessions { loadSessions() }
        }
    }

    private var usageContent: some View {
        GeometryReader { geometry in
            let spacing = CGFloat(8)
            let headerHeight = CGFloat(26)
            let bodyHeight = CGFloat(
                PedroOpsCardLayout.bodyHeight(
                    totalHeight: Double(geometry.size.height),
                    headerHeight: Double(headerHeight),
                    spacing: 6
                )
            )

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Picker("", selection: $usageMode) {
                        ForEach(PedroUsageMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 235, height: headerHeight)

                    Spacer(minLength: 6)

                    if usageMode == .usage ? network.isLoadingUsage : sessionsAreLoading {
                        ProgressView()
                            .scaleEffect(0.45)
                            .frame(width: 18, height: 18)
                    }

                    if usageMode == .sessions {
                        sessionSoundMenu
                    }
                }
                .frame(height: headerHeight)

                if usageMode == .usage {
                    usageCardsStrip(
                        availableWidth: geometry.size.width,
                        cardHeight: bodyHeight,
                        spacing: spacing
                    )
                } else if usageMode == .history {
                    PedroUsageHistoryView()
                } else {
                    sessionCardsStrip(
                        availableWidth: geometry.size.width,
                        cardHeight: bodyHeight,
                        spacing: spacing
                    )
                }
            }
        }
    }

    private func usageCardsStrip(
        availableWidth: CGFloat,
        cardHeight: CGFloat,
        spacing: CGFloat
    ) -> some View {
        let count = max(1, visibleCards.count)
        let width = max(0, (availableWidth - spacing * CGFloat(count - 1)) / CGFloat(count))
        return HStack(spacing: spacing) {
            ForEach(visibleCards) { card in
                PedroOpsUsageCardView(card: card, width: width, height: cardHeight)
            }
        }
        .frame(width: availableWidth, height: cardHeight)
    }

    @ViewBuilder
    private func sessionCardsStrip(
        availableWidth: CGFloat,
        cardHeight: CGFloat,
        spacing: CGFloat
    ) -> some View {
        if sessions.isEmpty && !sessionsAreLoading {
            PedroAgentSessionsEmptyState(width: availableWidth, height: cardHeight)
        } else {
            let cardWidth = CGFloat(
                PedroOpsCardLayout.cardWidth(
                    cardCount: sessions.count,
                    availableWidth: Double(max(0, availableWidth)),
                    spacing: Double(spacing),
                    visibleLimit: PedroAgentSession.visibleLimit
                )
            )

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) {
                    ForEach(sessions) { session in
                        PedroAgentSessionCard(
                            session: session,
                            width: cardWidth,
                            height: cardHeight,
                            isResponding: session.approval.map {
                                respondingRequestIDs.contains($0.requestID)
                            } ?? false,
                            onOpen: { _ = PedroAgentSessionOpener.open(session) },
                            onDecision: { decision in respond(to: session, with: decision) }
                        )
                    }
                }
            }
        }
    }

    private var sessionSoundMenu: some View {
        Menu {
            Toggle("Sons", isOn: $soundsEnabled)
            Divider()
            ForEach(PedroAgentMonitor.availableSoundNames, id: \.self) { soundName in
                Button {
                    selectedSoundName = soundName
                    soundsEnabled = true
                    NSSound(named: NSSound.Name(soundName))?.play()
                } label: {
                    if selectedSoundName == soundName {
                        Label(soundName, systemImage: "checkmark")
                    } else {
                        Text(soundName)
                    }
                }
            }
        } label: {
            Image(systemName: soundsEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(soundsEnabled ? Color.white.opacity(0.9) : Color.gray)
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sons das sessoes")
    }

    private var standardCardsContent: some View {
        GeometryReader { geometry in
            let spacing = tab == .mac ? CGFloat(6) : CGFloat(8)
            let cardHeight = CGFloat(
                PedroOpsCardLayout.cardHeight(
                    availableHeight: Double(max(0, geometry.size.height))
                )
            )
            let cardWidth = CGFloat(
                PedroOpsCardLayout.cardWidth(
                    cardCount: visibleCards.count,
                    availableWidth: Double(max(0, geometry.size.width)),
                    spacing: Double(spacing),
                    visibleLimit: tab.visibleCardLimit
                )
            )

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) {
                    ForEach(visibleCards) { card in
                        if card.id == "x99" {
                            PedroOpsX99StatusCardView(card: card, width: cardWidth, height: cardHeight)
                        } else if card.id == "truenas", card.state == .active {
                            PedroOpsTrueNASStatusCardView(card: card, width: cardWidth, height: cardHeight)
                        } else if card.id == "alienware" {
                            PedroOpsAlienwareStatusCardView(card: card, width: cardWidth, height: cardHeight)
                        } else {
                            PedroOpsCardView(card: card, width: cardWidth, height: cardHeight)
                        }
                    }
                }
            }
        }
    }

    private var alertsContent: some View {
        GeometryReader { geometry in
            let spacing = CGFloat(8)
            let headerHeight = CGFloat(26)
            let contentHeight = max(0, geometry.size.height - headerHeight - 6)
            let cardHeight = CGFloat(
                PedroOpsCardLayout.cardHeight(
                    availableHeight: Double(contentHeight)
                )
            )
            let visibleCards = max(cards.count, alertSnapshot.alerts.isEmpty ? 1 : alertSnapshot.alerts.count)
            let cardWidth = CGFloat(
                PedroOpsCardLayout.cardWidth(
                    cardCount: visibleCards,
                    availableWidth: Double(max(0, geometry.size.width)),
                    spacing: Double(spacing),
                    visibleLimit: tab.visibleCardLimit
                )
            )
            let cardsByID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    alertSummaryChip
                    alertFeedChip
                    Spacer(minLength: 6)
                    if !alertSnapshot.alerts.isEmpty {
                        Button(action: clearAllAlerts) {
                            Label("Limpar tudo", systemImage: "trash")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(Color.white.opacity(0.08))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(height: headerHeight, alignment: .center)

                if alertSnapshot.alerts.isEmpty {
                    PedroOpsAlertsEmptyState(
                        feedState: alertFeedState,
                        width: max(220, geometry.size.width),
                        height: cardHeight
                    )
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: spacing) {
                            ForEach(alertSnapshot.alerts) { alert in
                                if let card = cardsByID[alert.id] {
                                    PedroOpsAlertCardView(
                                        card: card,
                                        width: cardWidth,
                                        height: cardHeight,
                                        onDismiss: { dismissAlert(alert.id) }
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var alertSummaryLabel: String {
        if alertSnapshot.alerts.isEmpty {
            return "Sem alertas visíveis"
        }

        var segments: [String] = []
        if alertSnapshot.criticalCount > 0 {
            segments.append("\(alertSnapshot.criticalCount) críticos")
        }
        if alertSnapshot.warningCount > 0 {
            segments.append("\(alertSnapshot.warningCount) alertas")
        }
        if alertSnapshot.infoCount > 0 {
            segments.append("\(alertSnapshot.infoCount) infos")
        }
        return segments.joined(separator: " · ")
    }

    private var alertSummaryChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(alertSnapshot.alerts.isEmpty ? Color.green : Color.white.opacity(0.9))
                .frame(width: 7, height: 7)
            Text(alertSummaryLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color.white.opacity(alertSnapshot.alerts.isEmpty ? 0.08 : 0.06))
        )
    }

    private var alertFeedChip: some View {
        HStack(spacing: 6) {
            Image(systemName: feedStateIcon)
                .font(.system(size: 10, weight: .semibold))
            Text(alertFeedState.label)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(feedStateColor)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(feedStateColor.opacity(0.12))
        )
    }

    private var feedStateColor: Color {
        switch alertFeedState {
        case .active:
            return .green
        case .empty:
            return .secondary
        case .missing:
            return .yellow
        case .invalid:
            return .red
        }
    }

    private var feedStateIcon: String {
        switch alertFeedState {
        case .active:
            return "dot.radiowaves.left.and.right"
        case .empty:
            return "circle.dashed"
        case .missing:
            return "tray"
        case .invalid:
            return "exclamationmark.triangle.fill"
        }
    }

    private func loadCards(showLoading: Bool = true) {
        if !showLoading && isLoading { return }

        loadGeneration += 1
        let requestGeneration = loadGeneration

        switch tab {
        case .alerts:
            isLoading = true
            lastRemoteRefresh = Date()
            DispatchQueue.global(qos: .utility).async {
                let snapshot = PedroOpsAlertsProvider.snapshot()
                let feedState = snapshot.feedState
                let nextCards = PedroOpsSnapshotBuilder().alertCards(snapshot: snapshot)
                DispatchQueue.main.async {
                    guard requestGeneration == loadGeneration else { return }
                    alertSnapshot = snapshot
                    alertFeedState = feedState
                    cards = nextCards
                    isLoading = false
                    lastRemoteRefresh = Date()
                }
            }
        case .usage:
            isLoading = false
            network.refreshUsage()
        case .status:
            isLoading = false
            network.refreshStatus(targets: PedroOpsSnapshotBuilder.defaultTargets)
        case .alienware:
            isLoading = false
            network.refreshStatus(targets: [PedroOpsSnapshotBuilder.alienwareTarget])
        case .mac:
            isLoading = true
            lastRemoteRefresh = Date()
            DispatchQueue.global(qos: .utility).async {
                let nextCards = PedroOpsSnapshotBuilder().macCards()
                DispatchQueue.main.async {
                    guard requestGeneration == loadGeneration else { return }
                    cards = nextCards
                    isLoading = false
                }
            }
        }
    }

    private func loadSessions(showLoading: Bool = true) {
        if sessionsAreLoading {
            return
        }
        sessionsAreLoading = true

        DispatchQueue.global(qos: .utility).async {
            let nextSessions = PedroAgentSessionProvider.sessions()
            DispatchQueue.main.async {
                sessions = nextSessions
                let activeRequestIDs = Set(nextSessions.compactMap { $0.approval?.requestID })
                respondingRequestIDs.formIntersection(activeRequestIDs)
                sessionsAreLoading = false
            }
        }
    }

    private func respond(to session: PedroAgentSession, with decision: PedroAgentDecision) {
        guard let approval = session.approval,
              !respondingRequestIDs.contains(approval.requestID) else {
            return
        }
        respondingRequestIDs.insert(approval.requestID)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try PedroAgentBridge.respond(to: approval.requestID, decision: decision)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    loadSessions(showLoading: false)
                }
            } catch {
                DispatchQueue.main.async {
                    respondingRequestIDs.remove(approval.requestID)
                    NSSound.beep()
                }
            }
        }
    }

    private func dismissAlert(_ alertID: String) {
        dismissAlerts([alertID])
    }

    private func clearAllAlerts() {
        dismissAlerts(alertSnapshot.alerts.map(\.id))
    }

    private func dismissAlerts(_ ids: [String]) {
        let visibleAlerts = alertSnapshot.alerts
        loadGeneration += 1
        isLoading = false
        alertSnapshot = PedroOpsAlertsSnapshot(
            alerts: visibleAlerts.filter { !ids.contains($0.id) },
            feedState: alertFeedState
        )
        cards = PedroOpsSnapshotBuilder().alertCards(snapshot: alertSnapshot)
        lastRemoteRefresh = Date()
        DispatchQueue.global(qos: .utility).async {
            PedroOpsAlertsProvider.persistDismissal(alertIDs: ids, visibleAlerts: visibleAlerts)
        }
    }
}

private struct PedroAgentSessionsEmptyState: View {
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: "terminal")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text("Nenhuma sessao recente")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Claude e Codex aparecerao aqui quando estiverem ativos")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.gray)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .secondarySystemFill).opacity(0.44))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct PedroAgentSessionCard: View {
    let session: PedroAgentSession
    let width: CGFloat
    let height: CGFloat
    let isResponding: Bool
    let onOpen: () -> Void
    let onDecision: (PedroAgentDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                PedroAgentProviderIcon(provider: session.provider)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(session.state.tint.opacity(0.16))
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(session.project ?? session.provider.title)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                }

                Spacer(minLength: 2)

                Circle()
                    .fill(session.state.tint)
                    .frame(width: 7, height: 7)
                    .help(session.state.label)
            }

            HStack(spacing: 5) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(session.state.tint)
                        .frame(width: 5, height: 5)
                    Text(session.state.compactLabel)
                        .lineLimit(1)
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(session.state.tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(session.state.tint.opacity(0.12))
                )

                if let detailLabel {
                    Text(detailLabel)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }

            if let preview = session.approval?.prompt ?? session.preview, !preview.isEmpty {
                Text(preview)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.gray)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
            }

            Spacer(minLength: 0)

            HStack(spacing: 5) {
                Button(action: onOpen) {
                    Label("Abrir", systemImage: "arrow.up.forward.app.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.white.opacity(0.09))
                        )
                }
                .buttonStyle(.plain)
                .help("Abrir sessao")

                Spacer(minLength: 0)

                if session.approval != nil {
                    if isResponding {
                        ProgressView()
                            .scaleEffect(0.45)
                            .frame(width: 51, height: 22)
                    } else {
                        sessionDecisionButton(
                            icon: "xmark",
                            color: .red,
                            help: "Negar permissao",
                            decision: .deny
                        )
                        sessionDecisionButton(
                            icon: "checkmark",
                            color: .green,
                            help: "Permitir",
                            decision: .allow
                        )
                    }
                }
            }
        }
        .padding(7)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .secondarySystemFill).opacity(0.52))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(session.state.needsAttention ? session.state.tint.opacity(0.42) : Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var detailLabel: String? {
        let values = [session.model, session.branch]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private func sessionDecisionButton(
        icon: String,
        color: Color,
        help: String,
        decision: PedroAgentDecision
    ) -> some View {
        Button { onDecision(decision) } label: {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 23, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(color.opacity(0.13))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct PedroAgentProviderIcon: View {
    let provider: PedroAgentProvider

    var body: some View {
        Group {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .padding(3)
            } else {
                Image(systemName: provider.iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private var appIcon: NSImage? {
        let identifiers: [String]
        switch provider {
        case .claude:
            identifiers = ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
        case .codex:
            identifiers = ["com.openai.codex"]
        case .opencode:
            identifiers = ["ai.opencode.desktop"]
        }

        guard let url = identifiers.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.isTemplate = false
        return icon
    }
}

private struct PedroOpsAlertsEmptyState: View {
    let feedState: PedroOpsAlertFeedState
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.green.opacity(0.18))
                    .frame(width: 30, height: 30)
                    .overlay {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.green)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Sem alertas visíveis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(feedState == .missing || feedState == .invalid ? "Não foi possível confirmar o feed remoto" : "Nenhum alerta novo desde a última leitura")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.gray)
                }
            }

            HStack(spacing: 8) {
                emptyStateBadge(label: "Local verificado", color: .green, icon: "waveform.path.ecg")
                emptyStateBadge(label: feedState.label, color: feedStateColor, icon: feedStateIcon)
            }
        }
        .padding(12)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .secondarySystemFill).opacity(0.44))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func emptyStateBadge(label: String, color: Color, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(color.opacity(0.12))
        )
    }

    private var feedStateColor: Color {
        switch feedState {
        case .active:
            return .green
        case .empty:
            return .secondary
        case .missing:
            return .yellow
        case .invalid:
            return .red
        }
    }

    private var feedStateIcon: String {
        switch feedState {
        case .active:
            return "dot.radiowaves.left.and.right"
        case .empty:
            return "circle.dashed"
        case .missing:
            return "tray"
        case .invalid:
            return "exclamationmark.triangle.fill"
        }
    }
}

private struct PedroOpsAlertCardView: View {
    let card: PedroOpsCard
    let width: CGFloat
    let height: CGFloat
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                PedroOpsCardIcon(card: card)
                    .frame(width: 22, height: 22)
                    .foregroundStyle(card.state.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(card.subtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Limpar este alerta neste Mac")
                .accessibilityLabel("Limpar alerta")
            }

            Spacer(minLength: 0)
            HStack(spacing: 7) {
                ForEach(Array(card.metrics.prefix(3)), id: \.label) { metric in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(metric.label)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(metric.value)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let footnote = card.footnote {
                Text(footnote)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(CGFloat(PedroOpsCardLayout.cardPadding))
        .frame(width: width, height: height, alignment: .topLeading)
        .background(Color(nsColor: .secondarySystemFill).opacity(0.52), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .help("\(card.title)\n\(card.footnote ?? "")")
    }
}

private struct PedroOpsUsageCardView: View {
    let card: PedroOpsCard
    let width: CGFloat
    let height: CGFloat

    private var limitLevel: InsightUsageLimitLevel {
        guard card.state == .active else { return .normal }
        return card.metrics.map { InsightUsageLimitLevel.level(percent: $0.progressPercent, style: $0.progressStyle) }.max() ?? .normal
    }

    var body: some View {
        let padding = CGFloat(PedroOpsCardLayout.cardPadding)
        let contentWidth = CGFloat(PedroOpsCardLayout.contentWidth(totalWidth: Double(width)))
        let contentHeight = CGFloat(PedroOpsCardLayout.contentHeight(totalHeight: Double(height)))
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                PedroOpsCardIcon(card: card)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(card.state.tint.opacity(0.12)))
                Text(card.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white).lineLimit(1)
                Spacer(minLength: 2)
                if card.state == .warning {
                    Text("Última leitura").font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.yellow).lineLimit(1)
                }
                if limitLevel != .normal {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(limitLevel == .critical ? Color.red : .orange)
                        .help(limitLevel == .critical ? "Limite muito próximo (95% ou mais)" : "Próximo do limite (80% ou mais)")
                } else {
                    Circle().fill(card.state.tint).frame(width: 6, height: 6).help(card.state.label)
                }
            }
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(card.metrics.prefix(2)), id: \.label) { metric in
                    metricColumn(metric)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
        .padding(padding)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(limitLevel == .normal ? Color.white.opacity(0.075) :
                    (limitLevel == .critical ? Color.red : .orange).opacity(0.30), lineWidth: 1))
        .help("\(card.subtitle). \(card.footnote ?? "")")
    }

    private func compactDetail(_ detail: String?) -> String {
        guard let detail else { return "Sem janela" }
        return detail.replacingOccurrences(of: "^(reseta|renova)\\s+", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: " de ", with: " ")
    }

    private func metricColumn(_ metric: PedroOpsMetric) -> some View {
        let level = card.state == .active ? InsightUsageLimitLevel.level(percent: metric.progressPercent, style: metric.progressStyle) : .normal
        let tint: Color = card.state == .warning ? .secondary : level == .critical ? .red : level == .warning ? .orange : .white
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(metric.value.hasSuffix("%") ? String(metric.value.dropLast()) : metric.value)
                    .font(.system(size: 31, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.85)
                if metric.value.hasSuffix("%") {
                    Text("%").font(.system(size: 16, weight: .medium)).foregroundStyle(tint.opacity(0.7))
                }
            }
            .foregroundStyle(tint)
            Text(metric.label).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.65))
            Group {
                if let percent = metric.progressPercent {
                    PedroOpsProgressBar(percent: percent, style: metric.progressStyle, isStale: card.state != .active)
                } else { Color.clear }
            }.frame(height: 4)
            Text(compactDetail(metric.detail))
                .font(.system(size: 10, weight: .regular)).foregroundStyle(.white.opacity(0.55))
                .lineLimit(1).minimumScaleFactor(0.9).help(metric.detail ?? "Sem janela")
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PedroOpsCardView: View {
    let card: PedroOpsCard
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let padding = CGFloat(PedroOpsCardLayout.cardPadding)
        let contentWidth = CGFloat(PedroOpsCardLayout.contentWidth(totalWidth: Double(width)))
        let contentHeight = CGFloat(PedroOpsCardLayout.contentHeight(totalHeight: Double(height)))

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PedroOpsCardIcon(card: card)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(card.state.tint.opacity(0.16))
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(card.subtitle)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                Spacer(minLength: 4)

                Circle()
                    .fill(card.state.tint)
                    .frame(width: 7, height: 7)
                    .help(card.state.label)
            }

            if let primary = card.metrics.first {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(primary.value)
                            .font(.system(size: primary.secondaryValue == nil ? 24 : 18, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.58)
                        Text(primary.label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.gray)
                            .lineLimit(1)
                    }
                    if let progressPercent = primary.progressPercent {
                        PedroOpsProgressBar(percent: progressPercent, style: primary.progressStyle)
                    }
                    if let secondaryValue = primary.secondaryValue {
                        Text(secondaryValue)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    if let secondaryProgressPercent = primary.secondaryProgressPercent {
                        PedroOpsProgressBar(percent: secondaryProgressPercent, style: primary.progressStyle)
                    }
                    if let detail = primary.detail {
                        Text(detail)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.gray)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
            }

            HStack(spacing: 10) {
                ForEach(Array(card.metrics.dropFirst().prefix(2)), id: \.label) { metric in
                    PedroOpsMetricColumn(metric: metric)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let footnote = card.footnote, !footnote.isEmpty {
                Text(footnote)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(width: contentWidth, alignment: .topLeading)
        .frame(height: contentHeight, alignment: .topLeading)
        .padding(padding)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .secondarySystemFill).opacity(0.52))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct PedroOpsX99StatusCardView: View {
    let card: PedroOpsCard
    let width: CGFloat
    let height: CGFloat

    private var gpuMetrics: [PedroOpsMetric] {
        card.metrics.filter { $0.label == "GPU" || $0.label.hasPrefix("GPU ") }
    }

    private var cpuSummary: String {
        let cpu = card.metrics.first { $0.label == "CPU" }?.value ?? "--"
        guard let temperature = card.metrics.first(where: { $0.label == "Temp" })?.value
            .split(separator: "/")
            .first else {
            return "CPU \(cpu)"
        }
        return "CPU \(cpu) · \(temperature)"
    }

    var body: some View {
        if gpuMetrics.isEmpty {
            PedroOpsCardView(card: card, width: width, height: height)
        } else {
            let padding = CGFloat(PedroOpsCardLayout.cardPadding)
            let contentWidth = CGFloat(PedroOpsCardLayout.contentWidth(totalWidth: Double(width)))
            let contentHeight = CGFloat(PedroOpsCardLayout.contentHeight(totalHeight: Double(height)))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    PedroOpsCardIcon(card: card)
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(card.state.tint.opacity(0.16))
                        )

                    Text(card.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Spacer(minLength: 4)
                    Text(cpuSummary)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Circle()
                        .fill(card.state.tint)
                        .frame(width: 7, height: 7)
                        .help(card.state.label)
                }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(gpuMetrics.prefix(2).enumerated()), id: \.offset) { index, metric in
                        if index > 0 {
                            Divider()
                                .overlay(Color.white.opacity(0.09))
                        }
                        PedroOpsGPUStatusRow(metric: metric)
                    }
                }
            }
            .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
            .padding(padding)
            .frame(width: width, height: height, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .secondarySystemFill).opacity(0.52))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
    }
}

private struct PedroOpsGPUStatusRow: View {
    let metric: PedroOpsMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(metric.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Spacer(minLength: 4)

                Text(metric.detail ?? "--°C")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(metric.value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("uso")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.gray)

                Spacer(minLength: 6)

                Text("VRAM")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.gray)
                Text(metric.secondaryValue ?? "-- GB")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
        }
    }
}

private struct PedroOpsTrueNASStatusCardView: View {
    let card: PedroOpsCard
    let width: CGFloat
    let height: CGFloat

    private var pools: PedroOpsMetric? {
        card.metrics.first { $0.label == "Pools" }
    }

    private var memory: PedroOpsMetric? {
        card.metrics.first { $0.label == "Memória" }
    }

    private var temperature: PedroOpsMetric? {
        card.metrics.first { $0.label == "Temp" }
    }

    var body: some View {
        let padding = CGFloat(PedroOpsCardLayout.cardPadding)
        let contentWidth = CGFloat(PedroOpsCardLayout.contentWidth(totalWidth: Double(width)))
        let contentHeight = CGFloat(PedroOpsCardLayout.contentHeight(totalHeight: Double(height)))
        let primaryPool = poolParts(pools?.value)
        let secondaryPool = poolParts(pools?.secondaryValue)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                PedroOpsCardIcon(card: card)
                    .frame(width: 25, height: 25)
                    .background(Circle().fill(card.state.tint.opacity(0.16)))

                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title)
                        .font(.system(size: 15, weight: .bold))
                }

                Spacer(minLength: 4)
                Circle()
                    .fill(card.state.tint)
                    .frame(width: 7, height: 7)
            }

            HStack(spacing: 12) {
                poolStat(primaryPool)
                Divider().overlay(Color.white.opacity(0.08))
                poolStat(secondaryPool)
            }
            .frame(maxWidth: .infinity)

            Divider().overlay(Color.white.opacity(0.08))

            HStack(spacing: 16) {
                compactStat(
                    label: "RAM",
                    value: memory?.value ?? "--",
                    detail: nil
                )
                compactStat(
                    label: "TEMPERATURA",
                    value: temperature?.value ?? "--°C",
                    detail: nil
                )
            }
        }
        .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
        .padding(padding)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .secondarySystemFill).opacity(0.52))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func poolParts(_ rawValue: String?) -> (name: String, value: String) {
        guard let rawValue else { return ("Pool", "--") }
        let parts = rawValue.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let value = parts.last, parts.count > 1 else { return (rawValue, "--") }
        return (parts.dropLast().joined(separator: " "), value)
    }

    private func poolStat(_ pool: (name: String, value: String)) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(pool.name.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(pool.value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactStat(label: String, value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PedroOpsAlienwareStatusCardView: View {
    let card: PedroOpsCard
    let width: CGFloat
    let height: CGFloat

    private var gpu: PedroOpsMetric? {
        card.metrics.first { $0.label == "GPU" || $0.label.hasPrefix("GPU ") }
    }

    private func metric(_ label: String) -> PedroOpsMetric? {
        card.metrics.first { $0.label == label }
    }

    private var modelName: String {
        let raw = metric("Modelo")?.value ?? "m16 R1"
        return raw.replacingOccurrences(of: "Alienware ", with: "")
    }

    var body: some View {
        if card.state != .active {
            PedroOpsCardView(card: card, width: width, height: height)
        } else {
            let padding = CGFloat(PedroOpsCardLayout.cardPadding)
            let contentWidth = CGFloat(PedroOpsCardLayout.contentWidth(totalWidth: Double(width)))
            let contentHeight = CGFloat(PedroOpsCardLayout.contentHeight(totalHeight: Double(height)))

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    PedroOpsCardIcon(card: card)
                        .frame(width: 27, height: 27)
                        .background(Circle().fill(card.state.tint.opacity(0.16)))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(card.title)
                            .font(.system(size: 15, weight: .bold))
                        Text("\(modelName) · SSH via X99 · \(metric("Uptime")?.value ?? "online")")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)
                    if let battery = metric("Bateria") {
                        HStack(spacing: 5) {
                            Image(systemName: batteryIcon(for: battery))
                                .font(.system(size: 11, weight: .semibold))
                            Text(battery.value)
                                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(Color.white.opacity(0.08), in: Capsule())
                    }
                    Circle()
                        .fill(card.state.tint)
                        .frame(width: 8, height: 8)
                }

                Divider().overlay(Color.white.opacity(0.08))

                HStack(spacing: 0) {
                    hardwareMetric(
                        icon: "display",
                        label: shortGPUName,
                        value: gpu?.value ?? "--",
                        auxiliary: gpu?.detail,
                        detail: "VRAM \(gpu?.secondaryValue ?? "-- GB")",
                        tint: .mint
                    )

                    metricDivider

                    hardwareMetric(
                        icon: "cpu.fill",
                        label: "CPU",
                        value: metric("CPU")?.value ?? "--",
                        auxiliary: metric("Clock")?.value,
                        detail: metric("Processador")?.value,
                        tint: .green
                    )

                    metricDivider

                    hardwareMetric(
                        icon: "memorychip.fill",
                        label: "RAM",
                        value: metric("Memória")?.value ?? "--",
                        auxiliary: nil,
                        detail: metric("Memória")?.detail,
                        tint: .blue
                    )

                    metricDivider

                    hardwareMetric(
                        icon: "internaldrive.fill",
                        label: "SSD",
                        value: metric("Disco")?.value ?? "--",
                        auxiliary: nil,
                        detail: metric("Disco")?.detail,
                        tint: .orange
                    )
                }
                .frame(maxHeight: .infinity)
            }
            .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
            .padding(padding)
            .frame(width: width, height: height, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .secondarySystemFill).opacity(0.52))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
    }

    private var gpuName: String {
        guard let label = gpu?.label,
              let name = label.split(separator: "·").last else {
            return "GPU"
        }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shortGPUName: String {
        gpuName
            .replacingOccurrences(of: " Laptop GPU", with: "")
            .replacingOccurrences(of: " GPU", with: "")
    }

    private var metricDivider: some View {
        Divider()
            .overlay(Color.white.opacity(0.08))
            .padding(.vertical, 3)
    }

    private func hardwareMetric(
        icon: String,
        label: String,
        value: String,
        auxiliary: String?,
        detail: String?,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 23, height: 23)
                    .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                Text(label)
                    .font(.system(size: 11.5, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if let auxiliary, !auxiliary.isEmpty {
                    Text(auxiliary)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func batteryIcon(for metric: PedroOpsMetric) -> String {
        if metric.detail == "carregando" {
            return "battery.100percent.bolt"
        }
        let percent = metric.progressPercent ?? 0
        if percent >= 75 { return "battery.100percent" }
        if percent >= 40 { return "battery.50percent" }
        if percent > 10 { return "battery.25percent" }
        return "battery.0percent"
    }
}

private struct PedroOpsCardIcon: View {
    let card: PedroOpsCard

    var body: some View {
        let appIcon = appIcon
        Group {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                InsightSemanticIcon(name: card.id == "alienware" ? "insight.alienware" : card.iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(card.state.tint)
            }
        }
        .padding(appIcon == nil ? 0 : 3)
    }

    private var appIcon: NSImage? {
        guard let bundleIdentifier = card.bundleIdentifier,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.isTemplate = false
        return icon
    }
}

private struct PedroOpsMetricColumn: View {
    let metric: PedroOpsMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(metric.label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.gray)
                .lineLimit(1)
            Text(metric.value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
            if let progressPercent = metric.progressPercent {
                PedroOpsProgressBar(percent: progressPercent, style: metric.progressStyle)
            }
            if let detail = metric.detail {
                Text(detail)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.gray)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
    }
}

private struct PedroOpsProgressBar: View {
    let percent: Int
    let style: PedroOpsMetricProgressStyle
    var isStale: Bool = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(tint)
                    .frame(width: max(3, geometry.size.width * CGFloat(clampedPercent) / 100))
            }
        }
        .frame(height: 4)
    }

    private var clampedPercent: Int {
        min(100, max(0, percent))
    }

    private var tint: Color {
        if isStale { return .gray }
        if style == .relative {
            return .green
        }
        if clampedPercent >= 95 {
            return .red
        }
        if clampedPercent >= 80 {
            return .orange
        }
        return .green
    }
}

private extension PedroOpsCardState {
    var tint: Color {
        switch self {
        case .active:
            return .green
        case .warning:
            return .yellow
        case .offline:
            return .red
        case .unknown:
            return .gray
        }
    }
}

private extension PedroAgentSessionState {
    var compactLabel: String {
        switch self {
        case .working:
            return "Ativa"
        case .waitingApproval:
            return "Aprovacao"
        case .waitingQuestion:
            return "Pergunta"
        case .completed:
            return "Concluida"
        case .idle:
            return "Em espera"
        case .unavailable:
            return "Indisponivel"
        }
    }

    var tint: Color {
        switch self {
        case .working:
            return .green
        case .waitingApproval:
            return .orange
        case .waitingQuestion:
            return .yellow
        case .completed:
            return .blue
        case .idle:
            return .gray
        case .unavailable:
            return .red
        }
    }
}
