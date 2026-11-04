import UIKit
import UserNotifications

extension Notification.Name {
    /// Tocar numa notificação de download abre a aba Downloads.
    static let xsignOpenDownloads = Notification.Name("xsign.openDownloads")
}

/// Necessário para a sessão de download em segundo plano e para mostrar as
/// notificações também com o app aberto.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        DownloadSessionBridge.setBackgroundCompletion(completionHandler)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if (response.notification.request.content.userInfo[DownloadNotifier.targetKey] as? String) == "downloads" {
            NotificationCenter.default.post(name: .xsignOpenDownloads, object: nil)
        }
        completionHandler()
    }
}
