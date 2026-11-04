import Foundation
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

    func fraction(_ value: Double) {
        update { $0.fraction = value }
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

        let kinds: [SignStepKind] = tweakMode ? [.extract, .inject, .pack, .sign] : [.extract, .modify, .sign, .pack]
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

        // 1. Certificado e origem do .ipa
        let t0 = Date()
        emitter.step(.extract, .running(detail: certificate.nickname))
        emitter.log(L.tr("signlog.start", customName))
        emitter.log(L.tr("signlog.cert", certificate.nickname, certificate.teamID), .detail)
        emitter.fraction(0.06)

        let isServerMatchedCert = (certificate.p12Path == "SERVER_MATCH")
        let p12Data = isServerMatchedCert ? nil : (try? Data(contentsOf: Paths.resolve(certificate.p12Path)))
        if !isServerMatchedCert && (p12Data == nil || p12Data?.isEmpty == true) {
            emitter.fail(.extract, L.tr("signlog.error.p12Missing"))
            return
        }
        emitter.log(isServerMatchedCert ? L.tr("signlog.serverCert") : L.tr("signlog.p12Loaded"), .detail)

        guard let provData = try? Data(contentsOf: Paths.resolve(certificate.profilePath)), !provData.isEmpty else {
            emitter.fail(.extract, L.tr("signlog.error.profileMissing"))
            return
        }
        emitter.log(L.tr("signlog.profileLoaded"), .detail)

        let localIPAURL: URL? = (app.filePath.isEmpty || app.filePath.hasPrefix("http")) ? nil : Paths.resolve(app.filePath)
        let hasLocalIPA = localIPAURL.map { fm.fileExists(atPath: $0.path) } ?? false
        let remoteIPAURL = app.downloadURL

        guard remoteIPAURL != nil || hasLocalIPA else {
            emitter.fail(.extract, L.tr("signlog.error.noIPA"))
            return
        }

        var uploadLocalIPA: URL? = hasLocalIPA ? localIPAURL : nil
        var uploadRemoteURL: URL? = remoteIPAURL

        if tweakMode {
            // 2a. Extrair, injetar e reempacotar no aparelho
            do {
                try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
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
                emitter.step(.extract, .done(seconds: Date().timeIntervalSince(t0)))
                emitter.fraction(0.25)
                try Task.checkCancellation()

                let t1 = Date()
                emitter.step(.inject, .running(detail: "\(injections.count)"))
                emitter.log(L.tr("signlog.injecting", injections.count))
                let injector = TweakInjector(appDirectory: appDir) { text, level in
                    emitter.log(text, level)
                }
                let summary = try injector.inject(injections.map { Paths.resolve($0.path) })
                emitter.log(L.tr("signlog.injectDone", summary.injected.count), .success)
                emitter.step(.inject, .done(seconds: Date().timeIntervalSince(t1)))
                emitter.fraction(0.42)
                try Task.checkCancellation()

                let t2 = Date()
                emitter.step(.pack, .running(detail: nil))
                emitter.log(L.tr("signlog.packing"))
                let safeName = customName.replacingOccurrences(of: "/", with: "-")
                let packed = workDir.appendingPathComponent("\(safeName.isEmpty ? "app" : safeName).ipa")
                try fm.zipItem(at: unzipDir.appendingPathComponent("Payload", isDirectory: true),
                               to: packed, shouldKeepParent: true, compressionMethod: .deflate)
                emitter.log(L.tr("signlog.packed", sizeString(of: packed)), .detail)
                emitter.step(.pack, .done(seconds: Date().timeIntervalSince(t2)))
                emitter.fraction(0.55)

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
            emitter.step(.extract, .done(seconds: Date().timeIntervalSince(t0)))
            let t1 = Date()
            emitter.step(.modify, .running(detail: customBundle))
            emitter.log(L.tr("signlog.options", customBundle, customVersion), .detail)
            emitter.step(.modify, .done(seconds: Date().timeIntervalSince(t1)))
            emitter.fraction(0.28)
        }

        // 3. Montar o envio
        let boundary = "XSignBoundary-\(UUID().uuidString)"
        let bodyURL = fm.temporaryDirectory.appendingPathComponent("xsign-req-\(UUID().uuidString).body")
        defer { try? fm.removeItem(at: bodyURL) }
        let password = KeychainHelper.read(key: certificate.keychainKey) ?? certificate.password

        do {
            try writeMultipartBody(
                to: bodyURL,
                boundary: boundary,
                p12Data: p12Data,
                provData: provData,
                password: password,
                teamID: certificate.teamID,
                appID: certificate.appID,
                certName: certificate.nickname,
                customName: customName,
                customBundleID: customBundle,
                customVersion: customVersion,
                remoteIPAURL: uploadRemoteURL,
                localIPAURL: uploadLocalIPA
            )
        } catch {
            emitter.fail(tweakMode ? .sign : .modify, L.tr("signlog.error.prepare", error.localizedDescription))
            return
        }

        // 4. Assinar no servidor (Modo B por URL ou Modo A por upload)
        let t3 = Date()
        if uploadRemoteURL != nil {
            emitter.step(.sign, .running(detail: L.tr("signlog.modeURL.short")))
            emitter.log(L.tr("signlog.modeURL"))
        } else {
            emitter.step(.sign, .running(detail: "0%"))
            emitter.log(L.tr("signlog.uploading", sizeString(of: bodyURL)))
        }

        let cleanBase = endpointBase.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard let url = URL(string: "\(cleanBase)/api/xsign/sign") else {
            emitter.fail(.sign, L.tr("signlog.error.badServer"))
            return
        }

        var request = URLRequest(url: url, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(KeychainHelper.deviceID, forHTTPHeaderField: "X-XSign-Device")

        let baseFraction = tweakMode ? 0.55 : 0.3
        let uploadDelegate = UploadProgressDelegate { fraction in
            let pct = Int((fraction * 100).rounded())
            emitter.update { p in
                if let i = p.steps.firstIndex(where: { $0.kind == .sign }) { p.steps[i].state = .running(detail: "\(pct)%") }
                p.fraction = baseFraction + (0.85 - baseFraction) * fraction
            }
        } milestone: { pct in
            emitter.log(L.tr("signlog.uploadProgress", pct), .detail)
        }

        do {
            let (respData, urlResponse) = try await URLSession.shared.upload(for: request, fromFile: bodyURL, delegate: uploadDelegate)
            let httpStatus = (urlResponse as? HTTPURLResponse)?.statusCode ?? 500

            guard (200...299).contains(httpStatus) else {
                let serverMsg = (try? JSONDecoder().decode(RemoteErrorResponse.self, from: respData))?.error
                    ?? String(data: respData, encoding: .utf8)
                    ?? "HTTP \(httpStatus)"
                emitter.log(L.tr("signlog.serverStatus", httpStatus), .detail)
                emitter.fail(.sign, serverMsg)
                return
            }

            let decoded = try JSONDecoder().decode(RemoteSignResponse.self, from: respData)
            emitter.log(L.tr("signlog.serverDone", String(format: "%.1f", Date().timeIntervalSince(t3))), .success)
            emitter.step(.sign, .done(seconds: Date().timeIntervalSince(t3)))
            emitter.fraction(0.9)

            if !tweakMode {
                emitter.step(.pack, .running(detail: nil))
            }
            emitter.log(L.tr("signlog.final", decoded.appName, decoded.bundleIdentifier, decoded.bundleVersion), .detail)
            emitter.log(L.tr("signlog.otaReady"), .success)
            emitter.log(L.tr("signlog.linkValid", 24), .detail)

            emitter.update { p in
                if !tweakMode, let i = p.steps.firstIndex(where: { $0.kind == .pack }) { p.steps[i].state = .done(seconds: 0.1) }
                p.fraction = 1.0
                p.finished = true
                p.outputPath = decoded.downloadUrl
                p.installURL = decoded.installUrl
                p.downloadURL = decoded.downloadUrl
                p.shareURL = decoded.shareUrl
                p.finalName = decoded.appName
                p.finalBundleID = decoded.bundleIdentifier
                p.finalVersion = decoded.bundleVersion
                if let size = decoded.fileSize { p.fileSize = size }
            }
            emitter.finish()
        } catch is CancellationError {
            emitter.finish()
        } catch let error as URLError where error.code == .cancelled {
            emitter.finish()
        } catch {
            emitter.fail(.sign, L.tr("signlog.error.connection", error.localizedDescription))
        }
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

    private static func sizeString(of url: URL) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private static func writeMultipartBody(
        to fileURL: URL,
        boundary: String,
        p12Data: Data?,
        provData: Data,
        password: String,
        teamID: String,
        appID: String?,
        certName: String,
        customName: String,
        customBundleID: String,
        customVersion: String,
        remoteIPAURL: URL?,
        localIPAURL: URL?
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

        try appendField(name: "password", value: password)
        try appendField(name: "expiryHours", value: "24")
        try appendField(name: "authorizedUse", value: "true")
        try appendField(name: "customName", value: customName)
        try appendField(name: "customBundleId", value: customBundleID)
        try appendField(name: "customVersion", value: customVersion)

        if let p12Data, !p12Data.isEmpty {
            try appendFileData(name: "p12", filename: "certificate.p12", mimeType: "application/x-pkcs12", data: p12Data)
        } else {
            try appendField(name: "useServerCert", value: "true")
            try appendField(name: "certTeamId", value: teamID)
            if let appID { try appendField(name: "certAppId", value: appID) }
            try appendField(name: "certName", value: certName)
        }
        try appendFileData(name: "mobileprovision", filename: "profile.mobileprovision", mimeType: "application/x-apple-aspen-config", data: provData)

        if let remoteIPAURL {
            // Modo B: envia apenas a URL e a VPS baixa o .ipa direto na velocidade do servidor
            try appendField(name: "ipaUrl", value: remoteIPAURL.absoluteString)
        } else if let localIPAURL {
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

// MARK: - Progresso do upload

final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
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
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        let now = CFAbsoluteTimeGetCurrent()

        lock.lock()
        let shouldSend = now - lastSent > 0.15 || fraction >= 1
        if shouldSend { lastSent = now }
        var reached: [Int] = []
        while nextMilestone <= 100 && Int(fraction * 100) >= nextMilestone {
            reached.append(nextMilestone)
            nextMilestone += 25
        }
        lock.unlock()

        if shouldSend { onProgress(fraction) }
        reached.forEach(onMilestone)
    }
}
