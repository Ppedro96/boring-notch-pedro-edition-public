import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PedroContinuityFeedback: View {
    @ObservedObject private var continuity = PedroContinuityProvider.shared
    var body: some View {
        if continuity.enabled {
            HStack(spacing: 4) {
                if !continuity.busy.isEmpty { ProgressView().controlSize(.mini) }
                Text(continuity.feedback ?? continuity.statusLabel).font(.system(size: 9)).lineLimit(1)
            }.foregroundStyle(.secondary).frame(height: 14).allowsHitTesting(false)
        }
    }
}
struct PedroSharedItemCard: View {
    let item: PedroContinuityItem
    let topic: String
    @ObservedObject private var continuity = PedroContinuityProvider.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: topic == "clipboard" ? (item.text("kind") == "image" ? "photo" : "doc.on.clipboard") : "arrow.down.doc")
                Text(item.origin).lineLimit(1)
                Spacer(minLength: 0)
                if continuity.busy.contains(item.id) { ProgressView().controlSize(.mini) }
                if topic == "clipboard" {
                    Button { continuity.pin(item) } label: { Image(systemName: item.flag("pinned") ? "pin.fill" : "pin") }
                }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            Button { if topic == "clipboard" { continuity.copyClipboard(item) } else { continuity.openShared(item, topic: topic) } } label: {
                Text(topic == "clipboard" ? (item.text("kind") == "image" ? "Copiar imagem" : item.text("text")) : item.text("name")).font(.system(size: 12)).lineLimit(3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).contentShape(Rectangle())
            }.disabled(continuity.busy.contains(item.id))
        }.padding(8).frame(width: 148, height: 91).background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            .buttonStyle(.plain).contextMenu {
                Button("Remover compartilhado") { continuity.remove(topic: topic, key: item.id) }
            }.help(item.text("name").isEmpty ? item.text("label") : item.text("name"))
            .onDrag { dragProvider() }
    }
    private func dragProvider() -> NSItemProvider {
        guard topic == "shelf" else { return NSItemProvider() }
        if let blob = item.payload["blob"] {
            let provider = NSItemProvider()
            let name = blob.object["name"]?.string ?? "file"
            provider.suggestedName = name
            let type = UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension) ?? .data
            provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
                Task { @MainActor in
                    do { completion(try await continuity.fetch(blob), true, nil) }
                    catch { continuity.show(error.localizedDescription); completion(nil, false, error) }
                }
                return nil
            }
            return provider
        }
        if let url = URL(string: item.text("url")), !item.text("url").isEmpty { return NSItemProvider(object: url as NSURL) }
        return NSItemProvider(object: item.text("text") as NSString)
    }
}
struct PedroSharedTaskCard: View {
    let item: PedroContinuityItem
    @ObservedObject private var continuity = PedroContinuityProvider.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.text("agent") + " · " + item.origin).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(item.text("title")).font(.system(size: 12, weight: .medium)).lineLimit(2)
            HStack(spacing: 4) {
                let status = PedroContinuityPolicy.taskStatusLabel(item.text("status")) + (Date().timeIntervalSince1970 - item.number("updatedAt") > 120 && item.text("status") != "completed" ? " · sem atualização" : "")
                Text(status).lineLimit(1).help(status)
                Spacer(minLength: 0)
                if let progress = PedroContinuityPolicy.taskProgress(item) {
                    ProgressView(value: progress, total: 100).progressViewStyle(.linear).frame(width: 32)
                    Text("\(Int(progress))%").monospacedDigit().fixedSize(horizontal: true, vertical: false)
                }
            }.font(.system(size: 10)).foregroundStyle(.secondary).frame(height: 12)
            Text(item.text("summary")).font(.system(size: 10)).lineLimit(2)
            if item.payload["blob"] != nil {
                Button("Baixar resultado") { continuity.openShared(item, topic: "tasks") }.font(.system(size: 10)).disabled(continuity.busy.contains(item.id))
            }
            Spacer(minLength: 0)
        }.padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}
struct PedroMediaHostPicker: View {
    @ObservedObject private var continuity = PedroContinuityProvider.shared
    var body: some View {
        if continuity.enabled {
            Menu {
                Picker("Reproduzir em", selection: $continuity.mediaHost) {
                    Text("Este Mac").tag("local")
                    ForEach(continuity.items("media").filter { $0.id != continuity.peer }) { item in
                        Text(item.text("host") + (PedroContinuityPolicy.mediaAvailable(item, now: Date().timeIntervalSince1970) ? "" : " · indisponível")).tag(item.id)
                    }
                }
            } label: { Label(continuity.mediaHost == "local" ? "Mac" : continuity.mediaHost, systemImage: "desktopcomputer").font(.system(size: 9)).lineLimit(1) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(height: 14)
        }
    }
}
struct PedroRemoteMediaView: View {
    @ObservedObject private var continuity = PedroContinuityProvider.shared
    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let item = continuity.items("media").first { $0.id == continuity.mediaHost }
            let available = item.map { PedroContinuityPolicy.mediaAvailable($0, now: context.date.timeIntervalSince1970) } ?? false
            VStack(alignment: .leading, spacing: 6) {
                Text(item?.text("title") ?? "Mídia indisponível").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(available ? (item?.text("artist") ?? "") : "Computador indisponível").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 18) {
                    Button { continuity.sendMedia("previous") } label: { Image(systemName: "backward.fill") }
                    Button { continuity.sendMedia("toggle") } label: { Image(systemName: item?.flag("playing") == true ? "pause.fill" : "play.fill") }
                    Button { continuity.sendMedia("next") } label: { Image(systemName: "forward.fill") }
                    Button { continuity.sendMedia("raise") } label: { Image(systemName: "arrow.up.forward.app") }
                }.buttonStyle(.plain).disabled(!available)
                if let item, item.number("duration") > 0 {
                    Slider(value: Binding(get: { min(item.number("duration"), item.number("position")) }, set: { continuity.sendMedia("seek", position: $0) }), in: 0...max(1, item.number("duration")))
                        .controlSize(.mini).disabled(!available)
                }
                PedroContinuityFeedback()
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
