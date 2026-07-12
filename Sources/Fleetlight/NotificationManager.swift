import Foundation
@preconcurrency import UserNotifications

actor NotificationManager {
    static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { allowed, _ in
                continuation.resume(returning: allowed)
            }
        }
    }

    func send(title: String, body: String, identifier: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        await withCheckedContinuation { continuation in
            center.add(request) { _ in
                continuation.resume()
            }
        }
    }
}
