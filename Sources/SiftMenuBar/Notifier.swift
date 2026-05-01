import Foundation
import UserNotifications

/// Native UNUserNotifications, posted by the menu bar app when a
/// `sift auto` session finishes. The CLI daemon used to do this with
/// `osascript -e "display notification …"`; that produced the generic
/// Script Editor banner instead of one bearing the Sift bundle.
final class Notifier: @unchecked Sendable {
    static let shared = Notifier()

    private let lock = NSLock()
    private var _authorized = false
    private var authorized: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _authorized }
        set { lock.lock(); _authorized = newValue; lock.unlock() }
    }

    private init() {
        Task { await requestAuthorization() }
    }

    private func requestAuthorization() async {
        do {
            authorized = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            authorized = false
        }
    }

    func post(title: String, body: String, sessionDir: String) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["sessionDir": sessionDir]
        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }
}
