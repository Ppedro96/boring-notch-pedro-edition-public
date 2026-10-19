import SwiftUI
import AppKit

struct PedroMixerView: View {
    @ObservedObject private var mixer = PedroAudioMixer.shared
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Áudio por aplicativo").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Restaurar 100%") { mixer.restoreAll() }
                Button { mixer.refresh() } label: { Image(systemName: "arrow.clockwise") }
                Button {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                } label: { Image(systemName: "lock.shield") }.help("Permissão para gravar áudio do sistema")
            }.font(.system(size: 11)).buttonStyle(.plain)
            if let error = mixer.error {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
            }
            if mixer.apps.isEmpty {
                Text("Abra um app e reproduza áudio para aparecer aqui")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(mixer.apps) { app in
                            HStack(spacing: 8) {
                                if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 23, height: 23) }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(app.bypassed ? "Áudio gerenciado pelo app" : (app.playing ? "Reproduzindo" : "Pronto"))
                                        .font(.system(size: 9)).foregroundStyle(.secondary)
                                }.frame(width: 115, alignment: .leading)
                                if !app.bypassed {
                                    Button { mixer.setVolume(app.volume == 0 ? 1 : 0, id: app.id) } label: {
                                        Image(systemName: app.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    }.buttonStyle(.plain).frame(width: 18).help("Silenciar ou restaurar")
                                    Slider(value: Binding(get: {
                                        mixer.apps.first(where: { $0.id == app.id })?.volume ?? 1
                                    }, set: { mixer.setVolume($0, id: app.id) }), in: 0...2)
                                    Text("\(Int(app.volume * 100))%")
                                        .font(.system(size: 11, design: .monospaced)).frame(width: 39)
                                    Menu {
                                        Button("Saída do sistema") { mixer.setOutput(nil, id: app.id) }
                                        ForEach(mixer.outputs) { output in
                                            Button(output.name) { mixer.setOutput(output.id, id: app.id) }
                                        }
                                    } label: {
                                        Image(systemName: app.outputUID == nil ? "hifispeaker" : "arrow.triangle.branch")
                                    }.menuStyle(.borderlessButton).frame(width: 24)
                                    .help(app.outputUID.flatMap { uid in mixer.outputs.first(where: { $0.id == uid })?.name } ?? "Saída do sistema")
                                    if mixer.busy.contains(app.id) { ProgressView().controlSize(.mini) }
                                } else { Spacer() }
                            }.padding(.horizontal, 8).padding(.vertical, 6)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
            }
        }.padding(.horizontal, 4).padding(.bottom, 3)
        .onAppear { mixer.start() }
    }
}
