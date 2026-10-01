import AppKit
import SwiftUI

struct PedroClipboardView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var manager = PedroClipboardManager.shared
    @FocusState private var searchFocused: Bool
    @State private var selectedID: UUID?

    private var selectedItem: PedroClipboardItem? {
        manager.filteredItems.first { $0.id == selectedID } ?? manager.filteredItems.first
    }

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Buscar no histórico", text: $manager.query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit { chooseSelected() }
                }
                .font(.system(size: 12.5, weight: .medium))
                .padding(.horizontal, 9)
                .frame(height: 27)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

                Button {
                    searchFocused = false
                    Task { await manager.captureSelectedArea() }
                } label: {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 27, height: 27)
                }
                .buttonStyle(.plain)
                .disabled(manager.isCapturingArea)
                .accessibilityLabel("Copiar print de uma área")
                .help("Selecionar área e copiar print")

                if let feedback = manager.feedback {
                    Text(feedback)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(manager.feedbackIsError ? .orange : .green)
                        .lineLimit(1)
                        .help(feedback)
                        .frame(width: 92, alignment: .trailing)
                } else {
                    Button {
                        manager.clearUnpinned()
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 27, height: 27)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Limpar itens não fixados")
                }
            }

            if manager.filteredItems.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "clipboard")
                        .font(.system(size: 20, weight: .medium))
                    Text(manager.query.isEmpty ? "O histórico aparece aqui" : "Nada encontrado")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 7) {
                            ForEach(manager.filteredItems) { item in
                                itemCard(item)
                                    .id(item.id)
                            }
                        }
                    }
                    .onChange(of: selectedID) { _, newValue in
                        guard let newValue else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            selectedID = manager.filteredItems.first?.id
            focusSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pedroClipboardShouldFocusSearch)) { _ in
            focusSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pedroClipboardShouldClose)) { _ in
            vm.close()
        }
        .onChange(of: manager.query) { _, _ in
            selectedID = manager.filteredItems.first?.id
        }
        .onMoveCommand(perform: moveSelection)
        .onExitCommand {
            manager.cancelPresentation()
        }
    }

    private func itemCard(_ item: PedroClipboardItem) -> some View {
        let selected = item.id == (selectedID ?? manager.filteredItems.first?.id)
        return Button {
            selectedID = item.id
            manager.choose(item)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon(for: item.kind))
                    Text(label(for: item.kind))
                    Spacer(minLength: 0)
                    Button {
                        manager.togglePinned(item)
                    } label: {
                        Image(systemName: item.isPinned ? "pin.fill" : "pin")
                    }
                    .buttonStyle(.plain)
                    .help(item.isPinned ? "Desafixar" : "Fixar")
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(item.isPinned ? .yellow : .secondary)

                if item.kind == .image, let url = manager.imageURL(for: item),
                   let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else {
                    Text(item.displayText)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .padding(8)
            .frame(width: 148, height: 91, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.white.opacity(0.14) : Color.white.opacity(0.075))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(selected ? Color.white.opacity(0.42) : Color.white.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(item.isPinned ? "Desafixar" : "Fixar") {
                manager.togglePinned(item)
            }
            Button("Remover", role: .destructive) {
                manager.remove(item)
            }
        }
    }

    private func focusSearch() {
        DispatchQueue.main.async {
            searchFocused = true
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let items = manager.filteredItems
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedID } ?? 0
        let next: Int
        switch direction {
        case .left, .up:
            next = max(0, current - 1)
        case .right, .down:
            next = min(items.count - 1, current + 1)
        default:
            return
        }
        selectedID = items[next].id
    }

    private func chooseSelected() {
        guard let item = selectedItem else { return }
        manager.choose(item)
    }

    private func icon(for kind: PedroClipboardKind) -> String {
        switch kind {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .file: "doc.fill"
        }
    }

    private func label(for kind: PedroClipboardKind) -> String {
        switch kind {
        case .text: "Texto"
        case .link: "Link"
        case .image: "Imagem"
        case .file: "Arquivo"
        }
    }
}
