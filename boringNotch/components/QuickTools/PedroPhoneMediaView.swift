import SwiftUI

/// Compact transport for the selected phone; Mac playback stays in its existing view.
struct PedroPhoneMediaView: View {
    let phone: PedroPhone
    @ObservedObject private var manager = PedroPhoneManager.shared
    private var media: PedroPhoneMedia? { phone.isConnected ? phone.media : nil }
    private var available: Bool { media?.isAvailable == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                playerArtwork
                VStack(alignment: .leading, spacing: 3) {
                    Text(available ? (media?.title.isEmpty == false ? media!.title : media!.player) : "Nenhuma mídia")
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(available ? (media!.artist.isEmpty ? media!.player : media!.artist) : phone.tabName)
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            HStack(spacing: 15) {
                Spacer(minLength: 0)
                Button { manager.mediaAction("Previous", phone: phone) } label: {
                    Image(systemName: "backward.fill").frame(width: 24, height: 24).contentShape(Rectangle())
                }
                    .help("Faixa anterior no " + phone.tabName)
                Button { manager.mediaAction("PlayPause", phone: phone) } label: { Image(systemName: media?.playing == true ? "pause.fill" : "play.fill") }
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(available ? 0.065 : 0.02), in: Circle())
                    .help(media?.playing == true ? "Pausar no " + phone.tabName : "Reproduzir no " + phone.tabName)
                Button { manager.mediaAction("Next", phone: phone) } label: {
                    Image(systemName: "forward.fill").frame(width: 24, height: 24).contentShape(Rectangle())
                }
                    .help("Próxima faixa no " + phone.tabName)
                Spacer(minLength: 0)
            }.disabled(!available || manager.isActing)

        }
        .font(.system(size: 12)).buttonStyle(.plain)
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .help(available ? [media!.title, media!.artist, media!.player].filter { !$0.isEmpty }.joined(separator: " · ") : "Abra um player no " + phone.tabName)
    }
    @ViewBuilder private var playerArtwork: some View {
        if let media, media.players.count > 1 {
            Menu {
                ForEach(media.players, id: \.self) { player in
                    Button { manager.mediaAction("select", phone: phone, player: player) } label: {
                        if player == media.player { Label(player, systemImage: "checkmark") } else { Text(player) }
                    }
                }
            } label: {
                artwork.overlay(alignment: .bottomTrailing) {
                    Image(systemName: "chevron.down").font(.system(size: 6, weight: .bold))
                        .padding(2).background(.black.opacity(0.7), in: Circle())
                }
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 30, height: 30)
                .help("Escolher player: " + media.player).accessibilityLabel("Escolher player do " + phone.tabName)
        } else { artwork }
    }
    @ViewBuilder private var artwork: some View {
        if let value = media?.artwork, let url = URL(string: value), url.isFileURL,
           let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 5_000_000,
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFill().frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            Image(systemName: "music.note").foregroundStyle(.secondary)
                .frame(width: 30, height: 30).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
        }
    }
}

struct PedroPhoneReplyComposer: View {
    let notification: PedroPhoneNotification
    let phone: PedroPhone
    let cancel: () -> Void
    @ObservedObject private var manager = PedroPhoneManager.shared
    @EnvironmentObject private var vm: BoringViewModel
    @State private var focusWindow: BoringNotchSkyLightWindow?
    @State private var holdingOpen = false
    @State private var text = ""
    @State private var failure: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField("Sua resposta", text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 12)).lineLimit(1...2)
                .frame(height: 28, alignment: .topLeading)
                .padding(4).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                .focused($focused)
                .help(notification.app + " · " + notification.title)
            HStack(spacing: 7) {
                Text(failure ?? "Para " + String(notification.title.split(separator: "\n").first ?? "") )
                    .font(.system(size: 10)).foregroundStyle(failure == nil ? Color.secondary : .orange).lineLimit(1)
                    .help(failure ?? notification.title + " · " + phone.tabName)
                Spacer(minLength: 0)
                Button("Enviar") {
                    manager.reply(notification, phone: phone, text: text) { ok in
                        if ok { cancel() } else { failure = manager.feedback ?? "Não foi possível enviar" }
                    }
                }
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.green).fixedSize()
                .disabled(manager.isActing || !phone.isConnected || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf8.count > 4096)
            }.frame(height: 18)
        }

        .background(PedroPhoneReplyWindowReader { window in acquireFocus(window) })
        .onDisappear { releaseFocus() }
        .onExitCommand { cancel() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func acquireFocus(_ window: NSWindow) {
        // Only the notch on the pointer's display may receive the reply keyboard.
        guard !holdingOpen, vm.notchState == .open,
              BoringViewCoordinator.shared.currentView == .pedroPhone,
              let window = window as? BoringNotchSkyLightWindow,
              window.screen?.frame.contains(NSEvent.mouseLocation) == true else { return }
        focusWindow = window
        holdingOpen = true
        SharingStateManager.shared.beginInteraction()
        window.allowsKeyboardFocus = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        focused = true
    }

    private func releaseFocus() {
        guard holdingOpen else { return }
        holdingOpen = false
        focused = false
        focusWindow?.allowsKeyboardFocus = false
        focusWindow?.resignKey()
        focusWindow = nil
        SharingStateManager.shared.endInteraction()
    }
}

private struct PedroPhoneReplyWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> Reader { Reader(onWindow: onWindow) }
    func updateNSView(_ nsView: Reader, context: Context) { nsView.onWindow = onWindow }

    final class Reader: NSView {
        var onWindow: (NSWindow) -> Void
        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
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
