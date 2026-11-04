import Foundation
import UIKit
import UserNotifications

/// Fila de downloads de `.ipa` em segundo plano (continua com o app fechado),
/// com pausa/retomada de verdade, importação automática e notificação ao terminar.
@MainActor
final class DownloadManager: ObservableObject {
    static let sessionIdentifier = "com.xsign.app.background-downloads"

    @Published private(set) var tasks: [DownloadTask] = []

    /// Chamado ao concluir um download com sucesso (o AppState importa na aba Apps).
    var onDownloadFinished: ((DownloadTask, URL) -> Void)?
    /// Lido a cada notificação (preferência do usuário).
    var notificationsEnabled: @MainActor () -> Bool = { true }

    var activeCount: Int { tasks.filter { $0.state == .running || $0.state == .queued }.count }
    var running: [DownloadTask] { tasks.filter { $0.state == .running || $0.state == .queued || $0.state == .paused } }
    var finished: [DownloadTask] { tasks.filter { $0.state == .finished || $0.state == .failed } }

    private let bridge: DownloadSessionBridge
    private let session: URLSession
    private var urlTasks: [UUID: URLSessionDownloadTask] = [:]

    init() {
        let bridge = DownloadSessionBridge()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.timeoutIntervalForRequest = 120
        config.httpAdditionalHeaders = ["User-Agent": "XSign/1.0 (iOS)"]
        self.bridge = bridge
        self.session = URLSession(configuration: config, delegate: bridge, delegateQueue: nil)
        self.tasks = Self.loadPersisted()
        bridge.attach(self)

        let session = self.session
        session.getAllTasks { all in
            let downloads = all.compactMap { $0 as? URLSessionDownloadTask }
            Task { @MainActor [weak self] in
                self?.reattach(downloads)
            }
        }
    }

    // MARK: API pública (mesma de antes)

    func start(
        name: String,
        url: URL,
        iconURL: URL? = nil,
        bundleID: String? = nil,
        version: String? = nil,
        sourceName: String? = nil
    ) {
        let task = DownloadTask(
            url: url,
            name: name,
            iconURL: iconURL,
            bundleID: bundleID,
            version: version,
            sourceName: sourceName,
            state: .running
        )
        tasks.insert(task, at: 0)
        launch(task.id, url: url, resumeData: nil)
        persist()
        if notificationsEnabled() {
            DownloadNotifier.requestAuthorizationIfNeeded()
        }
    }

    func pause(_ id: UUID) {
        update(id) { $0.state = .paused }
        guard let task = urlTasks[id] else { persist(); return }
        urlTasks[id] = nil
        task.cancel(byProducingResumeData: { data in
            Task { @MainActor in
                if let data { DownloadResumeStore.save(data, for: id) }
            }
        })
        persist()
    }

    func resume(_ id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        update(id) { $0.state = .running; $0.error = nil }
        let data = DownloadResumeStore.load(id)
        DownloadResumeStore.delete(id)
        launch(id, url: task.url, resumeData: data)
        persist()
    }

    func cancel(_ id: UUID) {
        urlTasks[id]?.cancel()
        urlTasks[id] = nil
        DownloadResumeStore.delete(id)
        if let t = tasks.first(where: { $0.id == id }), let p = t.localPath {
            try? FileManager.default.removeItem(at: Paths.resolve(p))
        }
        tasks.removeAll { $0.id == id }
        persist()
    }

    func clearFinished() {
        for t in tasks where t.state == .failed { DownloadResumeStore.delete(t.id) }
        tasks.removeAll { $0.state == .finished || $0.state == .failed }
        persist()
    }

    func retry(_ id: UUID) { resume(id) }

    // MARK: Eventos da sessão (chamados pelo bridge na main)

    fileprivate func handleProgress(_ id: UUID, written: Int64, expected: Int64) {
        update(id) {
            $0.bytesWritten = written
            if expected > 0 { $0.totalBytes = expected }
            if $0.state == .queued { $0.state = .running }
        }
    }

    fileprivate func handleFinished(_ id: UUID, fileURL: URL) {
        guard tasks.contains(where: { $0.id == id }) else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        update(id) {
            $0.localPath = Paths.relative(fileURL)
            $0.bytesWritten = size
            $0.totalBytes = max($0.totalBytes, size)
            $0.state = .finished
            $0.error = nil
        }
        urlTasks[id] = nil
        DownloadResumeStore.delete(id)
        persist()

        guard let task = tasks.first(where: { $0.id == id }) else { return }
        if notificationsEnabled() {
            DownloadNotifier.notifyFinished(task.name)
        }
        onDownloadFinished?(task, fileURL)
    }

    fileprivate func handleFailure(_ id: UUID, message: String, resumeData: Data?) {
        // pausado ou removido pelo usuário: o "cancelado" é esperado
        guard let task = tasks.first(where: { $0.id == id }), task.state != .paused, task.state != .finished else { return }
        urlTasks[id] = nil
        if let resumeData { DownloadResumeStore.save(resumeData, for: id) }
        update(id) {
            $0.state = .failed
            $0.error = message
        }
        persist()
        if notificationsEnabled() {
            DownloadNotifier.notifyFailed(task.name)
        }
    }

    // MARK: Internos

    private func launch(_ id: UUID, url: URL, resumeData: Data?) {
        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var req = URLRequest(url: url)
            req.setValue("XSign/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
            task = session.downloadTask(with: req)
        }
        task.taskDescription = id.uuidString
        urlTasks[id] = task
        task.resume()
    }

