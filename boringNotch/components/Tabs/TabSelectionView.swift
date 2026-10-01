//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import AppKit
import SwiftUI

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @EnvironmentObject private var vm: BoringViewModel
    @State private var phoneDropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            tabButton(label: "Home", icon: "house.fill", view: .home)
            tabButton(label: "Shelf", icon: "tray.fill", view: .shelf)
            tabButton(label: "Ações", icon: "bolt.fill", view: .pedroActions)
            tabButton(label: "Clips", icon: "clipboard.fill", view: .pedroClipboard)
            tabButton(label: "Links", icon: "link", view: .pedroCapture)
            tabButton(label: "Celular", icon: "iphone", view: .pedroPhone)
            tabButton(label: "Atividade · Dot e transferências", icon: "circle.dotted", view: .pedroActivity)
            tabButton(label: "Usos", icon: "terminal.fill", view: .pedroUsage)
            tabButton(label: "Alertas", icon: "bell.fill", view: .pedroAlerts)
            tabButton(label: "Mac", icon: "cpu.fill", view: .pedroMac)
            tabButton(label: "Status · X99 e NAS", icon: "externaldrive.fill", view: .pedroStatus)
            tabButton(label: "Alienware", icon: "laptopcomputer", view: .pedroAlienware)
            tabButton(label: "Proxmox", icon: "server.rack", view: .pedroProxmox)
            tabButton(label: "Stack", icon: "square.stack.3d.up.fill", view: .pedroStack)
        }
        .id("pedro-tabs-v10")
        .clipShape(Capsule())
        .animation(.easeInOut(duration: 0.12), value: coordinator.currentView)
    }

    @ViewBuilder
    private func tabButton(label: String, icon: String, view: NotchViews) -> some View {
        let button = TabButton(label: label, icon: icon, selected: coordinator.currentView == view) {
            if coordinator.currentView == .pedroClipboard,
               view != .pedroClipboard,
               let window = NSApp.keyWindow as? BoringNotchSkyLightWindow {
                window.allowsKeyboardFocus = false
                window.resignKey()
            }
            coordinator.currentView = view
        }
        .help(label)
        .foregroundStyle(view == coordinator.currentView ? .white : .gray)
        .background {
            if view == coordinator.currentView {
                Capsule()
                    .fill(Color(nsColor: .secondarySystemFill))
            }
        }
        if view == .pedroPhone {
            button.onDrop(of: [.fileURL], isTargeted: $phoneDropTargeted) { providers in
                guard !providers.isEmpty else { return false }
                vm.dropEvent = true
                coordinator.currentView = .pedroPhone
                PedroPhoneManager.shared.prepareFiles(providers: providers)
                return true
            }
            .onChange(of: phoneDropTargeted) { _, targeted in
                vm.dragDetectorTargeting = targeted
                if targeted { coordinator.currentView = .pedroPhone }
            }
        } else { button }
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
