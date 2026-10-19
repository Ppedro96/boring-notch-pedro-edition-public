import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import QuickLookUI

struct PedroDeskHost: Decodable, Identifiable {
    let id: String
    let online: Bool
    let ffmpeg: Bool?
    let transcribe: Bool?
    let error: String?
    var title: String { id == "mac" ? "Mac" : id == "x99" ? "X99" : "Alienware" }
}
struct PedroDeskJob: Decodable, Identifiable {
    let id, host, name, operation, state, detail: String
    let progress: Double?
    let output: String?
    let source: String?
    var active: Bool { state == "waiting" || state == "running" }
}
struct PedroDeskFile: Decodable, Identifiable {
    let id, name, path, root, relative, host: String
    let size: Int64
    let modified: Double
}
struct PedroAndroidApp: Decodable, Identifiable { let id, name: String }
private struct PedroDeskReply: Decodable {
    let ok: Bool?
    let error: String?
    let hosts: [PedroDeskHost]?
    let jobs: [PedroDeskJob]?
    let results: [PedroDeskFile]?
    let apps: [PedroAndroidApp]?
    let warnings: [String]?
    let output: String?
    let detail: String?
    let running: Bool?
    let connected: [String]?
    let inputMode: String?
}

@MainActor final class PedroDeskManager: ObservableObject {
    static let shared = PedroDeskManager()
    @Published var hosts: [PedroDeskHost] = []
    @Published var jobs: [PedroDeskJob] = []
    @Published var files: [PedroDeskFile] = []
    @Published var message: String? {
        didSet {
            messageExpiry?.cancel()
            guard message != nil else { return }
            messageExpiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard !Task.isCancelled else { return }
                self?.message = nil
            }
        }
    }
    private var messageExpiry: Task<Void, Never>?
    @Published var deskRunning = false
    @Published var deskBusy = false
    @Published var deskError: String?
    private var deskPolling = false
    private var deskVersion = 0
    @Published var deskConnected: [String] = []
    @Published var deskDetail = ""
    @Published var deskInputMode = "deskflow"
    @Published var searching = false
    @Published var acting = false
    @Published var previewURL: URL?
    private var fetched: [String: URL] = [:]
    @Published var query = ""
    @Published var selectedFile: URL?
    @Published var host = "auto"
    @Published var operation = "video"
    private var polling = false
    private var jobTimer: Timer?
    private var deskTimer: Timer?
    private var jobViewers = 0
    private var deskViewers = 0
    private var searchVersion = 0
    private static func execute(_ request: [String: String], helper: String = "desk-hub.py", arguments: [String] = []) async -> Data {
        let payload = (try? JSONSerialization.data(withJSONObject: request)) ?? Data()
        return await Task.detached(priority: .utility) {
            let process = Process(), output = Pipe(), errors = Pipe(), input = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/pedro-notch/" + helper).path] + arguments
            process.standardOutput = output; process.standardError = errors; process.standardInput = input
            do {
                try process.run()
                try input.fileHandleForWriting.write(contentsOf: payload)
                try input.fileHandleForWriting.close()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return data
            } catch {
                return (try? JSONSerialization.data(withJSONObject: ["ok": false, "error": error.localizedDescription])) ?? Data()
            }
        }.value
    }
    private func reply(_ data: Data) -> PedroDeskReply? {
        guard let result = try? JSONDecoder().decode(PedroDeskReply.self, from: data) else { message = "Resposta inválida da integração"; return nil }
        if result.ok == false { message = result.error ?? "Falha na integração"; return nil }
        return result
    }
    func appear() {
        jobViewers += 1
        if jobTimer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.jobViewers > 0 || self.jobs.contains(where: \.active) else { return }
                    self.poll()
                }
            }
            RunLoop.main.add(timer, forMode: .common); jobTimer = timer
        }
        refresh()
    }
    func disappear() { jobViewers = max(0, jobViewers - 1) }
    func deskAppear() {
        deskViewers += 1
        if deskTimer == nil {
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.deskViewers > 0 else { return }; self.deskflow()
                }
            }
            RunLoop.main.add(timer, forMode: .common); deskTimer = timer
        }
        deskflow()
    }
    func deskDisappear() { deskViewers = max(0, deskViewers - 1) }
    func refresh() {
        Task {
            if let result = reply(await Self.execute(["command": "capabilities"])) { hosts = result.hosts ?? [] }
        }
        poll()
    }
    func poll() {
        guard !polling else { return }; polling = true
        Task {
            defer { polling = false }
            if let result = reply(await Self.execute(["command": "jobs"])) { jobs = result.jobs ?? [] }
        }
    }
    func choose() {
        SharingStateManager.shared.beginInteraction()
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .audio]
        panel.begin { response in
            Task { @MainActor in
                if response == .OK { self.selectedFile = panel.url }
                SharingStateManager.shared.endInteraction()
            }
        }
    }
    func submit() {
        guard let source = selectedFile, !acting else { return }; acting = true; message = nil
        Task {
            defer { acting = false }
            if reply(await Self.execute(["command": "submit", "source": source.path, "host": host, "operation": operation])) != nil {
                selectedFile = nil; message = "Adicionado à fila"; poll()
            }
        }
    }
    func archiveFinished() {
        Task { _ = reply(await Self.execute(["command": "archive"])); poll() }
    }
    func retry(_ job: PedroDeskJob) {
        guard !acting else { return }; acting = true
        Task {
            defer { acting = false }
            _ = reply(await Self.execute(["command": "submit", "source": job.source ?? "", "host": job.host, "operation": job.operation])); poll()
        }
    }
    func cancel(_ job: PedroDeskJob) {
        Task { _ = reply(await Self.execute(["command": "cancel", "id": job.id])); poll() }
    }
    func search(_ query: String, host: String) {
        searchVersion += 1; let version = searchVersion
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { files = []; searching = false; return }
        searching = true; message = nil
        Task {
            let data = await Self.execute(["command": "search", "query": query, "host": host])
            guard version == searchVersion else { return }
            searching = false
            if let result = reply(data) { files = result.results ?? []; message = result.warnings?.joined(separator: " · ") }
        }
    }
    func fetch(_ file: PedroDeskFile, action: String = "reveal") {
        guard !acting else { return }
        let key = file.id + String(file.modified) + String(file.size)
        func show(_ url: URL) {
            if action == "preview" { previewURL = url }
            else if action == "open" { NSWorkspace.shared.open(url) }
            else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        if file.host == "mac" { show(URL(fileURLWithPath: file.path)); return }
        if let cached = fetched[key], FileManager.default.fileExists(atPath: cached.path) { show(cached); return }
        acting = true; message = "Recebendo " + file.name
        Task {
            defer { acting = false }
            if let result = reply(await Self.execute(["command": "fetch", "host": file.host, "root": file.root, "relative": file.relative])), let output = result.output {
                let url = URL(fileURLWithPath: output); fetched[key] = url
                message = "Recebido e verificado"; show(url)
            }
        }
    }
    func deskflow(_ action: String = "status", layout: String = "x99-left") {
        let mutation = action != "status"
        guard !deskBusy, mutation || !deskPolling else { return }
        if mutation { deskBusy = true; deskVersion += 1; deskError = nil }
        else { deskPolling = true }
        let version = deskVersion
        Task {
            let data = await Self.execute(["command": "deskflow", "action": action, "layout": layout])
            if mutation { deskBusy = false } else { deskPolling = false }
            guard version == deskVersion else { return }
            if let result = try? JSONDecoder().decode(PedroDeskReply.self, from: data), result.ok != false {
                if let running = result.running { deskRunning = running }
                if let connected = result.connected { deskConnected = connected }
                if let inputMode = result.inputMode { deskInputMode = inputMode }
                deskDetail = result.detail ?? ""
                if mutation { deskflow() }
            } else {
                deskError = (try? JSONDecoder().decode(PedroDeskReply.self, from: data))?.error ?? "Não foi possível ler a sessão"
            }
        }
    }
    func android(_ phone: PedroPhone) async -> [PedroAndroidApp] {
        message = nil
        return reply(await Self.execute([:], helper: "scrcpy-phone.py", arguments: ["apps", phone.id]))?.apps ?? []
    }
    func openApp(_ app: PedroAndroidApp, phone: PedroPhone) {
        guard !acting else { return }; acting = true; message = nil
        Task {
            defer { acting = false }
            if reply(await Self.execute([:], helper: "scrcpy-phone.py", arguments: ["app", phone.id, app.id])) != nil { message = "Abrindo " + app.name }
        }
    }
}

