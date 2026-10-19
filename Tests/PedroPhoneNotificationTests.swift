import Foundation

@main struct PedroPhoneNotificationTests {
    @MainActor static func main() async throws {
        let old = PedroPhoneNotification(id: "1", app: "Messages", title: "Person", text: "Old")
        var incoming = PedroPhoneNotification(id: "2", app: "Messages", title: "Person", text: "New")
        incoming.replyID = "reply-token"
        func phone(_ notifications: [PedroPhoneNotification], reachable: Bool = true) -> PedroPhone {
            PedroPhone(id: "device", name: "Galaxy", paired: true, reachable: reachable, charge: 50, charging: false,
                notifications: notifications, notificationsAvailable: true, canRing: true, canShare: true, canShareFiles: true, via: nil)
        }
        var ledger = PedroPhoneNotificationLedger()
        precondition(ledger.additions(phone([old])).isEmpty, "Do not replay old inbox at launch")
        precondition(ledger.additions(phone([old, incoming])) == [incoming])
        precondition(ledger.additions(phone([old, incoming])).isEmpty, "Repeated D-Bus events are deduplicated")
        precondition(ledger.additions(phone([], reachable: false)).isEmpty)
        precondition(ledger.additions(phone([old, incoming])).isEmpty, "Reconnect must not replay seen notifications")
        var silent = incoming; silent = PedroPhoneNotification(id: "3", app: "Messages", title: "Person", text: "Quiet", silent: true)
        precondition(ledger.additions(phone([silent])).isEmpty)
        precondition(incoming.canReply && !old.canReply)
        precondition(!phone([incoming]).disconnected.isConnected)
        precondition(phone([incoming]).disconnected.notifications.isEmpty)
        let legacy = Data("""
        {"devices":[{"id":"a","name":"Galaxy","paired":true,"reachable":true,"charge":42,"charging":false,"notifications":[{"id":"1","app":"App","title":"Title","text":"Text"}],"notificationsAvailable":true,"canRing":true,"canShare":true,"canShareFiles":true,"via":null}]}
        """.utf8)
        let decoded = try JSONDecoder().decode(PedroPhoneSnapshot.self, from: legacy)
        precondition(decoded.devices?.first?.media == nil)
        precondition(decoded.devices?.first?.notifications.first?.canReply == false)
        let feedback = PedroPhoneFeedback()
        feedback.show("First", duration: .milliseconds(100))
        try await Task.sleep(for: .milliseconds(40))
        feedback.show("Latest", duration: .milliseconds(300))
        try await Task.sleep(for: .milliseconds(140))
        precondition(feedback.message == "Latest", "An old deadline must not dismiss a newer result")
        try await Task.sleep(for: .milliseconds(220))
        precondition(feedback.message == nil, "Results must disappear without another action")
        feedback.show("Dismiss me")
        feedback.dismiss()
        precondition(feedback.message == nil)
        print("PedroPhoneNotificationTests: launch baseline, event dedup, reconnect, silent notifications, stale state and legacy decoding passed")
    }
}
