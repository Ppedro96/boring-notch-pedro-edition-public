import AppKit
import UserNotifications

@MainActor
final class PedroPhoneNativeNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PedroPhoneNativeNotifications()
    private let center = UNUserNotificationCenter.current()
    private var ledger = PedroPhoneNotificationLedger()
    private var enabled = false
    private var delivered: Set<String> = []
    private var appActivation: NSObjectProtocol?
    private var workspaceActivation: NSObjectProtocol?
    private let replyCategory = "PEDRO_PHONE_REPLY"
    private let plainCategory = "PEDRO_PHONE_MESSAGE"

    func start() {
        center.delegate = self
        let reply = UNTextInputNotificationAction(identifier: "PEDRO_PHONE_REPLY_SEND", title: "Responder",
            options: [.authenticationRequired], textInputButtonTitle: "Enviar", textInputPlaceholder: "Sua resposta")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: replyCategory, actions: [reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: plainCategory, actions: [], intentIdentifiers: [])
        ])
        if appActivation == nil {
            appActivation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refreshAuthorization() } }
            workspaceActivation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refreshAuthorization() } }
        }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshAuthorization() }
        }
    }
    private func refreshAuthorization() {
        center.getNotificationSettings { [weak self] settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            Task { @MainActor in
                guard let self, self.enabled != allowed else { return }
                self.enabled = allowed
                PedroPhoneManager.shared.setNativeNotifications(allowed)
            }
        }
    }

    func testNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Insight Notch"
        content.subtitle = "Celulares"
        content.body = "Os avisos dos celulares aparecem aqui. Mensagens compativeis terao a acao Responder."
        content.categoryIdentifier = plainCategory
        center.add(UNNotificationRequest(identifier: "phone-notification-test", content: content, trigger: nil))
    }
    func consume(_ phones: [PedroPhone], hiddenApps: Set<String>) {
        let active = Set(phones.filter(\.isConnected).flatMap { phone in
            phone.notifications.filter { !hiddenApps.contains($0.app) }.map { "phone-" + phone.id + "-" + $0.id }
        })
        let removed = delivered.subtracting(active)
        if !removed.isEmpty { center.removeDeliveredNotifications(withIdentifiers: Array(removed)) }
        delivered.formIntersection(active)
        for phone in phones {
            let additions = ledger.additions(phone)
            guard enabled else { continue }
            for item in additions where !hiddenApps.contains(item.app) {
                let content = UNMutableNotificationContent()
                content.title = item.app + " · " + phone.tabName
                content.subtitle = item.title
                content.body = item.text
                content.threadIdentifier = "phone-" + phone.id + "-" + item.app
                content.categoryIdentifier = item.canReply ? replyCategory : plainCategory
                content.sound = .default
                content.userInfo = ["device": phone.id, "notification": item.id, "replyID": item.replyID ?? ""]
                let id = "phone-" + phone.id + "-" + item.id
                delivered.insert(id)
                center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let device = info["device"] as? String ?? ""
        let notification = info["notification"] as? String ?? ""
        let replyID = info["replyID"] as? String ?? ""
        let text = (response as? UNTextInputNotificationResponse)?.userText
        let replying = response.actionIdentifier == "PEDRO_PHONE_REPLY_SEND"
        Task { @MainActor in
            let manager = PedroPhoneManager.shared
            if replying, let text {
                // Wait briefly for the event stream after a cold launch. No replay or automatic resend.
                for _ in 0..<20 {
                    if manager.phones.contains(where: { $0.id == device }) { break }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                if let phone = manager.phones.first(where: { $0.id == device }),
                   let item = phone.notifications.first(where: { $0.id == notification && $0.replyID == replyID }) {
                    manager.reply(item, phone: phone, text: text) { ok in
                        if !ok { self.showFailure(manager.feedback ?? "Nao foi possivel enviar. Abra o Notch para tentar novamente.") }
                        completionHandler()
                    }
                } else {
                    self.showFailure("A notificacao expirou ou o aparelho esta desconectado. Abra o Notch para conferir.")
                    completionHandler()
                }
            } else {
                UserDefaults.standard.set(device, forKey: "pedroSelectedPhoneV1")
                BoringViewCoordinator.shared.currentView = .pedroPhone
                if let delegate = NSApp.delegate as? AppDelegate { delegate.vm.open() }
                completionHandler()
            }
        }
    }
    private func showFailure(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = "Resposta nao enviada"; content.body = text
        center.add(UNNotificationRequest(identifier: "phone-reply-error", content: content, trigger: nil))
    }
}