/// Keep new tools within existing tabs, sharing the Notch's compact card treatment.
struct PedroDeskView: View {
    @ObservedObject private var manager = PedroDeskManager.shared
    @AppStorage("pedroDeskSectionV1") private var section = "jobs"
    private var query: String { manager.query }
    @AppStorage("pedroDeskSearchSourceV1") private var source = "all"
    @State private var searchTask: Task<Void, Never>?
    @State private var previewHolding = false
    var body: some View {
        GeometryReader { geometry in
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Picker("Área de trabalho", selection: $section) {
                    Text("Cópias").tag("copies")
                    Text("Processar").tag("jobs")
                    Text("Buscar arquivos").tag("search")
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 340)
                Spacer(minLength: 0)
                if section == "jobs", manager.jobs.contains(where: { !$0.active }) {
                    Button { manager.archiveFinished() } label: { Image(systemName: "archivebox").frame(width: 24, height: 24) }.help("Arquivar tarefas finalizadas; manter resultados")
                }
                if manager.acting || manager.searching { ProgressView().controlSize(.mini) }
                Button { manager.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24) }.help("Atualizar máquinas e fila")
            }.frame(height: 26)
            if section == "copies" { PedroActivityView() }
            else if section == "search" { searchView }
            else { jobsView }
            if section != "copies" {
                let message = manager.message ?? "Resultados em Downloads/Insight Notch"
                HStack(spacing: 5) {
                    Text(message).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).help(message)
                    Spacer(minLength: 0)
                    if manager.message != nil { Button { manager.message = nil } label: { Image(systemName: "xmark").font(.system(size: 9)) }.help("Dispensar aviso") }
                }.frame(height: 16)
            }
        }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }.clipped().buttonStyle(.plain).onAppear { manager.appear() }
            .onChange(of: query) { _, _ in scheduleSearch() }
            .onChange(of: source) { _, _ in scheduleSearch() }
            .quickLookPreview($manager.previewURL)
            .onChange(of: manager.previewURL) { _, value in
                if value != nil && !previewHolding { previewHolding = true; SharingStateManager.shared.beginInteraction() }
                else if value == nil && previewHolding { previewHolding = false; SharingStateManager.shared.endInteraction() }
            }
            .onDisappear {
                searchTask?.cancel(); manager.disappear()
                if previewHolding { previewHolding = false; manager.previewURL = nil; SharingStateManager.shared.endInteraction() }
            }
    }
    private var jobsView: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button { manager.choose() } label: {
                    Label(manager.selectedFile?.lastPathComponent ?? "Selecionar mídia", systemImage: "doc.badge.plus")
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                }.help(manager.selectedFile?.path ?? "Ou arraste um vídeo ou áudio para esta área")
                Picker("Máquina", selection: $manager.host) {
                    Text("Automático").tag("auto")
                    ForEach(["mac", "x99", "alienware"], id: \.self) { id in
                        let host = manager.hosts.first { $0.id == id }
                        Text((id == "mac" ? "Mac" : id == "x99" ? "X99" : "Alienware") + (host?.online == true ? "" : " · offline")).tag(id)
                    }
                }.labelsHidden().frame(width: 112)
                Picker("Formato", selection: $manager.operation) {
                    Text("MP4 · 1080p").tag("video")
                    Text("Áudio · M4A").tag("audio")
                    Text("Transcrição").tag("transcribe")
                }.labelsHidden().frame(width: 122)
                Button { manager.submit() } label: { Image(systemName: "plus.circle.fill").font(.system(size: 16)).frame(width: 24, height: 24) }
                    .foregroundStyle(.cyan).disabled(manager.selectedFile == nil || manager.acting || !canSubmit).help("Adicionar à fila")
            }.font(.system(size: 11)).controlSize(.small).frame(height: 26).padding(.horizontal, 7).deskCard()
            ScrollView(.vertical) {
                LazyVStack(spacing: 5) {
                    if manager.jobs.isEmpty { empty("Fila vazia", icon: "tray", detail: "Mac, X99 e Alienware · um trabalho por máquina") }
                    ForEach(manager.jobs) { job in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                Text(job.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if job.active {
                                    Text("\(Int(job.progress ?? 0))%").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                                    Button { manager.cancel(job) } label: { Image(systemName: "stop.fill").frame(width: 22, height: 20) }.help("Cancelar tarefa")
                                } else if job.state == "failed" || job.state == "cancelled" {
                                    Button { manager.retry(job) } label: { Image(systemName: "arrow.clockwise").frame(width: 22, height: 20) }.help("Tentar novamente").disabled(manager.acting)
                                } else if let output = job.output {
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: output)]) } label: { Image(systemName: "folder").frame(width: 22, height: 20) }.help("Mostrar resultado")
                                }
                            }
                            Text(job.host.uppercased() + " · " + job.detail).font(.system(size: 10)).foregroundStyle(job.state == "failed" ? .orange : .secondary)
                                .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading).help(job.detail)
                            if job.active { ProgressView(value: job.progress ?? 0, total: 100).tint(.cyan).frame(height: 3) }
                        }.padding(.horizontal, 8).padding(.vertical, 5).deskCard()
                    }
                }.frame(maxWidth: .infinity)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard let first = providers.first else { return false }
            first.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                if let data = data as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    Task { @MainActor in manager.selectedFile = url }
                }
            }; return true
        }
    }
    private var canSubmit: Bool {
        if manager.host == "auto" {
            return manager.hosts.contains { $0.online && (manager.operation == "transcribe" ? $0.transcribe == true : $0.ffmpeg == true) }
        }
        guard let host = manager.hosts.first(where: { $0.id == manager.host }), host.online else { return false }
        return manager.operation == "transcribe" ? host.transcribe == true : host.ffmpeg == true
    }
    private var searchView: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Nome do arquivo · Mac, NAS, X99 e Alienware", text: $manager.query).textFieldStyle(.plain)
                    .modifier(PedroDeskKeyboard())
                Picker("Origem", selection: $source) {
                    Text("Todos").tag("all"); Text("Mac e NAS").tag("mac"); Text("X99 e NAS").tag("x99"); Text("Alienware").tag("alienware")
                }.labelsHidden().frame(width: 120)
            }.font(.system(size: 12)).padding(7).deskCard()
            ScrollView(.vertical) {
                LazyVStack(spacing: 5) {
                    if manager.files.isEmpty { empty(manager.searching ? "Buscando…" : "Busque pelo nome", icon: "doc.text.magnifyingglass", detail: "Pastas pessoais e NAS · mínimo de 2 caracteres") }
                    ForEach(manager.files) { file in
                        Button { manager.fetch(file) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: file.host == "mac" ? "doc" : "arrow.down.doc").foregroundStyle(.cyan)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                    Text(file.host.uppercased() + " · " + file.path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                    Text(Date(timeIntervalSince1970: file.modified), style: .date)
                                }.font(.system(size: 10)).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(7).deskCard().contentShape(Rectangle())
                        }.disabled(manager.acting)
                        .contextMenu {
                            Button(file.host == "mac" ? "Pré-visualizar" : "Trazer e pré-visualizar") { manager.fetch(file, action: "preview") }
                            Button(file.host == "mac" ? "Abrir" : "Trazer e abrir") { manager.fetch(file, action: "open") }
                            Button("Mostrar no Finder") { manager.fetch(file) }
                        }.help(file.host == "mac" ? "Mostrar no Finder" : "Trazer cópia verificada para Downloads/Insight Notch")
                    }
                }
            }
        }
    }
    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled else { return }; manager.search(query, host: source)
        }
    }
    private func empty(_ title: String, icon: String, detail: String) -> some View {
        VStack(spacing: 6) { Image(systemName: icon).font(.system(size: 21)); Text(title).font(.system(size: 12, weight: .medium)); Text(detail).font(.system(size: 10)) }
            .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 6)
    }
}
private extension View {
    func deskCard() -> some View {
        self.background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08)))
    }
}

