import Foundation
import UIKit
import ZIPFoundation

/// Motor de assinatura. As telas falam só com este protocolo e consomem o
/// progresso (passos + log) como `AsyncStream`.
protocol SigningService {
    func sign(app: AppItem, certificate: Certificate, options: SignOptions) -> AsyncStream<SignProgress>
}

// MARK: - Emissor thread-safe de progresso e log

final class SignEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: SignProgress
    private let continuation: AsyncStream<SignProgress>.Continuation

    init(initial: SignProgress, continuation: AsyncStream<SignProgress>.Continuation) {
        self.progress = initial
        self.continuation = continuation
        continuation.yield(initial)
    }

    func update(_ change: (inout SignProgress) -> Void) {
        lock.lock()
        change(&progress)
        let snapshot = progress
        lock.unlock()
        continuation.yield(snapshot)
    }

    func snapshot() -> SignProgress {
        lock.lock()
        defer { lock.unlock() }
        return progress
    }

    func log(_ text: String, _ level: SignLogLevel = .info) {
        update { $0.log.append(SignLogLine(level: level, text: text)) }
    }

    func step(_ kind: SignStepKind, _ state: StepState) {
        update { p in
            if let i = p.steps.firstIndex(where: { $0.kind == kind }) { p.steps[i].state = state }
        }
    }

    /// A barra só anda para a frente.
    func fraction(_ value: Double) {
        update { $0.fraction = max($0.fraction, min(value, 1)) }
    }

    func fail(_ kind: SignStepKind, _ message: String) {
        update { p in
            if let i = p.steps.firstIndex(where: { $0.kind == kind }) { p.steps[i].state = .failed(message) }
            p.error = message
            p.log.append(SignLogLine(level: .error, text: message))
        }
        continuation.finish()
    }

    func finish() {
        continuation.finish()
    }
}

// MARK: - Assinatura Real no Servidor Linux (zsign em https://exploiting-ios.online)

struct RemoteSigningService: SigningService {
    var baseURLString: String = "https://exploiting-ios.online"

    struct RemoteSignResponse: Decodable {
        let id: String
        let appName: String
        let bundleIdentifier: String
        let bundleVersion: String
        let originalFilename: String?
        let fileSize: Int64?
        let expiresAt: String?
        let shareUrl: String?
        let installUrl: String
        let downloadUrl: String
    }

    struct RemoteErrorResponse: Decodable {
        let error: String?
    }

    /// Estado de um trabalho de assinatura no servidor (`/api/xsign/v2/jobs`).
    struct ServerJobState: Decodable {
        let id: String
        let version: Int
        let status: String
        let chunkSize: Int64
        let totalChunks: Int
        let receivedChunks: Int
        let receivedBytes: Int64
        let ipaSize: Int64
        let statusSeconds: Double?
        let queuePosition: Int?
        let result: RemoteSignResponse?
        let error: String?
        let errorStatus: Int?
        /// Quanto a assinatura levou (ou já leva) no servidor.
        let signingSeconds: Double?
    }

    /// Falha já com a mensagem para a pessoa e o passo onde aconteceu.
    struct SignFailure: Error {
        let step: SignStepKind
        let message: String
    }

    /// O servidor configurado não tem `/api/xsign/v2/jobs`: usa o envio antigo.
    private struct ServerJobsUnsupported: Error {}

    /// Tudo o que o servidor precisa para assinar.
    private struct ServerSignRequest {
        let base: String
        let app: AppItem
        let certificate: Certificate
        let options: SignOptions
        let p12Data: Data?
        let provData: Data
        let password: String
        let customName: String
        let customBundleID: String
        let customVersion: String
        let applyVersion: Bool
        let remoteIPAURL: URL?
        let localIPAURL: URL?
        let workDir: URL
        let localJobID: String
    }

    /// Fim da faixa da barra usada pelo envio; o resto é a assinatura no servidor.
    static let uploadTop = 0.72

    func sign(app: AppItem, certificate: Certificate, options: SignOptions) -> AsyncStream<SignProgress> {
        let endpointBase = UserDefaults.standard.string(forKey: "xsign.serverURL") ?? baseURLString
        return AsyncStream { continuation in
            let job = Task.detached(priority: .userInitiated) {
                await Self.run(app: app, certificate: certificate, options: options,
                               endpointBase: endpointBase, continuation: continuation)
            }
            continuation.onTermination = { _ in job.cancel() }
        }
    }

    // MARK: Fluxo

