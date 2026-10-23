import Foundation

/// Fila de downloads de `.ipa`. Usa URLSession; em produção, trocar por uma
/// sessão em segundo plano (`URLSessionConfiguration.background`) para seguir
/// baixando com o app fora da tela.
@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var tasks: [DownloadTask] = []

    var activeCount: Int { tasks.filter { $0.state == .running || $0.state == .queued }.count }
    var running: [DownloadTask] { tasks.filter { $0.state == .running || $0.state == .queued || $0.state == .paused } }
    var finished: [DownloadTask] { tasks.filter { $0.state == .finished || $0.state == .failed } }

    private var handles: [UUID: Task<Void, Never>] = [:]

    /// Inicia o download de um app de uma fonte.
    func start(name: String, url: URL) {
        let task = DownloadTask(url: url, name: name, state: .running)
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
        update(id) { $0.state = .running }
        handles[id] = Task { await run(id: id, url: t.url) }
    }

    func cancel(_ id: UUID) {
        handles[id]?.cancel()
        handles[id] = nil
        tasks.removeAll { $0.id == id }
    }

    func retry(_ id: UUID) { resume(id) }

    private func run(id: UUID, url: URL) async {
        do {
            let (bytes, response) = try await URLSession.shared.bytes(from: url)
            let total = response.expectedContentLength
            update(id) { $0.totalBytes = max(0, total); $0.state = .running }

            let dest = Paths.downloads.appendingPathComponent(url.lastPathComponent)
            FileManager.default.createFile(atPath: dest.path, contents: nil)
            let handle = try FileHandle(forWritingTo: dest)
            defer { try? handle.close() }

            var written: Int64 = 0
            var buffer = Data()
            buffer.reserveCapacity(64 * 1024)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 64 * 1024 {
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count); buffer.removeAll(keepingCapacity: true)
                    update(id) { $0.bytesWritten = written }
                }
            }
            if !buffer.isEmpty { try handle.write(contentsOf: buffer); written += Int64(buffer.count) }
            update(id) { $0.bytesWritten = written; $0.state = .finished }
            // Em produção: ImportRouter.importIPA(at: dest) se "importar automaticamente" estiver ligado.
        } catch is CancellationError {
            // pausado/cancelado: estado já tratado por quem chamou
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