struct PedroAndroidAppsView: View {
    let phone: PedroPhone
    @ObservedObject private var manager = PedroDeskManager.shared
    @State private var apps: [PedroAndroidApp] = []
    @State private var loading = false
    @State private var query = ""
    private var filtered: [PedroAndroidApp] {
        query.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Buscar aplicativo", text: $query).textFieldStyle(.plain).modifier(PedroDeskKeyboard())
                if loading { ProgressView().controlSize(.mini) }
            }.font(.system(size: 11)).frame(height: 22)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if !loading && filtered.isEmpty {
                        Text(apps.isEmpty ? "Nenhum app disponível por ADB" : "Nenhum app encontrado")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(filtered) { app in
                        Button { manager.openApp(app, phone: phone) } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "macwindow").foregroundStyle(.cyan)
                                Text(app.name).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                            }.font(.system(size: 11)).padding(5).contentShape(Rectangle())
                        }.disabled(manager.acting).help("Abrir em janela própria · " + app.id)
                    }
                }
            }
            if let message = manager.message {
                HStack {
                    Text(message).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).help(message)
                    Spacer(minLength: 0)
                    Button { manager.message = nil } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                }.frame(height: 16)
            }
        }.task(id: phone.id) { loading = true; query = ""; apps = []; apps = await manager.android(phone); loading = false }
    }
}