    private static func run(
        app: AppItem,
        certificate: Certificate,
        options: SignOptions,
        endpointBase: String,
        continuation: AsyncStream<SignProgress>.Continuation
    ) async {
        let customName = (options.name ?? app.name).trimmingCharacters(in: .whitespacesAndNewlines)
        let customBundle = (options.bundleID ?? app.bundleID).trimmingCharacters(in: .whitespacesAndNewlines)
        let customVersion = (options.version ?? app.version).trimmingCharacters(in: .whitespacesAndNewlines)
        let injections = options.injections
        let tweakMode = !injections.isEmpty

        // Só passos que acontecem de verdade: o resto quem faz é o servidor.
        let kinds: [SignStepKind] = tweakMode
            ? [.prepare, .extract, .inject, .pack, .upload, .sign]
            : [.prepare, .upload, .sign]
        let emitter = SignEmitter(
            initial: SignProgress(
                steps: kinds.map { SignStep(kind: $0) },
                fraction: 0.02,
                outputPath: app.filePath,
                finalName: customName,
                finalBundleID: customBundle,
                finalVersion: customVersion,
                fileSize: app.size
            ),
            continuation: continuation
        )

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("xsign-work-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: workDir) }

        // O envio segue numa sessão em segundo plano; o que roda no aparelho
        // (baixar, injetar, montar o envio) ganha alguns segundos extras.
        let backgroundGuard = BackgroundTaskGuard(name: "xsign-sign")
        defer { backgroundGuard.end() }
        DownloadNotifier.requestAuthorizationIfNeeded()
        let versionEdited = options.version.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) != app.version.trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? false

        // 1. Certificado, perfil e origem do .ipa
        let t0 = Date()
        emitter.step(.prepare, .running(detail: certificate.nickname))
        emitter.log(L.tr("signlog.start", customName))
        emitter.log(L.tr("signlog.cert", certificate.nickname, certificate.teamID), .detail)
        emitter.fraction(0.04)

        let isServerMatchedCert = (certificate.p12Path == "SERVER_MATCH")
        let p12Data = isServerMatchedCert ? nil : (try? Data(contentsOf: Paths.resolve(certificate.p12Path)))
        if !isServerMatchedCert && (p12Data == nil || p12Data?.isEmpty == true) {
            emitter.fail(.prepare, L.tr("signlog.error.p12Missing"))
            return
        }
        emitter.log(isServerMatchedCert ? L.tr("signlog.serverCert") : L.tr("signlog.p12Loaded"), .detail)

        guard let provData = try? Data(contentsOf: Paths.resolve(certificate.profilePath)), !provData.isEmpty else {
            emitter.fail(.prepare, L.tr("signlog.error.profileMissing"))
            return
        }
        emitter.log(L.tr("signlog.profileLoaded"), .detail)

        let localIPAURL: URL? = (app.filePath.isEmpty || app.filePath.hasPrefix("http")) ? nil : Paths.resolve(app.filePath)
        let hasLocalIPA = localIPAURL.map { fm.fileExists(atPath: $0.path) } ?? false
        let remoteIPAURL = app.downloadURL

        guard remoteIPAURL != nil || hasLocalIPA else {
            emitter.fail(.prepare, L.tr("signlog.error.noIPA"))
            return
        }
        emitter.step(.prepare, .done(seconds: Date().timeIntervalSince(t0)))
        emitter.fraction(0.08)

        var uploadLocalIPA: URL? = hasLocalIPA ? localIPAURL : nil
        var uploadRemoteURL: URL? = remoteIPAURL

        if tweakMode {
            // 2a. Extrair, injetar e reempacotar no aparelho
            do {
                try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
                let t1 = Date()
                emitter.step(.extract, .running(detail: nil))
                let sourceIPA: URL
                if hasLocalIPA, let localIPAURL {
                    sourceIPA = localIPAURL
                } else if let remoteIPAURL {
                    emitter.log(L.tr("signlog.downloading", remoteIPAURL.host ?? remoteIPAURL.absoluteString))
                    sourceIPA = try await download(remoteIPAURL, into: workDir)
                    emitter.log(L.tr("signlog.downloaded", sizeString(of: sourceIPA)), .detail)
                } else {
                    emitter.fail(.extract, L.tr("signlog.error.noIPA"))
                    return
                }
                try Task.checkCancellation()

                emitter.log(L.tr("signlog.extracting"))
                let unzipDir = workDir.appendingPathComponent("unpacked", isDirectory: true)
                try fm.createDirectory(at: unzipDir, withIntermediateDirectories: true)
                try fm.unzipItem(at: sourceIPA, to: unzipDir)
                guard let appDir = findAppBundle(in: unzipDir) else {
                    emitter.fail(.extract, L.tr("signlog.error.noApp"))
                    return
                }
                emitter.log(L.tr("signlog.extracted", appDir.lastPathComponent), .detail)
                emitter.step(.extract, .done(seconds: Date().timeIntervalSince(t1)))
                emitter.fraction(0.16)
                try Task.checkCancellation()

                let t2 = Date()
                emitter.step(.inject, .running(detail: "\(injections.count)"))
                emitter.log(L.tr("signlog.injecting", injections.count))
                let injector = TweakInjector(appDirectory: appDir) { text, level in
                    emitter.log(text, level)
                }
                let summary = try injector.inject(injections.map { Paths.resolve($0.path) })
                emitter.log(L.tr("signlog.injectDone", summary.injected.count), .success)
                emitter.step(.inject, .done(seconds: Date().timeIntervalSince(t2)))
                emitter.fraction(0.26)
                try Task.checkCancellation()

                let t3 = Date()
                emitter.step(.pack, .running(detail: nil))
                emitter.log(L.tr("signlog.packing"))
                let safeName = customName.replacingOccurrences(of: "/", with: "-")
                let packed = workDir.appendingPathComponent("\(safeName.isEmpty ? "app" : safeName).ipa")
                try fm.zipItem(at: unzipDir.appendingPathComponent("Payload", isDirectory: true),
                               to: packed, shouldKeepParent: true, compressionMethod: .deflate)
                // A pasta aberta não é mais necessária: libera espaço para o envio.
                try? fm.removeItem(at: unzipDir)
                emitter.log(L.tr("signlog.packed", sizeString(of: packed)), .detail)
                emitter.step(.pack, .done(seconds: Date().timeIntervalSince(t3)))
                emitter.fraction(0.34)

                uploadLocalIPA = packed
                uploadRemoteURL = nil
            } catch is CancellationError {
                emitter.finish()
                return
            } catch {
                emitter.fail(runningStep(in: emitter) ?? .extract, error.localizedDescription)
                return
            }
        } else {
            emitter.log(L.tr("signlog.options", customBundle, customVersion), .detail)
        }

        // 3. Servidor: envia e acompanha a assinatura de verdade
        let cleanBase = endpointBase.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard URL(string: "\(cleanBase)/api/xsign/v2/jobs") != nil, cleanBase.hasPrefix("http") else {
            emitter.fail(.upload, L.tr("signlog.error.badServer"))
            return
        }
        try? fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        let request = ServerSignRequest(
            base: cleanBase,
            app: app,
            certificate: certificate,
            options: options,
            p12Data: p12Data,
            provData: provData,
            password: KeychainHelper.read(key: certificate.keychainKey) ?? certificate.password,
            customName: customName,
            customBundleID: customBundle,
            customVersion: customVersion,
            applyVersion: versionEdited,
            remoteIPAURL: uploadRemoteURL,
            localIPAURL: uploadLocalIPA,
            workDir: workDir,
            localJobID: UUID().uuidString
        )
        let uploadBase = tweakMode ? 0.34 : 0.08
        let phase = ServerPhase(emitter: emitter, uploadBase: uploadBase,
                                urlMode: uploadRemoteURL != nil,
                                ipaSize: uploadLocalIPA.map { fileSize(of: $0) } ?? 0)

        // Registro em disco: se o iOS encerrar o app no meio, o resultado não se perde.
        PendingSignStore.markLive(request.localJobID)
        defer {
            PendingSignStore.unmarkLive(request.localJobID)
            PendingSignStore.remove(request.localJobID)
        }

        do {
            let decoded: RemoteSignResponse
            do {
                decoded = try await signWithServerJob(request, emitter: emitter, phase: phase)
            } catch is ServerJobsUnsupported {
                decoded = try await signLegacy(request, emitter: emitter, phase: phase)
            }

            let signSeconds = phase.signingSeconds
            emitter.log(L.tr("signlog.serverDone", String(format: "%.1f", signSeconds)), .success)
            emitter.log(L.tr("signlog.final", decoded.appName, decoded.bundleIdentifier, decoded.bundleVersion), .detail)
            emitter.log(L.tr("signlog.otaReady"), .success)
            emitter.log(L.tr("signlog.linkValid", 24), .detail)

            emitter.update { p in
                for i in p.steps.indices {
                    if case .running = p.steps[i].state {
                        p.steps[i].state = .done(seconds: p.steps[i].kind == .sign ? signSeconds : nil)
                    }
                }
                if let i = p.steps.firstIndex(where: { $0.kind == .sign }) { p.steps[i].state = .done(seconds: signSeconds) }
                p.fraction = 1.0
                p.finished = true
                p.outputPath = decoded.downloadUrl
                p.installURL = decoded.installUrl
                p.downloadURL = decoded.downloadUrl
                p.shareURL = decoded.shareUrl
                p.finalName = decoded.appName
                p.finalBundleID = decoded.bundleIdentifier
                p.finalVersion = decoded.bundleVersion
                p.expiresAt = decoded.expiresAt.flatMap(parseServerDate)
                if let size = decoded.fileSize { p.fileSize = size }
            }
            emitter.finish()
            await notifyIfInBackground(signed: decoded)
        } catch is CancellationError {
            emitter.finish()
        } catch let error as URLError where error.code == .cancelled {
            emitter.finish()
        } catch let failure as SignFailure {
            emitter.fail(failure.step, failure.message)
            await notifyIfInBackground(failure: failure.message, name: customName)
        } catch {
            let message = L.tr("signlog.error.connection", error.localizedDescription)
            emitter.fail(runningStep(in: emitter) ?? .upload, message)
            await notifyIfInBackground(failure: message, name: customName)
        }
    }

