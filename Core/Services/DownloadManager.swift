import Foundation

/// Fila de downloads reais de `.ipa`, com pausa, retomada e importação automática.
@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var tasks: [DownloadTask] = []

    /// Callback chamado ao concluir um download com sucesso (para o AppState importar na aba Apps).
    var onDownloadFinished: ((DownloadTask, URL) -> Void)?

    var activeCount: Int { tasks.filter { $0.state == .running || $0.state == .queued }.count }
    var running: [DownloadTask] { tasks.filter { $0.state == .running || $0.state == .queued || $0.state == .paused } }
    var finished: [DownloadTask] { tasks.filter { $0.state == .finished || $0.state == .failed } }

    private var handles: [UUID: Task<Void, Never>] = [:]

    /// Inicia o download de um app de uma fonte ou link direto.
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
        let id = task.id
        handles[id] = Task { await run(id: id, url: url) }
    }

    func pause(_ id: UUID) {
        handles[id]?.cancel()
        update(id) { $0.state = .paused }
    }

    func resume(_ id: UUID) {
        guard let t = tasks.first(where: { $0.id == id }) else { return }
        update(id) { $0.state = .running; $0.error = nil }
        handles[id] = Task { await run(id: id, url: t.url) }
    }

    func cancel(_ id: UUID) {
        handles[id]?.cancel()
        handles[id] = nil
        if let t = tasks.first(where: { $0.id == id }), let p = t.localPath {
            try? FileManager.default.removeItem(at: Paths.resolve(p))
        }
        tasks.removeAll { $0.id == id }
    }

    func clearFinished() {
        tasks.removeAll { $0.state == .finished || $0.state == .failed }
    }

    func retry(_ id: UUID) { resume(id) }

    private func run(id: UUID, url: URL) async {
        do {
            Paths.ensure()
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 300)
            req.setValue("XSign/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            let total = response.expectedContentLength
            update(id) { $0.totalBytes = max(0, total); $0.state = .running }

            let rawName = url.lastPathComponent.isEmpty ? "app.ipa" : url.lastPathComponent
            let fileName = rawName.lowercased().hasSuffix(".ipa") ? rawName : "\(rawName).ipa"
            let dest = Paths.downloads.appendingPathComponent("\(id.uuidString.prefix(8))-\(fileName)")
            try? FileManager.default.removeItem(at: dest)
            FileManager.default.createFile(atPath: dest.path, contents: nil)
            let handle = try FileHandle(forWritingTo: dest)
            defer { try? handle.close() }

            var written: Int64 = 0
            var buffer = Data()
            buffer.reserveCapacity(128 * 1024)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 128 * 1024 {
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    update(id) { $0.bytesWritten = written }
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
            }
            try? handle.close()

            let relPath = Paths.relative(dest)
            update(id) {
                $0.bytesWritten = written
                $0.totalBytes = max($0.totalBytes, written)
                $0.localPath = relPath
                $0.state = .finished
            }

            if let completedTask = tasks.first(where: { $0.id == id }) {
                onDownloadFinished?(completedTask, dest)
            }
        } catch is CancellationError {
            // Pausa ou cancelamento tratados pelo chamador
        } catch {
            update(id) { $0.state = .failed; $0.error = error.localizedDescription }
        }
        handles[id] = nil
    }

    private func update(_ id: UUID, _ change: (inout DownloadTask) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[i])
    }
}
