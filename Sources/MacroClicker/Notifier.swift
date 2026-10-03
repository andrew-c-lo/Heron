import AppKit
@preconcurrency import UserNotifications

/// A Notification Center banner when something stops on its own while you're in another app (a chain gave up,
/// the auto clicker hit a problem, a background macro reached its click limit). Never for routine starts and stops.
@MainActor
enum Notifier {
    /// Only inside the real app bundle (the notification center isn't available to a bare executable).
    private static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    /// Ask once, when the setting is first used.
    static func requestPermission() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ title: String, _ body: String, enabled: Bool) {
        guard enabled, available, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        // Permission is asked the first time it's needed (macOS only shows the prompt once).
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { UNUserNotificationCenter.current().add(request) }
        }
    }
}
