import AppKit
import SwiftUI

struct PedroCaptureView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var manager = PedroCaptureManager.shared
    @ObservedObject private var continuity = PedroContinuityProvider.shared
    @FocusState private var editorFocused: Bool
    @State private var focusWindow: BoringNotchSkyLightWindow?
    @State private var holdingOpen = false

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.mint)
                TextField("https://…", text: $manager.draft.link)
                    .textFieldStyle(.plain)
                    .focused($editorFocused)
                    .accessibilityLabel("Link para analisar")
                Button { manager.pasteLink() } label: {
                    Image(systemName: "doc.on.clipboard").frame(width: 27, height: 27)
                }
                .buttonStyle(.plain).help("Colar link do clipboard")
            }
            .font(.system(size: 14))
            .padding(.horizontal, 8)
            .frame(height: 31)
            .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 7) {
                TextField("Título opcional", text: $manager.draft.title)
                    .font(.system(size: 14, weight: .semibold))
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Título do link")
                Menu {
                    ForEach(continuity.items("links")) { item in
                        Menu(item.text("title") + " · " + item.origin) {
                            Text(item.text("note"))
                            Button("Abrir link") { if let url = URL(string: item.text("url")), ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) } }
                            if item.payload["blob"] != nil { Button("Baixar Markdown verificado") { continuity.openShared(item, topic: "links") } }
                            Button("Remover da lista compartilhada") { continuity.remove(topic: "links", key: item.id) }
                        }
                    }
                    Divider()
                    if manager.recent.isEmpty { Text("Nenhuma captura salva") }
                    ForEach(manager.recent, id: \.path) { url in
                        Button(manager.title(for: url)) { manager.open(url) }
                    }
                } label: { Image(systemName: "clock.arrow.circlepath").frame(width: 27, height: 27) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Abrir capturas recentes no Obsidian")
                Button { manager.openInbox() } label: {
                    Image(systemName: "folder").frame(width: 27, height: 27)
                }
                .help("Abrir pasta de capturas")
                Button { Task { await manager.save() } } label: {
                    Image(systemName: manager.isSaving ? "hourglass" : "square.and.arrow.down")
                        .frame(width: 29, height: 27)
                }
                .foregroundStyle(manager.draft.sourceURL == nil ? Color.secondary : .mint)
                .disabled(manager.isSaving || manager.draft.sourceURL == nil)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Salvar link na fila de estudo do Obsidian")
            }
            .buttonStyle(.plain)
            .frame(height: 27)

            ZStack(alignment: .topLeading) {
                if manager.draft.body.isEmpty {
                    Text("Observação opcional").foregroundStyle(.tertiary)
                        .padding(.horizontal, 9).padding(.top, 4)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $manager.draft.body)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .accessibilityLabel("Observação do link")
            }
            .font(.system(size: 14))
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 6) {
                Image(systemName: hasError ? "exclamationmark.triangle" : "tray")
                Text(statusText)
                    .lineLimit(1)
                    .help(manager.feedback ?? manager.store.inboxURL.path)
                Spacer(minLength: 0)
                if let last = manager.recent.first, manager.feedback != nil, !manager.isError {
                    Button { manager.open(last) } label: { Image(systemName: "arrow.up.forward") }
                        .buttonStyle(.plain).help("Abrir última nota")
                }
                Button { releaseFocus(); vm.close() } label: {
                    Image(systemName: "xmark").frame(width: 20, height: 17)
                }
                .buttonStyle(.plain).help("Fechar captura e manter rascunho")
            }
            .font(.system(size: 12))
            .foregroundStyle(hasError ? .orange : .secondary)
            .frame(height: 19)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PedroCaptureWindowReader { window in acquireFocus(window) })
        .onDisappear { releaseFocus() }
        .onExitCommand { releaseFocus(); vm.close() }
    }

    private var hasError: Bool {
        manager.isError || (!manager.draft.isEmpty && manager.draft.sourceURL == nil)
    }

    private var statusText: String {
        continuity.feedback ?? manager.feedback ?? (hasError ? "Link inválido · HTTP ou HTTPS" : "Inbox · Para analisar e catalogar")
    }

    private func acquireFocus(_ window: NSWindow) {
        // Mirrored notches must not compete for the keyboard across displays.
        guard !holdingOpen, vm.notchState == .open,
              BoringViewCoordinator.shared.currentView == .pedroCapture,
              let window = window as? BoringNotchSkyLightWindow,
              window.screen?.frame.contains(NSEvent.mouseLocation) == true else { return }
        focusWindow = window
        holdingOpen = true
        SharingStateManager.shared.beginInteraction()
        window.allowsKeyboardFocus = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        editorFocused = true
    }

    private func releaseFocus() {
        guard holdingOpen else { return }
        holdingOpen = false
        let window = focusWindow
        focusWindow = nil
        editorFocused = false
        window?.allowsKeyboardFocus = false
        window?.resignKey()
        SharingStateManager.shared.endInteraction()
    }
}

private struct PedroCaptureWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> Reader { Reader(onWindow: onWindow) }
    func updateNSView(_ nsView: Reader, context: Context) { nsView.onWindow = onWindow }

    final class Reader: NSView {
        var onWindow: (NSWindow) -> Void
        init(onWindow: @escaping (NSWindow) -> Void) { self.onWindow = onWindow; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.onWindow(window)
            }
        }
    }
}