/// The Notch normally refuses focus. Hold it open only while this editor owns the keyboard.
private struct PedroDeskKeyboard: ViewModifier {
    @State private var window: BoringNotchSkyLightWindow?
    @State private var holding = false
    func body(content: Content) -> some View {
        content.background(PedroDeskWindowReader { candidate in
            if let candidate = candidate as? BoringNotchSkyLightWindow { window = candidate }
        })
        .simultaneousGesture(TapGesture().onEnded {
            guard let window, !holding else { return }; holding = true
            SharingStateManager.shared.beginInteraction(); window.allowsKeyboardFocus = true
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        })
        .onDisappear {
            if holding { window?.allowsKeyboardFocus = false; window?.resignKey(); SharingStateManager.shared.endInteraction(); holding = false }
        }
    }
}
private struct PedroDeskWindowReader: NSViewRepresentable {
    var found: (NSWindow) -> Void
    func makeNSView(context: Context) -> Reader { Reader(found: found) }
    func updateNSView(_ view: Reader, context: Context) { view.found = found }
    final class Reader: NSView {
        var found: (NSWindow) -> Void
        init(found: @escaping (NSWindow) -> Void) { self.found = found; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { DispatchQueue.main.async { self.found(window) } } }
    }
}

struct PedroContinuousDeskView: View {
    @ObservedObject private var manager = PedroDeskManager.shared
    @AppStorage("pedroDeskLayoutV1") private var layout = "x99-left"
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 6) {
                HStack(spacing: 7) {
                    computer(layout == "x99-left" ? "x99" : "alienware")
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 11)).foregroundStyle(.secondary)
                    computer("mac")
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 11)).foregroundStyle(.secondary)
                    computer(layout == "x99-left" ? "alienware" : "x99")
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 8) {
                    Text(manager.deskError ?? (manager.deskInputMode == "mesh" ? "⌃⌥Home · controle local" : "⌃⌥Home · voltar ao Mac")).font(.system(size: 10))
                        .foregroundStyle(manager.deskError == nil ? Color.secondary : Color.orange).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading).help(manager.deskError ?? "Teclado, mouse e área de transferência")
                    Button { manager.deskflow(manager.deskRunning ? "stop" : "start", layout: layout) } label: {
                        Label(manager.deskRunning ? "Pausar" : "Conectar", systemImage: manager.deskRunning ? "pause.fill" : "play.fill")
                    }.font(.system(size: 11, weight: .medium)).foregroundStyle(.cyan).disabled(manager.deskBusy)
                    Menu {
                        Picker("Disposição", selection: $layout) {
                            Text("X99 à esquerda").tag("x99-left")
                            Text("Alienware à esquerda").tag("alienware-left")
                        }.disabled(manager.deskRunning)
                        Divider()
                        Button("Permissões do macOS") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
                        Button("Abrir Deskflow") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Deskflow.app")) }
                    } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24).help("Disposição e ajustes")
                }.frame(height: 24)
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }.clipped().buttonStyle(.plain).onAppear { manager.deskAppear() }.onDisappear { manager.deskDisappear() }
    }
    private func computer(_ id: String) -> some View {
        let connected = id == "mac" ? manager.deskRunning : manager.deskConnected.contains(id)
        return VStack(spacing: 4) {
            InsightSemanticIcon(name: id == "alienware" ? "insight.alienware" : id == "mac" ? "laptopcomputer" : "desktopcomputer").font(.system(size: 20)).foregroundStyle(connected ? .cyan : .secondary)
            Text(id == "mac" ? "Mac" : id == "x99" ? "X99" : "Alienware").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 4) {
                Circle().fill(connected ? Color.green : .gray).frame(width: 5, height: 5)
                Text(connected ? "Conectado" : "Aguardando").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(7).deskCard().help((id == "mac" ? "Mac" : id == "x99" ? "X99" : "Alienware") + (connected ? " · conectado" : " · aguardando conexão"))
    }
}
