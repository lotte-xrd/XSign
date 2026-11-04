import UIKit
import UserNotifications

extension Notification.Name {
    /// Tocar numa notificação de download abre a aba Downloads.
    static let xsignOpenDownloads = Notification.Name("xsign.openDownloads")
    /// Tocar na notificação de assinatura concluída instala o app (userInfo com o link).
    static let xsignInstallFromNotification = Notification.Name("xsign.installFromNotification")
    /// Tocar na notificação de assinatura (sem instalar) abre a aba Apps.
    static let xsignOpenApps = Notification.Name("xsign.openApps")
}

/// Necessário para a sessão de download em segundo plano e para mostrar as
/// notificações também com o app aberto.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Reconecta a sessão de assinatura em segundo plano (entrega o que terminou
        // enquanto o app estava fechado).
        _ = SignUploadSession.shared
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if identifier == SignUploadSession.identifier {
            SignUploadSession.shared.handleBackgroundEvents(completion: completionHandler)
        } else {
            DownloadSessionBridge.setBackgroundCompletion(completionHandler)
        }
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
        let info = response.notification.request.content.userInfo
        switch info[DownloadNotifier.targetKey] as? String {
        case "downloads":
            NotificationCenter.default.post(name: .xsignOpenDownloads, object: nil)
        case "install":
            if let url = info[SignNotifier.installURLKey] as? String {
                PendingNotificationAction.setInstall(url: url, bundleID: info[SignNotifier.bundleIDKey] as? String)
            }
            NotificationCenter.default.post(name: .xsignInstallFromNotification, object: nil)
        case "apps":
            NotificationCenter.default.post(name: .xsignOpenApps, object: nil)
        default:
            break
        }
        completionHandler()
    }
}

/// Instalação pedida por uma notificação tocada. Fica guardada até o app estar
/// ativo (o toque pode abrir o XSign do zero, antes das telas existirem).
enum PendingNotificationAction {
    private static let lock = NSLock()
    private static var install: (url: String, bundleID: String?)?

    static func setInstall(url: String, bundleID: String?) {
        lock.lock()
        install = (url, bundleID)
        lock.unlock()
    }

    static func takeInstall() -> (url: String, bundleID: String?)? {
        lock.lock()
        defer { lock.unlock() }
        let value = install
        install = nil
        return value
    }
}
