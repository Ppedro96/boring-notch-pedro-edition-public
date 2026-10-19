// WindowServer capture adapter derived from Vorssaint WindowPreviewProvider.
// Copyright 2026 Vorssaint. SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import ApplicationServices
import ScreenCaptureKit
import SwiftUI
import OSLog

struct PedroDockWindow: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let bounds: CGRect
    let icon: NSImage?
    var preview: NSImage?
    var captureFailed = false
}

@MainActor
final class PedroDockPreview: ObservableObject {
    static let shared = PedroDockPreview()
    static let enabledKey = "pedroDockPreviewEnabled"
    @Published private(set) var windows: [PedroDockWindow] = []
    @Published private(set) var appName = ""
    @Published private(set) var hasCapturePermission = false
    private var timer: Timer?
    private var panel: NSPanel?
    private var captureTask: Task<Void, Never>?
    private var hoveredPID: pid_t?
    private var candidatePID: pid_t?
    private var candidateSince = Date.distantPast
    private var lastInside = Date.distantPast
    private var anchor = CGRect.zero
    private let system = AXUIElementCreateSystemWide()

    private init() { AXUIElementSetMessagingTimeout(system, 0.1) }

    func start() {
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
        guard timer == nil else { return }
        Logger(subsystem: "theboringteam.boringnotch", category: "PedroDockPreview").notice(
            "Dock previews started: Accessibility=\(AXIsProcessTrusted(), privacy: .public), ScreenRecording=\(CGPreflightScreenCaptureAccess(), privacy: .public)")
        timer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() { timer?.invalidate(); timer = nil; hide() }

    func requestPermissions() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
    }

