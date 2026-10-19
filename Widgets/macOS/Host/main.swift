import AppKit
import SwiftUI
import WidgetKit

if CommandLine.arguments.contains("--reload") {
    WidgetCenter.shared.reloadAllTimelines()
    exit(0)
}
class HostDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = VStack(alignment: .leading, spacing: 20) {
            Text("Baterias Galaxy").font(.title2.bold())
            BatteriesPanel(snapshot: .read(), date: Date()).frame(height: 140)
                .padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            Text("No desktop, clique com o botão direito → Editar Widgets → Baterias Galaxy.\nEste widget mostra apenas os quatro Samsung. Mantenha o widget Baterias da Apple para o Mac e seus acessórios.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Atualizar widget") { WidgetCenter.shared.reloadAllTimelines() }
        }.padding(24).frame(width: 450)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 410),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window?.title = "Insight Batteries"
        window?.contentView = NSHostingView(rootView: view)
        window?.center(); window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let delegate = HostDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
