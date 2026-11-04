import Foundation
import UIKit
import UserNotifications

/// Envio da assinatura numa URLSession em segundo plano: o upload e a espera
/// pela resposta do servidor continuam com o XSign fora da tela. O iOS acorda o
/// app quando termina, e uma notificação avisa que o app está pronto.
final class SignUploadSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = SignUploadSession()

    static var identifier: String {
        "\(Bundle.main.bundleIdentifier ?? "com.xsign.app").background-signing"
    }

    private final class Pending {
        var data = Data()
        var onProgress: ((Int64, Int64) -> Void)?
        var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var orphanData: [Int: Data] = [:]
    private var backgroundCompletion: (() -> Void)?

    /// Criada uma única vez no init (duas sessões com o mesmo identificador dão erro).
    private var session: URLSession!

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        // O servidor fica calado enquanto assina: dá tempo de sobra.
        config.timeoutIntervalForRequest = 900
        config.timeoutIntervalForResource = 6 * 60 * 60
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Recria a sessão (relançamento pelo iOS) e guarda o handler do AppDelegate.
    func handleBackgroundEvents(completion: @escaping () -> Void) {
        lock.lock()
        backgroundCompletion = completion
        lock.unlock()
    }

    /// Envia o corpo já gravado em arquivo e devolve a resposta do servidor.
    /// `jobID` identifica o trabalho salvo em `PendingSignStore`.
    func upload(
        _ request: URLRequest,
        fromFile fileURL: URL,
        jobID: String,
        onProgress: @escaping (_ sent: Int64, _ expected: Int64) -> Void
    ) async throws -> (Data, HTTPURLResponse) {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
                let task = session.uploadTask(with: request, fromFile: fileURL)
                task.taskDescription = jobID
                let entry = Pending()
                entry.onProgress = onProgress
                entry.continuation = cont
                lock.lock()
                pending[task.taskIdentifier] = entry
                lock.unlock()
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    private final class TaskBox: @unchecked Sendable {
        var task: URLSessionTask?
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        lock.lock()
        let handler = pending[task.taskIdentifier]?.onProgress
        lock.unlock()
        handler?(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if let entry = pending[dataTask.taskIdentifier] {
            entry.data.append(data)
        } else {
            orphanData[dataTask.taskIdentifier, default: Data()].append(data)
        }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let entry = pending.removeValue(forKey: task.taskIdentifier)
        let orphan = orphanData.removeValue(forKey: task.taskIdentifier)
        lock.unlock()

        if let entry, let cont = entry.continuation {
            if let error {
                cont.resume(throwing: error)
            } else if let http = task.response as? HTTPURLResponse {
                cont.resume(returning: (entry.data, http))
            } else {
                cont.resume(throwing: URLError(.badServerResponse))
            }
            return
        }

        // O app foi encerrado pelo iOS no meio do envio: termina pelo registro salvo.
        guard let jobID = task.taskDescription else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        PendingSignStore.completeOrphan(jobID: jobID, status: status, data: orphan ?? Data(), error: error)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = backgroundCompletion
        backgroundCompletion = nil
        lock.unlock()
        DispatchQueue.main.async { handler?() }
    }
}

// MARK: - Trabalhos de assinatura salvos em disco

/// Cada assinatura enviada fica registrada em disco até terminar. Se o iOS
/// encerrar o XSign no meio, o resultado é gravado aqui e o app o coloca na aba
/// Assinados na próxima abertura.
struct PendingSignJob: Codable {
    var jobID: String
    var app: AppItem
    var certificateID: UUID
    var options: SignOptions
    var bodyPath: String
    var createdAt: Date = Date()
    /// Preenchidos quando o servidor respondeu com o app fora da memória.
    var resultData: Data? = nil
    var errorMessage: String? = nil
}

enum PendingSignStore {
    private static var folder: URL {
        let dir = Paths.documents.appendingPathComponent("PendingSigns", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func url(_ jobID: String) -> URL {
        folder.appendingPathComponent("\(jobID).json")
    }

    static func save(_ job: PendingSignJob) {
        if let data = try? JSONEncoder().encode(job) {
            try? data.write(to: url(job.jobID), options: .atomic)
        }
    }

    static func remove(_ jobID: String) {
        try? FileManager.default.removeItem(at: url(jobID))
    }

    static func load(_ jobID: String) -> PendingSignJob? {
        guard let data = try? Data(contentsOf: url(jobID)) else { return nil }
        return try? JSONDecoder().decode(PendingSignJob.self, from: data)
    }

    /// Trabalhos que terminaram sem o app na memória (para registrar na abertura).
    static func takeFinished() -> [PendingSignJob] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var finished: [PendingSignJob] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let job = try? JSONDecoder().decode(PendingSignJob.self, from: data) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if job.resultData != nil || job.errorMessage != nil {
                finished.append(job)
                try? FileManager.default.removeItem(at: file)
            } else if Date().timeIntervalSince(job.createdAt) > 24 * 60 * 60 {
                try? FileManager.default.removeItem(atPath: job.bodyPath)
                try? FileManager.default.removeItem(at: file)
            }
        }
        return finished
    }

    static func completeOrphan(jobID: String, status: Int, data: Data, error: Error?) {
        guard var job = load(jobID) else { return }
        try? FileManager.default.removeItem(atPath: job.bodyPath)
        let name = job.options.name ?? job.app.name

        if error == nil, (200...299).contains(status),
           let decoded = try? JSONDecoder().decode(RemoteSigningService.RemoteSignResponse.self, from: data) {
            job.resultData = data
            save(job)
            SignNotifier.notifySigned(
                name: decoded.appName,
                installURL: decoded.installUrl,
                bundleID: decoded.bundleIdentifier
            )
        } else {
            let message = (try? JSONDecoder().decode(RemoteSigningService.RemoteErrorResponse.self, from: data))?.error
                ?? error?.localizedDescription
                ?? "HTTP \(status)"
            job.errorMessage = message
            save(job)
            SignNotifier.notifyFailed(name: name, message: message)
        }
    }
}

// MARK: - Notificações da assinatura

enum SignNotifier {
    static let installURLKey = "xsign.installURL"
    static let bundleIDKey = "xsign.bundleID"

    /// Só avisa com o app fora da tela; com ele aberto, a própria tela mostra.
    static func notifySigned(name: String, installURL: String?, bundleID: String?) {
        let willInstall = Settings.load().installAfterSign && installURL != nil
        let content = UNMutableNotificationContent()
        content.title = L.tr("notify.sign.done.title")
        content.body = willInstall ? L.tr("notify.sign.done.install", name) : L.tr("notify.sign.done.body", name)
        content.sound = .default
        var info: [String: String] = [DownloadNotifier.targetKey: willInstall ? "install" : "apps"]
        if let installURL { info[installURLKey] = installURL }
        if let bundleID { info[bundleIDKey] = bundleID }
        content.userInfo = info
        post(content)
    }

    static func notifyFailed(name: String, message: String) {
        let content = UNMutableNotificationContent()
        content.title = L.tr("notify.sign.failed.title")
        content.body = L.tr("notify.sign.failed.body", name, message)
        content.sound = .default
        content.userInfo = [DownloadNotifier.targetKey: "apps"]
        post(content)
    }

    private static func post(_ content: UNMutableNotificationContent) {
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

// MARK: - Tempo extra para a parte feita no aparelho

/// Pede ao iOS alguns segundos a mais para terminar o que roda no próprio
/// aparelho (baixar, injetar tweaks, montar o envio) quando o app sai da tela.
final class BackgroundTaskGuard: @unchecked Sendable {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private let lock = NSLock()

    init(name: String) {
        DispatchQueue.main.async { [self] in
            let id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
                self?.end()
            }
            lock.lock()
            identifier = id
            lock.unlock()
        }
    }

    func end() {
        DispatchQueue.main.async { [self] in
            lock.lock()
            let id = identifier
            identifier = .invalid
            lock.unlock()
            if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
        }
    }
}