    private func tick() {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey), AXIsProcessTrusted(),
              !NSWorkspace.shared.runningApplications.contains(where: {
                  $0.bundleIdentifier == "com.apple.ScreenSaver.Engine"
              }) else { hide(); return }
        let point = NSEvent.mouseLocation
        if let panel, panel.isVisible {
            // The narrow bridge between icon and preview permits crossing the gap.
            let bridge: CGRect
            if panel.frame.minY >= anchor.maxY || panel.frame.maxY <= anchor.minY {
                bridge = CGRect(x: anchor.minX, y: min(anchor.minY, panel.frame.minY),
                                width: anchor.width, height: max(anchor.maxY, panel.frame.maxY) - min(anchor.minY, panel.frame.minY))
            } else {
                bridge = CGRect(x: min(anchor.minX, panel.frame.minX), y: anchor.minY,
                                width: max(anchor.maxX, panel.frame.maxX) - min(anchor.minX, panel.frame.minX), height: anchor.height)
            }
            if panel.frame.contains(point) || bridge.contains(point) {
                lastInside = Date()
                return
            }
        }
        guard nearScreenEdge(point), let hit = dockHit(point) else {
            candidatePID = nil
            if Date().timeIntervalSince(lastInside) > 0.4 { hide() }
            return
        }
        lastInside = Date()
        if hit.app.processIdentifier == hoveredPID { return }
        if candidatePID != hit.app.processIdentifier {
            candidatePID = hit.app.processIdentifier
            candidateSince = Date()
            return
        }
        guard Date().timeIntervalSince(candidateSince) >= 0.3 else { return }
        show(app: hit.app, iconFrame: hit.frame)
    }

    private func nearScreenEdge(_ point: CGPoint) -> Bool {
        NSScreen.screens.contains { screen in
            screen.frame.contains(point) && (point.x - screen.frame.minX < 160 || screen.frame.maxX - point.x < 160 || point.y - screen.frame.minY < 160)
        }
    }

    private func dockHit(_ point: CGPoint) -> (app: NSRunningApplication, frame: CGRect)? {
        guard let dock = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" }),
              let top = NSScreen.screens.first?.frame.maxY else { return nil }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(top - point.y), &hit) == .success else { return nil }
        var current = hit
        for _ in 0..<5 {
            guard let element = current else { break }
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            guard pid == dock.processIdentifier else { return nil }
            let url = attribute(element, kAXURLAttribute) as? URL
            let title = attribute(element, kAXTitleAttribute) as? String
            let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            let app = apps.first { app in
                if let url { return app.bundleURL?.standardizedFileURL == url.standardizedFileURL }
                return title != nil && app.localizedName == title
            }
            if let app, let frame = frame(element) {
                return (app, CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height))
            }
            current = attribute(element, kAXParentAttribute).flatMap {
                CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
            }
        }
        return nil
    }

    private func show(app: NSRunningApplication, iconFrame: CGRect) {
        captureTask?.cancel()
        guard let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.2)
        let appWindows = (attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []).filter {
            (attribute($0, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole
        }
        var matchedWindows = Set<Int>()
        windows = info.compactMap { value in
            guard (value[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                  (value[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = value[kCGWindowNumber as String] as? NSNumber,
                  let raw = value[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary), bounds.width >= 100, bounds.height >= 60 else { return nil }
            // WindowServer also lists invisible backing/helper windows. Only show a
            // real app window once, including minimized windows that can be restored.
            guard let match = appWindows.indices.first(where: { index in
                guard !matchedWindows.contains(index), let rect = frame(appWindows[index]) else { return false }
                return abs(rect.minX - bounds.minX) < 4 && abs(rect.minY - bounds.minY) < 4 &&
                    abs(rect.width - bounds.width) < 4 && abs(rect.height - bounds.height) < 4
            }), (value[kCGWindowIsOnscreen as String] as? Bool == true ||
                     attribute(appWindows[match], kAXMinimizedAttribute) as? Bool == true) else { return nil }
            matchedWindows.insert(match)
            return PedroDockWindow(id: id.uint32Value, pid: app.processIdentifier,
                                   title: attribute(appWindows[match], kAXTitleAttribute) as? String ?? app.localizedName ?? "Janela",
                                   bounds: bounds, icon: app.icon)
        }
        windows = Array(windows.prefix(24))
        guard !windows.isEmpty else { hide(); return }
        hoveredPID = app.processIdentifier
        appName = app.localizedName ?? "Aplicativo"
        anchor = iconFrame
        hasCapturePermission = CGPreflightScreenCaptureAccess()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let screen = NSScreen.screens.first(where: { $0.frame.contains(iconFrame.center) }) ?? NSScreen.main!
        let area = screen.visibleFrame
        let width = min(CGFloat(min(windows.count, 3)) * 194 + 24, area.width - 20)
        let height: CGFloat = 183
        let orientation = CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String ?? "bottom"
        var origin = CGPoint(x: iconFrame.midX - width / 2, y: iconFrame.maxY + 10)
        if orientation == "left" { origin = CGPoint(x: iconFrame.maxX + 10, y: iconFrame.midY - height / 2) }
        if orientation == "right" { origin = CGPoint(x: iconFrame.minX - width - 10, y: iconFrame.midY - height / 2) }
        origin.x = min(max(origin.x, area.minX + 6), area.maxX - width - 6)
        origin.y = min(max(origin.y, area.minY + 6), area.maxY - height - 6)
        panel.setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
        panel.orderFrontRegardless()
        lastInside = Date()
        guard hasCapturePermission else { return }
        let targets = windows
        captureTask = Task { [weak self] in
            do {
                var pending: [PedroDockWindow] = []
                for target in targets {
                    guard !Task.isCancelled, let self else { return }
                    if let image = await PedroDockWindowCapture.capture(target.id),
                       !Task.isCancelled, self.hoveredPID == target.pid,
                       let index = self.windows.firstIndex(where: { $0.id == target.id }) {
                        self.windows[index].preview = NSImage(cgImage: image, size: .zero)
                    } else { pending.append(target) }
                }
                guard !pending.isEmpty else { return }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                for target in pending {
                    guard !Task.isCancelled, let self else { return }
                    guard let window = content.windows.first(where: { $0.windowID == target.id }) ?? content.windows.first(where: {
                        $0.owningApplication?.processID == target.pid &&
                        abs($0.frame.minX - target.bounds.minX) < 4 && abs($0.frame.minY - target.bounds.minY) < 4 &&
                        abs($0.frame.width - target.bounds.width) < 4 && abs($0.frame.height - target.bounds.height) < 4
                    }) else {
                        Logger(subsystem: "theboringteam.boringnotch", category: "PedroDockPreview")
                            .error("Window unavailable in ScreenCaptureKit")
                        self.markCaptureFailed(target.id); continue
                    }
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    let config = SCStreamConfiguration()
                    let scale = min(560 / max(window.frame.width, 1), 360 / max(window.frame.height, 1))
                    config.width = max(1, Int(window.frame.width * scale))
                    config.height = max(1, Int(window.frame.height * scale))
                    config.showsCursor = false
                    do {
                        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                        guard !Task.isCancelled, self.hoveredPID == target.pid,
                              let index = self.windows.firstIndex(where: { $0.id == target.id }) else { continue }
                        self.windows[index].preview = NSImage(cgImage: image, size: .zero)
                    } catch {
                        guard !Task.isCancelled else { return }
                        Logger(subsystem: "theboringteam.boringnotch", category: "PedroDockPreview")
                            .error("Window capture failed: \((error as NSError).code, privacy: .public)")
                        self.markCaptureFailed(target.id)
                    }
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                Logger(subsystem: "theboringteam.boringnotch", category: "PedroDockPreview")
                    .error("Window enumeration failed: \((error as NSError).code, privacy: .public)")
                for target in targets { self.markCaptureFailed(target.id) }
            }
        }
    }

    private func markCaptureFailed(_ id: CGWindowID) {
        if let index = windows.firstIndex(where: { $0.id == id }) { windows[index].captureFailed = true }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: PedroDockPreviewView(service: self))
        return panel
    }

    func activate(_ window: PedroDockWindow) {
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { hide(); return }
        let application = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        if let list = attribute(application, kAXWindowsAttribute) as? [AXUIElement] {
            // Match geometry as well as title: apps can have several same-title windows.
            let matches = list.filter { element in
                guard let rect = frame(element) else { return false }
                return abs(rect.minX - window.bounds.minX) < 4 && abs(rect.minY - window.bounds.minY) < 4 &&
                    abs(rect.width - window.bounds.width) < 4 && abs(rect.height - window.bounds.height) < 4
            }
            let titled = list.filter { (attribute($0, kAXTitleAttribute) as? String) == window.title }
            let chosen = matches.count == 1 ? matches.first : (titled.count == 1 ? titled.first : nil)
            app.activate(options: [])
            if let chosen {
                AXUIElementSetAttributeValue(chosen, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                AXUIElementSetAttributeValue(chosen, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(chosen, kAXRaiseAction as CFString)
            }
        } else { app.activate(options: []) }
        hide()
    }

    private func hide() {
        panel?.orderOut(nil)
        captureTask?.cancel()
        captureTask = nil
        hoveredPID = nil
        windows = []
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}

private enum PedroDockWindowCapture {
    private typealias Capture = @convention(c) (UInt32, UnsafeMutablePointer<UInt32>, UInt32, UInt32) -> Unmanaged<CFArray>?
    private static let queue = DispatchQueue(label: "pedro.dock.window-capture", qos: .userInitiated)
    private static let captureFunction: Capture? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSHWCaptureWindowList") else { return nil }
        return unsafeBitCast(symbol, to: Capture.self)
    }()
    private static let connection: UInt32 = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSMainConnectionID") else { return 0 }
        typealias Connection = @convention(c) () -> UInt32
        return unsafeBitCast(symbol, to: Connection.self)()
    }()

    static func capture(_ windowID: CGWindowID) async -> CGImage? {
        guard CGPreflightScreenCaptureAccess(), connection != 0, let capture = captureFunction else { return nil }
        return await withCheckedContinuation { continuation in
            queue.async {
                var id = UInt32(windowID)
                guard let images = capture(connection, &id, 1, (1 << 8) | (1 << 11))?.takeRetainedValue(),
                      CFArrayGetCount(images) > 0, let value = CFArrayGetValueAtIndex(images, 0) else {
                    continuation.resume(returning: nil); return
                }
                let candidate = unsafeBitCast(value, to: CFTypeRef.self)
                guard CFGetTypeID(candidate) == CGImage.typeID else { continuation.resume(returning: nil); return }
                let image = unsafeBitCast(candidate, to: CGImage.self)
                guard image.width > 1, image.height > 1 else { continuation.resume(returning: nil); return }
                let scale = min(1, min(560 / CGFloat(image.width), 360 / CGFloat(image.height)))
                let width = max(1, Int(CGFloat(image.width) * scale)), height = max(1, Int(CGFloat(image.height) * scale))
                guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    continuation.resume(returning: nil); return
                }
                bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                continuation.resume(returning: bitmap.makeImage())
            }
        }
    }
}

private extension CGRect { var center: CGPoint { CGPoint(x: midX, y: midY) } }

private struct PedroDockPreviewView: View {
    @ObservedObject var service: PedroDockPreview
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(service.appName).font(.system(size: 13, weight: .semibold))
                Spacer()
                if !service.hasCapturePermission {
                    Button("Autorizar miniaturas") { service.requestPermissions() }.font(.system(size: 11))
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(service.windows) { window in
                        Button { service.activate(window) } label: {
                            VStack(spacing: 5) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06))
                                    if let image = window.preview {
                                        Image(nsImage: image).resizable().scaledToFit()
                                    } else if window.captureFailed || !service.hasCapturePermission {
                                        Text(service.hasCapturePermission ? "Captura indisponível" : "Autorize a captura de tela")
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                    } else {
                                        ProgressView().controlSize(.small)
                                    }
                                }.frame(width: 184, height: 113).clipShape(RoundedRectangle(cornerRadius: 7))
                                Text(window.title).font(.system(size: 11)).lineLimit(1).frame(width: 184)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).help(window.title)
                    }
                }
            }
        }.padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .preferredColorScheme(.dark)
    }
}