    /// Religa os downloads que continuaram rodando enquanto o app estava fechado.
    private func reattach(_ live: [URLSessionDownloadTask]) {
        var liveIDs = Set<UUID>()
        for t in live {
            guard let key = t.taskDescription, let id = UUID(uuidString: key),
                  tasks.contains(where: { $0.id == id }) else {
                t.cancel()
                continue
            }
            if t.state == .running || t.state == .suspended {
                urlTasks[id] = t
                liveIDs.insert(id)
                update(id) { $0.state = .running }
            }
        }
        for task in tasks where (task.state == .running || task.state == .queued) && !liveIDs.contains(task.id) && urlTasks[task.id] == nil {
            let resumable = DownloadResumeStore.load(task.id) != nil
            update(task.id) {
                $0.state = resumable ? .paused : .failed
                if !resumable { $0.error = L.tr("downloads.interrupted") }
            }
        }
        persist()
    }

    private func update(_ id: UUID, _ change: (inout DownloadTask) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[i])
    }

    private func persist() {
        let snapshot = tasks
        Task { await Store.shared.save(snapshot, to: "downloads") }
    }

    private static func loadPersisted() -> [DownloadTask] {
        let url = Paths.documents.appendingPathComponent("Store/downloads.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([DownloadTask].self, from: data)) ?? []
    }
}

// MARK: - Delegate da sessão em segundo plano

/// Recebe os eventos da URLSession (fora da main) e repassa ao DownloadManager.
/// Guarda os eventos que chegam antes do manager estar pronto (relançamento em segundo plano).
final class DownloadSessionBridge: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private weak var manager: DownloadManager?
    private var pending: [@MainActor (DownloadManager) -> Void] = []
    private var lastTick: [String: CFAbsoluteTime] = [:]

    private static let completionLock = NSLock()
    private static var backgroundCompletion: (() -> Void)?

    static func setBackgroundCompletion(_ handler: @escaping () -> Void) {
        completionLock.lock()
        backgroundCompletion = handler
        completionLock.unlock()
    }

    private static func takeBackgroundCompletion() -> (() -> Void)? {
        completionLock.lock()
        defer { completionLock.unlock() }
        let handler = backgroundCompletion
        backgroundCompletion = nil
        return handler
    }

    func attach(_ manager: DownloadManager) {
        lock.lock()
        self.manager = manager
        let queued = pending
        pending.removeAll()
        lock.unlock()
        guard !queued.isEmpty else { return }
        Task { @MainActor in
            for event in queued { event(manager) }
        }
    }

    private func deliver(_ event: @escaping @MainActor (DownloadManager) -> Void) {
        lock.lock()
        if let manager {
            lock.unlock()
            Task { @MainActor in event(manager) }
        } else {
            pending.append(event)
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription, let id = UUID(uuidString: key) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let last = lastTick[key] ?? 0
        let shouldSend = now - last > 0.25 || totalBytesWritten == totalBytesExpectedToWrite
        if shouldSend { lastTick[key] = now }
        lock.unlock()
        guard shouldSend else { return }
        deliver { $0.handleProgress(id, written: totalBytesWritten, expected: totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription, let id = UUID(uuidString: key) else { return }

        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let status = http.statusCode
            deliver { $0.handleFailure(id, message: "HTTP \(status)", resumeData: nil) }
            return
        }

        // O arquivo temporário some quando este método retorna: mover agora.
        Paths.ensure()
        let requested = downloadTask.originalRequest?.url ?? downloadTask.currentRequest?.url
        let suggested = downloadTask.response?.suggestedFilename
        var name = requested?.lastPathComponent ?? ""
        if name.isEmpty || name == "/" { name = suggested ?? "app.ipa" }
        if !name.lowercased().hasSuffix(".ipa") {
            if let suggested, suggested.lowercased().hasSuffix(".ipa") {
                name = suggested
            } else {
                name += ".ipa"
            }
        }
        let destination = Paths.downloads.appendingPathComponent("\(key.prefix(8))-\(name)")
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            deliver { $0.handleFinished(id, fileURL: destination) }
        } catch {
            let message = error.localizedDescription
            deliver { $0.handleFailure(id, message: message, resumeData: nil) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let key = task.taskDescription, let id = UUID(uuidString: key) else { return }
        let ns = error as NSError
        let resume = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let message = ns.localizedDescription
        lock.lock()
        lastTick[key] = nil
        lock.unlock()
        deliver { $0.handleFailure(id, message: message, resumeData: resume) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            DownloadSessionBridge.takeBackgroundCompletion()?()
        }
    }
}

// MARK: - Dados para retomar downloads pausados

enum DownloadResumeStore {
    private static var folder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("ResumeData", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func save(_ data: Data, for id: UUID) {
        try? data.write(to: folder.appendingPathComponent(id.uuidString), options: .atomic)
    }

    static func load(_ id: UUID) -> Data? {
        try? Data(contentsOf: folder.appendingPathComponent(id.uuidString))
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(id.uuidString))
    }
}

// MARK: - Notificações locais

enum DownloadNotifier {
    static let targetKey = "xsign.target"

    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    static func notifyFinished(_ name: String) {
        post(title: L.tr("notify.download.done.title"), body: L.tr("notify.download.done.body", name))
    }

    static func notifyFailed(_ name: String) {
        post(title: L.tr("notify.download.failed.title"), body: L.tr("notify.download.failed.body", name))
    }

    private static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [targetKey: "downloads"]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