    // MARK: Trabalho no servidor (envio em partes + estado real)

    private static func signWithServerJob(
        _ r: ServerSignRequest,
        emitter: SignEmitter,
        phase: ServerPhase
    ) async throws -> RemoteSignResponse {
        let fm = FileManager.default
        let chunked = r.remoteIPAURL == nil
        guard let createURL = URL(string: "\(r.base)/api/xsign/v2/jobs") else {
            throw SignFailure(step: .upload, message: L.tr("signlog.error.badServer"))
        }
        let ipaSize = r.localIPAURL.map { fileSize(of: $0) } ?? 0
        if chunked && (r.localIPAURL == nil || ipaSize <= 0) {
            throw SignFailure(step: .upload, message: L.tr("signlog.error.noIPA"))
        }

        // 1. Cria o trabalho: certificado, perfil e opções (o .ipa vai depois, em partes).
        emitter.step(.upload, .running(detail: chunked ? L.tr("sign.detail.preparing") : L.tr("signlog.modeURL.short")))
        var extra: [String: String] = [:]
        if chunked, let local = r.localIPAURL {
            extra["ipaSize"] = String(ipaSize)
            extra["ipaName"] = local.lastPathComponent
        }
        let boundary = "XSignBoundary-\(UUID().uuidString)"
        let bodyURL = fm.temporaryDirectory.appendingPathComponent("xsign-job-\(UUID().uuidString).body")
        defer { try? fm.removeItem(at: bodyURL) }
        do {
            try writeMultipartBody(to: bodyURL, boundary: boundary, request: r, includeLocalIPA: false, extraFields: extra)
        } catch {
            throw SignFailure(step: .upload, message: L.tr("signlog.error.prepare", error.localizedDescription))
        }

        var createRequest = URLRequest(url: createURL, timeoutInterval: 120)
        createRequest.httpMethod = "POST"
        createRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        createRequest.setValue(KeychainHelper.deviceID, forHTTPHeaderField: "X-XSign-Device")
        let (createData, createResponse) = try await URLSession.shared.upload(for: createRequest, fromFile: bodyURL)
        let createStatus = (createResponse as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(createStatus) else {
            if createStatus == 404 || createStatus == 405 { throw ServerJobsUnsupported() }
            emitter.log(L.tr("signlog.serverStatus", createStatus), .detail)
            throw SignFailure(step: .upload, message: serverMessage(status: createStatus, data: createData))
        }
        let created = try decodeState(createData, step: .upload)
        let jobID = created.id

        PendingSignStore.save(PendingSignJob(
            jobID: r.localJobID,
            app: r.app,
            certificateID: r.certificate.id,
            options: r.options,
            bodyPath: "",
            serverJobID: jobID,
            serverBase: r.base
        ))

        do {
            if chunked, let local = r.localIPAURL {
                try await uploadChunks(of: local, size: ipaSize, job: created, request: r, emitter: emitter, phase: phase)
            } else {
                emitter.log(L.tr("signlog.modeURL"))
            }
            return try await waitForServer(jobID: jobID, base: r.base, emitter: emitter, phase: phase, chunked: chunked)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                let base = r.base
                Task.detached { await Self.cancelServerJob(base: base, jobID: jobID) }
            }
            throw error
        }
    }

