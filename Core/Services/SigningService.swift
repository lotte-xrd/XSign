import Foundation

/// Motor de assinatura. As telas falam só com este protocolo e consomem o
/// progresso como `AsyncStream`.
protocol SigningService {
    func sign(app: AppItem, certificate: Certificate, options: SignOptions) -> AsyncStream<SignProgress>
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
            Task {
                var steps: [SignStep] = [
                    SignStep(kind: .extract, state: .waiting),
                    SignStep(kind: .modify, state: .waiting),
                    SignStep(kind: .sign, state: .waiting),
                    SignStep(kind: .pack, state: .waiting)
                ]

                func emit(_ fraction: Double, finished: Bool = false, error: String? = nil, response: RemoteSignResponse? = nil) {
                    continuation.yield(SignProgress(
                        steps: steps,
                        fraction: fraction,
                        finished: finished,
                        outputPath: response?.downloadUrl ?? app.filePath,
                        installURL: response?.installUrl,
                        downloadURL: response?.downloadUrl,
                        shareURL: response?.shareUrl,
                        finalName: response?.appName ?? options.name ?? app.name,
                        finalBundleID: response?.bundleIdentifier ?? options.bundleID ?? app.bundleID,
                        finalVersion: response?.bundleVersion ?? options.version ?? app.version,
                        fileSize: response?.fileSize ?? app.size,
                        error: error
                    ))
                }

                let t0 = Date()
                steps[0].state = .running(detail: certificate.nickname)
                emit(0.1)

                // 1. Ler arquivos reais do certificado (.p12 + .mobileprovision)
                let p12URL = Paths.resolve(certificate.p12Path)
                let provURL = Paths.resolve(certificate.profilePath)
                guard let p12Data = try? Data(contentsOf: p12URL), !p12Data.isEmpty else {
                    let msg = "Arquivo .p12 do certificado não encontrado. Reimporte o certificado em Ajustes."
                    steps[0].state = .failed(msg)
                    emit(0.1, error: msg)
                    continuation.finish()
                    return
                }
                guard let provData = try? Data(contentsOf: provURL), !provData.isEmpty else {
                    let msg = "Arquivo .mobileprovision não encontrado. Reimporte o certificado em Ajustes."
                    steps[0].state = .failed(msg)
                    emit(0.1, error: msg)
                    continuation.finish()
                    return
                }

                let localIPAURL = app.filePath.isEmpty ? nil : Paths.resolve(app.filePath)
                let hasLocalIPA = localIPAURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                let remoteIPAURL = app.downloadURL

                guard remoteIPAURL != nil || hasLocalIPA else {
                    let msg = "Arquivo .ipa ou URL da fonte não encontrado para este aplicativo."
                    steps[0].state = .failed(msg)
                    emit(0.1, error: msg)
                    continuation.finish()
                    return
                }

                steps[0].state = .done(seconds: Date().timeIntervalSince(t0))

                // 2. Preparar opções (Nome, Bundle ID, Versão)
                let t1 = Date()
                let customName = (options.name ?? app.name).trimmingCharacters(in: .whitespacesAndNewlines)
                let customBundle = (options.bundleID ?? app.bundleID).trimmingCharacters(in: .whitespacesAndNewlines)
                let customVersion = (options.version ?? app.version).trimmingCharacters(in: .whitespacesAndNewlines)
                steps[1].state = .running(detail: customBundle)
                emit(0.28)

                let boundary = "XSignBoundary-\(UUID().uuidString)"
                let tempBodyURL = FileManager.default.temporaryDirectory.appendingPathComponent("xsign-req-\(UUID().uuidString).body")
                defer { try? FileManager.default.removeItem(at: tempBodyURL) }

                let password = KeychainHelper.read(key: certificate.keychainKey) ?? certificate.password

                do {
                    try Self.writeMultipartBody(
                        to: tempBodyURL,
                        boundary: boundary,
                        p12Data: p12Data,
                        provData: provData,
                        password: password,
                        customName: customName,
                        customBundleID: customBundle,
                        customVersion: customVersion,
                        remoteIPAURL: remoteIPAURL,
                        localIPAURL: hasLocalIPA ? localIPAURL : nil
                    )
                } catch {
                    let msg = "Erro ao preparar envio: \(error.localizedDescription)"
                    steps[1].state = .failed(msg)
                    emit(0.28, error: msg)
                    continuation.finish()
                    return
                }

                steps[1].state = .done(seconds: Date().timeIntervalSince(t1))

                // 3. Chamar o servidor zsign (Modo B por URL ou Modo A por upload)
                let t2 = Date()
                let modeLabel = remoteIPAURL != nil ? "Modo B (URL direta)" : "Upload IPA"
                steps[2].state = .running(detail: modeLabel)
                emit(0.55)

                let cleanBase = endpointBase.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
                guard let url = URL(string: "\(cleanBase)/api/xsign/sign") else {
                    let msg = "URL do servidor inválida."
                    steps[2].state = .failed(msg)
                    emit(0.55, error: msg)
                    continuation.finish()
                    return
                }

                var request = URLRequest(url: url, timeoutInterval: 600)
                request.httpMethod = "POST"
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                request.setValue(KeychainHelper.deviceID, forHTTPHeaderField: "X-XSign-Device")

                do {
                    let (respData, urlResponse) = try await URLSession.shared.upload(for: request, fromFile: tempBodyURL)
                    let httpStatus = (urlResponse as? HTTPURLResponse)?.statusCode ?? 500

                    guard (200...299).contains(httpStatus) else {
                        let serverMsg = (try? JSONDecoder().decode(RemoteErrorResponse.self, from: respData))?.error
                            ?? String(data: respData, encoding: .utf8)
                            ?? "Erro HTTP \(httpStatus)"
                        steps[2].state = .failed(serverMsg)
                        emit(0.55, error: serverMsg)
                        continuation.finish()
                        return
                    }

                    let decoded = try JSONDecoder().decode(RemoteSignResponse.self, from: respData)
                    steps[2].state = .done(seconds: Date().timeIntervalSince(t2))

                    // 4. Finalizar link OTA
                    let t3 = Date()
                    steps[3].state = .running(detail: "OTA pronto")
                    emit(0.9)
                    steps[3].state = .done(seconds: max(0.1, Date().timeIntervalSince(t3)))

                    emit(1.0, finished: true, response: decoded)
                    continuation.finish()
                } catch {
                    let msg = "Falha de conexão com o servidor de assinatura: \(error.localizedDescription)"
                    steps[2].state = .failed(msg)
                    emit(0.55, error: msg)
                    continuation.finish()
                }
            }
        }
    }

    private static func writeMultipartBody(
        to fileURL: URL,
        boundary: String,
        p12Data: Data,
        provData: Data,
        password: String,
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

        try appendFileData(name: "p12", filename: "certificate.p12", mimeType: "application/x-pkcs12", data: p12Data)
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
