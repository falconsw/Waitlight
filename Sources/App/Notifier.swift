import AppKit
import Foundation
import UserNotifications

/// The two moments worth interrupting for: a session that has been waiting on
/// you for a while, and a turn that ended while you were somewhere else.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let waitingKey = "notifyWaiting"
    static let doneKey = "notifyDone"

    /// A prompt answered within this long was answered by someone already
    /// looking at it, and a notification would only arrive after the fact.
    private let waitingGrace: TimeInterval = 10

    private let board: SessionBoard
    private let center = UNUserNotificationCenter.current()
    private var defaults: UserDefaults { .standard }

    init(board: SessionBoard) {
        self.board = board
        super.init()
        defaults.register(defaults: [Self.waitingKey: true, Self.doneKey: true])
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        board.onWaiting = { [weak self] row in self?.waitingStarted(row) }
        board.onDone = { [weak self] row in self?.turnEnded(row) }
    }

    private func waitingStarted(_ row: SessionBoard.Row) {
        guard defaults.bool(forKey: Self.waitingKey) else { return }
        let id = row.id
        DispatchQueue.main.asyncAfter(deadline: .now() + waitingGrace) { [weak self] in
            guard let self, let now = self.board.row(id: id), now.phase == .waiting else { return }
            let what = now.session.waitingFor.map { L10n.t("Waiting for you: \($0)") }
                ?? L10n.t("Claude Code is waiting for your answer.")
            self.post(id: id, title: L10n.t("\(now.project) is waiting"), body: what)
        }
    }

    private func turnEnded(_ row: SessionBoard.Row) {
        guard defaults.bool(forKey: Self.doneKey),
              let pid = row.session.processID, !TabFocus.isInFront(pid: pid)
        else { return }
        post(id: row.id, title: L10n.t("\(row.project) is done"), body: L10n.t("Your turn."))
    }

    private func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["session": id]
        // One notification per session: a newer one replaces what it said before.
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// A session no longer waiting has nothing left to say.
    func clear(_ id: String) {
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["session"] as? String
        Task { @MainActor in
            if let id, let row = self.board.row(id: id) { self.board.open(row) }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