    /// Envia o .ipa em partes (o Cloudflare recusa pedidos acima de 100 MB).
    /// Todas as partes entram de uma vez na sessão em segundo plano, então o
    /// envio continua mesmo com o XSign fora da tela.
    private static func uploadChunks(
        of ipa: URL,
        size: Int64,
        job: ServerJobState,
        request r: ServerSignRequest,
        emitter: SignEmitter,
        phase: ServerPhase
    ) async throws {
        let chunkSize = max(job.chunkSize, 1)
        let count = job.totalChunks
        guard count > 0 else { throw SignFailure(step: .upload, message: L.tr("signlog.error.badResponse")) }
        let sizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        emitter.log(L.tr("signlog.upload.parts", sizeText, count))

        let chunkDir = r.workDir.appendingPathComponent("chunks-\(job.id)", isDirectory: true)
        let files: [URL]
        do {
            try FileManager.default.createDirectory(at: chunkDir, withIntermediateDirectories: true)
            files = try writeChunks(of: ipa, chunkSize: chunkSize, count: count, into: chunkDir)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SignFailure(step: .upload, message: L.tr("signlog.error.prepare", error.localizedDescription))
        }
        defer { try? FileManager.default.removeItem(at: chunkDir) }

        let uploadBase = phase.uploadBase
        let progress = ChunkProgress(total: size)
        let reporter = UploadProgressDelegate { fraction in
            let pct = Int((fraction * 100).rounded(.down))
            emitter.update { p in
                if let i = p.steps.firstIndex(where: { $0.kind == .upload }) { p.steps[i].state = .running(detail: "\(pct)%") }
                p.fraction = max(p.fraction, uploadBase + (RemoteSigningService.uploadTop - uploadBase) * fraction)
            }
        } milestone: { pct in
            emitter.log(L.tr("signlog.uploadProgress", pct), .detail)
        }
        reporter.report(sent: 0, expected: size)

        let started = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                let file = files[index]
                let expected = min(chunkSize, size - Int64(index) * chunkSize)
                group.addTask {
                    try await Self.uploadChunk(index: index, file: file, expected: expected, jobID: job.id,
                                          request: r, progress: progress, reporter: reporter, emitter: emitter)
                }
            }
            try await group.waitForAll()
        }
        let seconds = Date().timeIntervalSince(started)
        emitter.log(L.tr("signlog.upload.done", sizeText, String(format: "%.1f", seconds)), .success)
        emitter.step(.upload, .done(seconds: seconds))
        emitter.fraction(uploadTop)
    }

    private static func uploadChunk(
        index: Int,
        file: URL,
        expected: Int64,
        jobID: String,
        request r: ServerSignRequest,
        progress: ChunkProgress,
        reporter: UploadProgressDelegate,
        emitter: SignEmitter
    ) async throws {
        guard let url = URL(string: "\(r.base)/api/xsign/v2/jobs/\(jobID)/chunks/\(index)") else {
            throw SignFailure(step: .upload, message: L.tr("signlog.error.badServer"))
        }
        var request = URLRequest(url: url, timeoutInterval: 600)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(KeychainHelper.deviceID, forHTTPHeaderField: "X-XSign-Device")

        var attempt = 0
        while true {
            attempt += 1
            try Task.checkCancellation()
            var failure = ""
            do {
                let (data, response) = try await SignUploadSession.shared.upload(
                    request,
                    fromFile: file,
                    jobID: "chunk:\(r.localJobID):\(index)"
                ) { sent, _ in
                    reporter.report(sent: progress.set(index, min(sent, expected)), expected: progress.total)
                }
                if (200...299).contains(response.statusCode) {
                    reporter.report(sent: progress.set(index, expected), expected: progress.total)
                    try? FileManager.default.removeItem(at: file)
                    return
                }
                failure = serverMessage(status: response.statusCode, data: data)
                // Sem volta: o trabalho sumiu do servidor ou é de outro aparelho.
                if [403, 404, 410, 413].contains(response.statusCode) {
                    throw SignFailure(step: .upload, message: failure)
                }
            } catch let error as SignFailure {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                failure = error.localizedDescription
            }

            reporter.report(sent: progress.set(index, 0), expected: progress.total)
            if attempt >= 4 {
                throw SignFailure(step: .upload, message: L.tr("signlog.error.chunk", index + 1, failure))
            }
            emitter.log(L.tr("signlog.upload.retry", index + 1, failure), .warning)
            try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
        }
    }

    /// Acompanha o trabalho até o servidor terminar. Cada consulta espera até
    /// 20 s por uma mudança, então a tela muda assim que o servidor muda.
    private static func waitForServer(
        jobID: String,
        base: String,
        emitter: SignEmitter,
        phase: ServerPhase,
        chunked: Bool
    ) async throws -> RemoteSignResponse {
        let ticker = Task.detached { await phase.tick() }
        defer { ticker.cancel() }

        var version = 0
        var failures = 0
        var firstAnswer = true
        while true {
            try Task.checkCancellation()
            guard let url = URL(string: "\(base)/api/xsign/v2/jobs/\(jobID)?wait=20&v=\(version)") else {
                throw SignFailure(step: .sign, message: L.tr("signlog.error.badServer"))
            }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
            request.setValue(KeychainHelper.deviceID, forHTTPHeaderField: "X-XSign-Device")

            let pair: (Data, URLResponse)
            do {
                pair = try await URLSession.shared.data(for: request)
            } catch let error as URLError where error.code != .cancelled {
                // Rede instável ou o app voltou do segundo plano: tenta de novo.
                failures += 1
                if failures >= 8 {
                    throw SignFailure(step: phase.currentStep, message: L.tr("signlog.error.connection", error.localizedDescription))
                }
                if failures == 2 { emitter.log(L.tr("signlog.server.retrying"), .warning) }
                try await Task.sleep(nanoseconds: UInt64(min(failures, 5)) * 2_000_000_000)
                continue
            }
            let (data, response) = pair

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else {
                let message = serverMessage(status: status, data: data)
                if status == 403 || status == 404 { throw SignFailure(step: phase.currentStep, message: message) }
                failures += 1
                if failures >= 8 { throw SignFailure(step: phase.currentStep, message: message) }
                if failures == 2 { emitter.log(L.tr("signlog.server.retrying"), .warning) }
                try await Task.sleep(nanoseconds: 3_000_000_000)
                continue
            }
            failures = 0

            let state = try decodeState(data, step: phase.currentStep)
            version = state.version
            phase.apply(status: state.status, seconds: state.statusSeconds ?? 0, position: state.queuePosition,
                        signingSeconds: state.signingSeconds)

            switch state.status {
            case "done":
                guard let result = state.result else {
                    throw SignFailure(step: .sign, message: L.tr("signlog.error.badResponse"))
                }
                return result
            case "failed":
                if let code = state.errorStatus { emitter.log(L.tr("signlog.serverStatus", code), .detail) }
                throw SignFailure(step: phase.currentStep,
                                  message: state.error ?? L.tr("signlog.error.http", state.errorStatus ?? 500))
            case "uploading" where chunked && firstAnswer && state.receivedChunks < state.totalChunks:
                // Todas as partes foram aceitas, mas o servidor não tem todas.
                throw SignFailure(step: .upload, message: L.tr("signlog.error.chunksMissing"))
            default:
                break
            }
            firstAnswer = false
        }
    }

    private static func cancelServerJob(base: String, jobID: String) async {
        guard let url = URL(string: "\(base)/api/xsign/v2/jobs/\(jobID)") else { return }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "DELETE"
        request.setValue(KeychainHelper.deviceID, forHTTPHeaderField: "X-XSign-Device")
        _ = try? await URLSession.shared.data(for: request)
    }

    private static func decodeState(_ data: Data, step: SignStepKind) throws -> ServerJobState {
        do {
            return try JSONDecoder().decode(ServerJobState.self, from: data)
        } catch {
            throw SignFailure(step: step, message: L.tr("signlog.error.badResponse"))
        }
    }

    // MARK: Retomar depois que o iOS encerrou o app

    enum ResumedJob {
        case done(RemoteSignResponse)
        case gone
        case pending
    }

    /// Consulta, sem esperar, um trabalho iniciado antes de o app ser encerrado.
    static func fetchJobState(base: String, jobID: String) async -> ResumedJob {
        guard let url = URL(string: "\(base)/api/xsign/v2/jobs/\(jobID)") else { return .gone }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue(KeychainHelper.deviceID, forHTTPHeaderField: "X-XSign-Device")
        guard let pair = try? await URLSession.shared.data(for: request),
              let status = (pair.1 as? HTTPURLResponse)?.statusCode else { return .pending }
        if status == 403 || status == 404 { return .gone }
        guard (200...299).contains(status),
              let state = try? JSONDecoder().decode(ServerJobState.self, from: pair.0) else { return .pending }
        switch state.status {
        case "done":
            if let result = state.result { return .done(result) }
            return .gone
        case "failed":
            return .gone
        default:
            return .pending
        }
    }

    // MARK: Envio antigo (servidor sem /api/xsign/v2)

    /// Um único pedido com tudo dentro e a resposta só no fim da assinatura.
    private static func signLegacy(
        _ r: ServerSignRequest,
        emitter: SignEmitter,
        phase: ServerPhase
    ) async throws -> RemoteSignResponse {
        let fm = FileManager.default
        guard let url = URL(string: "\(r.base)/api/xsign/sign") else {
            throw SignFailure(step: .upload, message: L.tr("signlog.error.badServer"))
        }
        let boundary = "XSignBoundary-\(UUID().uuidString)"
        let bodyURL = fm.temporaryDirectory.appendingPathComponent("xsign-req-\(UUID().uuidString).body")
        defer { try? fm.removeItem(at: bodyURL) }
        do {
            try writeMultipartBody(to: bodyURL, boundary: boundary, request: r, includeLocalIPA: true, extraFields: [:])
        } catch {
            throw SignFailure(step: .upload, message: L.tr("signlog.error.prepare", error.localizedDescription))
        }

        if r.remoteIPAURL != nil {
            emitter.step(.upload, .running(detail: L.tr("signlog.modeURL.short")))
            emitter.log(L.tr("signlog.modeURL"))
        } else {
            emitter.step(.upload, .running(detail: "0%"))
            emitter.log(L.tr("signlog.uploading", sizeString(of: bodyURL)))
        }

        var request = URLRequest(url: url, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(KeychainHelper.deviceID, forHTTPHeaderField: "X-XSign-Device")

        // Quando o envio termina, a tela passa a contar o tempo da assinatura.
        let uploadBase = phase.uploadBase
        let uploadStarted = Date()
        let handoff = OneShot()
        let ticker = TickerBox()
        defer { ticker.cancel() }
        let uploadProgress = UploadProgressDelegate { fraction in
            if fraction >= 1 {
                guard handoff.fire() else { return }
                emitter.step(.upload, .done(seconds: Date().timeIntervalSince(uploadStarted)))
                emitter.fraction(RemoteSigningService.uploadTop)
                phase.apply(status: "signing", seconds: 0, position: nil)
                ticker.set(Task.detached { await phase.tick() })
                return
            }
            guard r.remoteIPAURL == nil else { return }
            let pct = Int((fraction * 100).rounded(.down))
            emitter.update { p in
                if let i = p.steps.firstIndex(where: { $0.kind == .upload }) { p.steps[i].state = .running(detail: "\(pct)%") }
                p.fraction = max(p.fraction, uploadBase + (RemoteSigningService.uploadTop - uploadBase) * fraction)
            }
        } milestone: { pct in
            guard r.remoteIPAURL == nil else { return }
            emitter.log(L.tr("signlog.uploadProgress", pct), .detail)
        }

        PendingSignStore.save(PendingSignJob(
            jobID: r.localJobID,
            app: r.app,
            certificateID: r.certificate.id,
            options: r.options,
            bodyPath: bodyURL.path
        ))

        let (respData, urlResponse) = try await SignUploadSession.shared.upload(
            request,
            fromFile: bodyURL,
            jobID: r.localJobID
        ) { sent, expected in
            uploadProgress.report(sent: sent, expected: expected)
        }
        let httpStatus = urlResponse.statusCode
        guard (200...299).contains(httpStatus) else {
            emitter.log(L.tr("signlog.serverStatus", httpStatus), .detail)
            throw SignFailure(step: handoff.fired ? .sign : .upload,
                              message: serverMessage(status: httpStatus, data: respData))
        }
        do {
            return try JSONDecoder().decode(RemoteSignResponse.self, from: respData)
        } catch {
            throw SignFailure(step: .sign, message: L.tr("signlog.error.badResponse"))
        }
    }

    // MARK: Mensagens de erro do servidor

    /// Nunca mostra HTML cru (como a página 413 do Cloudflare): usa a mensagem
    /// do servidor quando ela vem em JSON e uma explicação curta no resto.
    static func serverMessage(status: Int, data: Data) -> String {
        if let message = (try? JSONDecoder().decode(RemoteErrorResponse.self, from: data))?.error?
            .trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            return message
        }
        switch status {
        case 413: return L.tr("signlog.error.tooLarge")
        case 429: return L.tr("signlog.error.busy")
        case 502, 503, 504, 520...527, 530: return L.tr("signlog.error.serverDown", status)
        default: return L.tr("signlog.error.http", status)
        }
    }

    // MARK: Notificação com o app fora da tela

    private static func isAppActive() async -> Bool {
        await MainActor.run { UIApplication.shared.applicationState == .active }
    }

    private static func notifyIfInBackground(signed decoded: RemoteSignResponse) async {
        let active = await isAppActive()
        guard !active else { return }
        SignNotifier.notifySigned(name: decoded.appName, installURL: decoded.installUrl, bundleID: decoded.bundleIdentifier)
    }

    private static func notifyIfInBackground(failure message: String, name: String) async {
        let active = await isAppActive()
        guard !active else { return }
        SignNotifier.notifyFailed(name: name, message: message)
    }

    static func parseServerDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    // MARK: Auxiliares

    private static func runningStep(in emitter: SignEmitter) -> SignStepKind? {
        emitter.snapshot().steps.first(where: { step in
            if case .running = step.state { return true }
            return false
        })?.kind
    }

    private static func download(_ url: URL, into directory: URL) async throws -> URL {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 600)
        req.setValue("XSign/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        let (temp, response) = try await URLSession.shared.download(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temp)
            throw URLError(.badServerResponse)
        }
        let dest = directory.appendingPathComponent("source.ipa")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }

    private static func findAppBundle(in unzipDir: URL) -> URL? {
        let payload = unzipDir.appendingPathComponent("Payload", isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)) ?? []
        return items.first(where: { $0.pathExtension.lowercased() == "app" })
    }

    private static func fileSize(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    private static func sizeString(of url: URL) -> String {
        ByteCountFormatter.string(fromByteCount: fileSize(of: url), countStyle: .file)
    }

    /// Grava as partes do .ipa em arquivos (a sessão em segundo plano só envia
    /// arquivos), lendo 4 MB por vez para não pesar na memória.
    private static func writeChunks(of ipa: URL, chunkSize: Int64, count: Int, into dir: URL) throws -> [URL] {
        let reader = try FileHandle(forReadingFrom: ipa)
        defer { try? reader.close() }
        var urls: [URL] = []
        for index in 0..<count {
            try Task.checkCancellation()
            let url = dir.appendingPathComponent("part-\(index)")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let writer = try FileHandle(forWritingTo: url)
            defer { try? writer.close() }
            var remaining = chunkSize
            while remaining > 0 {
                let piece: Data = try autoreleasepool {
                    try reader.read(upToCount: Int(min(remaining, 4 * 1024 * 1024))) ?? Data()
                }
                if piece.isEmpty { break }
                try writer.write(contentsOf: piece)
                remaining -= Int64(piece.count)
            }
            urls.append(url)
        }
        return urls
    }

    private static func writeMultipartBody(
        to fileURL: URL,
        boundary: String,
        request r: ServerSignRequest,
        includeLocalIPA: Bool,
        extraFields: [String: String]
    ) throws {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }

        func writeString(_ str: String) throws {
            if let data = str.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
        }

        func appendField(name: String, value: String) throws {
            guard !value.isEmpty else { return }
            try writeString("--\(boundary)\r\n")
            try writeString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            try writeString("\(value)\r\n")
        }

        func appendFileData(name: String, filename: String, mimeType: String, data: Data) throws {
            try writeString("--\(boundary)\r\n")
            try writeString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
            try writeString("Content-Type: \(mimeType)\r\n\r\n")
            try handle.write(contentsOf: data)
            try writeString("\r\n")
        }

        let options = r.options
        try appendField(name: "password", value: r.password)
        try appendField(name: "expiryHours", value: "24")
        try appendField(name: "authorizedUse", value: "true")
        try appendField(name: "customName", value: r.customName)
        try appendField(name: "customBundleId", value: r.customBundleID)
        try appendField(name: "customVersion", value: r.customVersion)
        if r.applyVersion { try appendField(name: "applyVersion", value: "true") }

        // Opções aplicadas pelo zsign no servidor.
        try appendField(name: "removeExtensions", value: options.removeExtensions ? "true" : "false")
        try appendField(name: "removeDeviceRestriction", value: options.removeDeviceRestriction ? "true" : "false")
        try appendField(name: "fileSharing", value: options.fileSharing ? "true" : "false")
        if let minOS = options.minOS?.trimmingCharacters(in: .whitespacesAndNewlines), !minOS.isEmpty {
            try appendField(name: "minOS", value: minOS)
        }
        for (name, value) in extraFields.sorted(by: { $0.key < $1.key }) {
            try appendField(name: name, value: value)
        }
        if let icon = options.iconData, icon.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            try appendFileData(name: "icon", filename: "icon.png", mimeType: "image/png", data: icon)
        }

        if let p12Data = r.p12Data, !p12Data.isEmpty {
            try appendFileData(name: "p12", filename: "certificate.p12", mimeType: "application/x-pkcs12", data: p12Data)
        } else {
            try appendField(name: "useServerCert", value: "true")
            try appendField(name: "certTeamId", value: r.certificate.teamID)
            if let appID = r.certificate.appID { try appendField(name: "certAppId", value: appID) }
            try appendField(name: "certName", value: r.certificate.nickname)
        }
        try appendFileData(name: "mobileprovision", filename: "profile.mobileprovision", mimeType: "application/x-apple-aspen-config", data: r.provData)

        if let remoteIPAURL = r.remoteIPAURL {
            // Modo B: envia apenas a URL e a VPS baixa o .ipa direto na velocidade do servidor
            try appendField(name: "ipaUrl", value: remoteIPAURL.absoluteString)
        } else if includeLocalIPA, let localIPAURL = r.localIPAURL {
            // Modo A: envia o arquivo .ipa local em chunks de 256 KB sem estourar a RAM
            try writeString("--\(boundary)\r\n")
            try writeString("Content-Disposition: form-data; name=\"ipa\"; filename=\"\(localIPAURL.lastPathComponent)\"\r\n")
            try writeString("Content-Type: application/octet-stream\r\n\r\n")
            let reader = try FileHandle(forReadingFrom: localIPAURL)
            defer { try? reader.close() }
            while let chunk = try reader.read(upToCount: 256 * 1024), !chunk.isEmpty {
                try handle.write(contentsOf: chunk)
            }
            try writeString("\r\n")
        }

        try writeString("--\(boundary)--\r\n")
    }
}

// MARK: - Etapa do servidor na tela

/// Mostra a etapa real do servidor (fila, download, assinatura) com o tempo
/// passando. A barra só avança devagar enquanto espera e nunca chega a 100%
/// antes da resposta final.
final class ServerPhase: @unchecked Sendable {
    let uploadBase: Double
    private let emitter: SignEmitter
    private let urlMode: Bool
    private let ipaSize: Int64
    private let lock = NSLock()
    private var status = ""
    private var since = Date()
    private var position: Int?
    private var signingStarted: Date?
    private var signingEnded: Date?
    private var uploadDone: Bool
    private var downloadStarted: Date?
    private var serverSigningSeconds: Double?

    init(emitter: SignEmitter, uploadBase: Double, urlMode: Bool, ipaSize: Int64) {
        self.emitter = emitter
        self.uploadBase = uploadBase
        self.urlMode = urlMode
        self.ipaSize = ipaSize
        self.uploadDone = !urlMode
    }

    /// Passo em andamento, para marcar uma falha no lugar certo.
    var currentStep: SignStepKind {
        lock.lock()
        defer { lock.unlock() }
        return uploadDone ? .sign : .upload
    }

    /// Segundos da assinatura no servidor (da entrada em "signing" até agora).
    var signingSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        if let serverSigningSeconds { return serverSigningSeconds }
        guard let start = signingStarted else { return 0 }
        return (signingEnded ?? Date()).timeIntervalSince(start)
    }

    func apply(status newStatus: String, seconds: Double, position newPosition: Int?, signingSeconds reported: Double? = nil) {
        lock.lock()
        if let reported { serverSigningSeconds = reported }
        let changed = newStatus != status
        if changed {
            status = newStatus
            since = Date().addingTimeInterval(-seconds)
        }
        position = newPosition
        var finishedDownload: Double?
        if newStatus == "downloading" && downloadStarted == nil { downloadStarted = since }
        if newStatus == "signing" {
            if signingStarted == nil { signingStarted = since }
            if !uploadDone {
                uploadDone = true
                finishedDownload = downloadStarted.map { since.timeIntervalSince($0) } ?? 0
            }
        }
        if newStatus == "done" || newStatus == "failed" { signingEnded = Date() }
        lock.unlock()

        if let finishedDownload {
            emitter.step(.upload, .done(seconds: finishedDownload))
            emitter.fraction(RemoteSigningService.uploadTop)
        }
        if changed {
            switch newStatus {
            case "queued": emitter.log(L.tr("signlog.server.queued"))
            case "downloading": emitter.log(L.tr("signlog.server.downloading"))
            case "signing": emitter.log(L.tr("signlog.server.signing"))
            default: break
            }
        }
        render()
    }

    /// Atualiza o tempo na tela a cada segundo até ser cancelado.
    func tick() async {
        while !Task.isCancelled {
            render()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func render() {
        lock.lock()
        let status = self.status
        let elapsed = max(0, Date().timeIntervalSince(since))
        let position = self.position
        let uploadDone = self.uploadDone
        let signingElapsed = signingStarted.map { Date().timeIntervalSince($0) } ?? 0
        lock.unlock()

        let top = RemoteSigningService.uploadTop
        let step: SignStepKind = uploadDone ? .sign : .upload
        switch status {
        case "queued":
            let detail = position.map { L.tr("sign.detail.queuePosition", $0) } ?? L.tr("sign.detail.queued")
            emitter.step(step, .running(detail: detail))
        case "downloading":
            emitter.step(.upload, .running(detail: L.tr("sign.detail.downloading", Int(elapsed))))
            emitter.fraction(Self.creep(from: uploadBase, to: top - 0.04, elapsed: elapsed, tau: 25))
        case "signing":
            emitter.step(.sign, .running(detail: L.tr("sign.detail.seconds", Int(elapsed))))
            // Quanto maior o app, mais devagar a barra anda (o servidor leva mais).
            let megabytes = Double(max(ipaSize, 0)) / 1_048_576
            let tau = ipaSize > 0 ? 8 + megabytes * 0.25 : 30
            emitter.fraction(Self.creep(from: top, to: 0.97, elapsed: signingElapsed, tau: tau))
        default:
            break
        }
    }

    private static func creep(from start: Double, to end: Double, elapsed: Double, tau: Double) -> Double {
        start + (end - start) * (1 - exp(-elapsed / max(tau, 1)))
    }
}

// MARK: - Progresso do upload

/// Soma o que cada parte já enviou.
final class ChunkProgress: @unchecked Sendable {
    let total: Int64
    private let lock = NSLock()
    private var sent: [Int: Int64] = [:]

    init(total: Int64) { self.total = total }

    /// Atualiza uma parte e devolve o total enviado.
    func set(_ index: Int, _ bytes: Int64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        sent[index] = bytes
        return sent.values.reduce(0, +)
    }
}

/// Dispara uma vez só (passagem do envio para a assinatura).
final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    var fired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Guarda a Task do relógio para cancelar no fim.
final class TickerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func set(_ newTask: Task<Void, Never>) {
        lock.lock()
        let cancelNow = cancelled
        if !cancelNow { task = newTask }
        lock.unlock()
        if cancelNow { newTask.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = task
        task = nil
        lock.unlock()
        current?.cancel()
    }
}

final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: (Double) -> Void
    private let onMilestone: (Int) -> Void
    private let lock = NSLock()
    private var lastSent: CFAbsoluteTime = 0
    private var nextMilestone = 25

    init(onProgress: @escaping (Double) -> Void, milestone: @escaping (Int) -> Void) {
        self.onProgress = onProgress
        self.onMilestone = milestone
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        report(sent: totalBytesSent, expected: totalBytesExpectedToSend)
    }

    /// Throttle do progresso (também usado pela sessão em segundo plano).
    func report(sent totalBytesSent: Int64, expected totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        let now = CFAbsoluteTimeGetCurrent()

        lock.lock()
        let shouldSend = now - lastSent > 0.15 || fraction >= 1
        if shouldSend { lastSent = now }
        var reached: [Int] = []
        while nextMilestone < 100 && Int(fraction * 100) >= nextMilestone {
            reached.append(nextMilestone)
            nextMilestone += 25
        }
        lock.unlock()

        if shouldSend { onProgress(fraction) }
        reached.forEach(onMilestone)
    }
}
