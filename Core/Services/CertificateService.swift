import Foundation
import Security
import UIKit
import ZIPFoundation

/// Importa, valida e exporta certificados (.p12 + .mobileprovision, ou pacote .zip).
struct CertificateService {

    /// `p12Path` de um certificado sem .p12 no aparelho: o servidor acha o .p12 pelo perfil.
    static let serverMatchPath = "SERVER_MATCH"

    enum CertError: LocalizedError {
        case badPassword, mismatch, profileUnreadable, missingFilesInZip
        case passwordNeeded, notP12, missingP12, missingProfile

        var errorDescription: String? {
            switch self {
            case .badPassword:       return L.tr("cert.error.password")
            case .mismatch:          return L.tr("cert.error.mismatch")
            case .profileUnreadable: return L.tr("cert.error.profile")
            case .missingFilesInZip: return L.tr("cert.error.missingFiles")
            case .passwordNeeded:    return L.tr("cert.error.passwordNeeded")
            case .notP12:            return L.tr("cert.error.notP12")
            case .missingP12:        return L.tr("cert.error.missingP12")
            case .missingProfile:    return L.tr("cert.error.missingProfile")
            }
        }

        /// Erros que a tela de importação resolve pedindo algo ao usuário
        /// (a senha ou o arquivo que falta).
        var needsUserInput: Bool {
            switch self {
            case .passwordNeeded, .missingP12, .missingProfile, .badPassword: return true
            default: return false
            }
        }
    }

    typealias ProfileInfo = ProvisioningProfileInfo
    typealias CertificateCandidate = CertificateScanResult

    /// Confere a senha do .p12. Funciona também com o formato novo do OpenSSL 3
    /// (AES-256), que o `SecPKCS12Import` do iOS 17 e anteriores não abre.
    func validateP12(data: Data, password: String) -> Bool {
        CertificateScanner.validate(data, password: password)
    }

    /// Lê o plist embutido no .mobileprovision (dentro do envelope CMS/PKCS#7).
    func readProfile(data: Data) throws -> ProfileInfo {
        guard let info = ProvisioningProfileInfo.read(data) else { throw CertError.profileUnreadable }
        return info
    }

    /// Entitlements do perfil de provisionamento de um certificado já importado.
    func entitlements(for cert: Certificate) -> [String: Any] {
        guard let data = try? Data(contentsOf: Paths.resolve(cert.profilePath)) else { return [:] }
        return entitlements(fromProfile: data)
    }

    func entitlements(fromProfile data: Data) -> [String: Any] {
        ProvisioningProfileInfo.plist(from: data)?["Entitlements"] as? [String: Any] ?? [:]
    }

    /// UUID do perfil de um certificado (do modelo ou lido do arquivo).
    func profileUUID(of cert: Certificate) -> String? {
        if let uuid = cert.profileUUID { return uuid }
        guard let data = try? Data(contentsOf: Paths.resolve(cert.profilePath)) else { return nil }
        return ProvisioningProfileInfo.read(data)?.uuid
    }

    /// Salva o par .p12 + .mobileprovision em `Documents/Certificates/<id>/` e retorna o `Certificate`.
    /// `verify: false` para arquivos que vêm do nosso servidor (compra e certificado
    /// embutido no XSign): a senha já foi usada lá e não pode travar a importação.
    func saveCertificate(p12Data: Data, profileData: Data, password: String, nickname: String?,
                         makeActive: Bool, verify: Bool = true) throws -> Certificate {
        let info = try readProfile(data: profileData)
        if verify {
            guard validateP12(data: p12Data, password: password) else {
                throw PKCS12File(data: p12Data) == nil ? CertError.notP12 : CertError.badPassword
            }
            if CertificateScanner.p12(p12Data, password: password, matchesProfile: info) == false {
                throw CertError.mismatch
            }
        }
        let certID = UUID()
        let folder = Paths.certs.appendingPathComponent(certID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let p12URL = folder.appendingPathComponent("certificate.p12")
        let provURL = folder.appendingPathComponent("profile.mobileprovision")
        try p12Data.write(to: p12URL, options: .atomic)
        try profileData.write(to: provURL, options: .atomic)

        let keychainKey = "cert.password.\(certID.uuidString)"
        KeychainHelper.save(key: keychainKey, value: password)

        let resolvedNick = (nickname?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? info.teamName
            ?? info.name
            ?? "Certificado \(info.teamID)"

        return Certificate(
            id: certID,
            nickname: resolvedNick,
            teamID: info.teamID,
            teamName: info.teamName,
            type: info.type,
            appID: info.appID,
            issuedAt: info.issuedAt,
            expiresAt: info.expiresAt,
            devices: info.devices,
            entitlementsCount: info.entitlementsCount,
            p12Path: Paths.relative(p12URL),
            profilePath: Paths.relative(provURL),
            keychainKey: keychainKey,
            password: password,
            status: status(expiresAt: info.expiresAt),
            checkedAt: Date(),
            inUse: makeActive,
            profileUUID: info.uuid
        )
    }

    /// Importa o que foi encontrado nos arquivos. `password` é a que o usuário
    /// digitou; sem ela vale a senha descoberta sozinha.
    func importCandidate(_ candidate: CertificateCandidate, password: String? = nil, nickname: String? = nil,
                         makeActive: Bool) throws -> Certificate {
        guard candidate.p12Data != nil || candidate.profileData != nil else { throw CertError.missingFilesInZip }
        guard let p12 = candidate.p12Data else { throw CertError.missingP12 }
        guard let profile = candidate.profileData else { throw CertError.missingProfile }
        if candidate.p12Unreadable && password == nil { throw CertError.notP12 }
        guard let pass = password ?? candidate.foundPassword else { throw CertError.passwordNeeded }
        return try saveCertificate(p12Data: p12, profileData: profile, password: pass, nickname: nickname, makeActive: makeActive)
    }

    /// Importa um pacote `.zip` de certificado (como o baixado de `exploiting-ios.online`).
    func importFromZip(url: URL, makeActive: Bool) throws -> Certificate {
        try importCandidate(collectCertificateFiles([url]), makeActive: makeActive)
    }

    // MARK: - Ler arquivos soltos, pastas e .zip

    /// Lê arquivos soltos, pastas e .zip (inclusive .zip dentro de .zip), separa
    /// .p12 / .mobileprovision, escolhe o par que combina e descobre a senha em
    /// .txt / .json / .plist que vierem junto (ou testando as senhas comuns).
    func collectCertificateFiles(_ urls: [URL]) -> CertificateCandidate {
        CertificateScanner.scan(Self.entries(from: urls))
    }

    static func entries(from urls: [URL]) -> [CertificateFileEntry] {
        var entries: [CertificateFileEntry] = []
        let maxSize: UInt64 = 20 * 1024 * 1024

        func addZip(_ archive: Archive, prefix: String, depth: Int) {
            for entry in archive where entry.type == .file && entry.uncompressedSize < maxSize {
                guard entries.count < 400, let data = try? extractEntry(entry, from: archive) else { continue }
                let name = prefix + entry.path
                if name.lowercased().hasSuffix(".zip"), depth < 2,
                   let inner = Archive(data: data, accessMode: .read) {
                    addZip(inner, prefix: name + "/", depth: depth + 1)
                } else {
                    entries.append(CertificateFileEntry(name: name, data: data))
                }
            }
        }

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
                while let file = walker?.nextObject() as? URL, entries.count < 400 {
                    let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard values?.isRegularFile == true, UInt64(values?.fileSize ?? 0) < maxSize,
                          let data = try? Data(contentsOf: file) else { continue }
                    let name = String(file.path.dropFirst(url.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    if file.pathExtension.lowercased() == "zip", let archive = Archive(data: data, accessMode: .read) {
                        addZip(archive, prefix: name + "/", depth: 1)
                    } else {
                        entries.append(CertificateFileEntry(name: name, data: data))
                    }
                }
            } else if let data = try? Data(contentsOf: url), UInt64(data.count) < 200 * 1024 * 1024 {
                // .zip pelo conteúdo (PK), mesmo com outra extensão.
                if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) || url.pathExtension.lowercased() == "zip",
                   let archive = Archive(data: data, accessMode: .read) {
                    addZip(archive, prefix: "", depth: 0)
                } else if UInt64(data.count) < maxSize {
                    entries.append(CertificateFileEntry(name: url.lastPathComponent, data: data))
                }
            }
        }
        return entries
    }

    /// Possíveis senhas num arquivo de texto/JSON/plist.
    static func passwordHints(from data: Data) -> (strong: [String], weak: [String]) {
        CertificateScanner.passwordHints(from: data)
    }

    // MARK: - Certificado com que o próprio XSign foi instalado

    /// O certificado que assinou este XSign: o perfil `embedded.mobileprovision`
    /// e, quando o servidor embutiu, o .p12 em `BundledCert/`.
    struct InstalledCertificate {
        var profileData: Data
        var profile: ProfileInfo
        var p12Data: Data?
        var password: String?

        /// Identifica o perfil mesmo sem UUID.
        var key: String { profile.uuid ?? "\(profile.teamID)-\(profileData.count)" }
    }

    /// Só o perfil; o .p12 embutido é lido depois, com `loadBundledP12`, quando precisa.
    func installedCertificate() -> InstalledCertificate? {
        guard let embeddedURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let profileData = try? Data(contentsOf: embeddedURL),
              let profile = ProvisioningProfileInfo.read(profileData) else { return nil }
        return InstalledCertificate(profileData: profileData, profile: profile)
    }

    /// Lê o .p12 que o servidor embutiu em `BundledCert/` (com `password.txt`).
    func loadBundledP12(into installed: inout InstalledCertificate) {
        guard installed.p12Data == nil, let resources = Bundle.main.resourceURL else { return }
        let bundled = resources.appendingPathComponent("BundledCert", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundled.path) else { return }
        let found = collectCertificateFiles([bundled])
        guard let p12 = found.p12Data else { return }
        installed.p12Data = p12
        // Se nem a senha do password.txt nem as comuns conferirem aqui, usa a do
        // arquivo assim mesmo: ela foi a usada pelo servidor, que é quem assina.
        installed.password = found.foundPassword
            ?? found.passwordHints.first(where: { !$0.isEmpty })
            ?? "1"
    }

    /// Cria o `Certificate` do XSign instalado: com o .p12 embutido quando há,
    /// senão vinculado ao servidor (o servidor acha o .p12 pelo perfil).
    func saveInstalledCertificate(_ installed: InstalledCertificate, makeActive: Bool) throws -> Certificate {
        if let p12 = installed.p12Data {
            return try saveCertificate(p12Data: p12, profileData: installed.profileData,
                                       password: installed.password ?? "1", nickname: nil,
                                       makeActive: makeActive, verify: false)
        }

        let info = installed.profile
        let certID = UUID()
        let folder = Paths.certs.appendingPathComponent(certID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let provURL = folder.appendingPathComponent("profile.mobileprovision")
        try installed.profileData.write(to: provURL, options: .atomic)

        return Certificate(
            id: certID,
            nickname: info.teamName ?? info.name ?? "Certificado \(info.teamID)",
            teamID: info.teamID,
            teamName: info.teamName,
            type: info.type,
            appID: info.appID,
            issuedAt: info.issuedAt,
            expiresAt: info.expiresAt,
            devices: info.devices,
            entitlementsCount: info.entitlementsCount,
            p12Path: Self.serverMatchPath,
            profilePath: Paths.relative(provURL),
            keychainKey: "cert.password.\(certID.uuidString)",
            password: "1",
            status: status(expiresAt: info.expiresAt),
            checkedAt: Date(),
            inUse: makeActive,
            profileUUID: info.uuid
        )
    }

    /// Apaga os arquivos e a senha de um certificado.
    func removeFiles(of cert: Certificate) {
        KeychainHelper.delete(key: cert.keychainKey)
        let folder = Paths.resolve(cert.profilePath).deletingLastPathComponent()
        if folder.path.contains("/Certificates/"), folder.lastPathComponent != "Certificates" {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Exporta um certificado em `.zip` para compartilhamento.
    func exportCertificateZip(_ cert: Certificate) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("cert-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let p12Source = Paths.resolve(cert.p12Path)
        let provSource = Paths.resolve(cert.profilePath)
        let pass = KeychainHelper.read(key: cert.keychainKey) ?? cert.password

        if FileManager.default.fileExists(atPath: p12Source.path) {
            try FileManager.default.copyItem(at: p12Source, to: tempDir.appendingPathComponent("certificate.p12"))
        }
        if FileManager.default.fileExists(atPath: provSource.path) {
            try FileManager.default.copyItem(at: provSource, to: tempDir.appendingPathComponent("profile.mobileprovision"))
        }
        let passText = "Senha do certificado (P12) / Password: \(pass)\r\nTeam ID: \(cert.teamID)\r\n"
        try passText.data(using: .utf8)?.write(to: tempDir.appendingPathComponent("SENHA-PASSWORD.txt"))

        let safeName = cert.nickname.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-")
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent("XSign-\(safeName).zip")
        try? FileManager.default.removeItem(at: zipURL)
        try FileManager.default.zipItem(at: tempDir, to: zipURL, shouldKeepParent: false)
        try? FileManager.default.removeItem(at: tempDir)
        return zipURL
    }

    /// Deriva o status a partir das datas e valida existência dos arquivos.
    func status(expiresAt: Date?) -> CertStatus {
        guard let expiresAt else { return .unknown }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day ?? -1
        if days < 0 { return .expired }
        if days <= 7 { return .expiring }
        return .valid
    }

    // MARK: - Revogação pela Apple (OCSP)

    struct AppleRevocation {
        var status: String       // "good", "revoked" ou "unknown"
        var revokedAt: Date?
    }

    /// Certificado público (DER) de dentro do .p12. A chave privada não sai daqui.
    /// Sem .p12 no aparelho (certificado vinculado ao servidor), usa o do perfil
    /// quando ele tem um só.
    func publicCertificateDER(for cert: Certificate) -> Data? {
        if cert.p12Path != Self.serverMatchPath,
           let p12Data = try? Data(contentsOf: Paths.resolve(cert.p12Path)), !p12Data.isEmpty {
            let password = KeychainHelper.read(key: cert.keychainKey) ?? cert.password
            if let der = CertificateScanner.certificates(of: p12Data, password: password).first { return der }
        }
        guard let profileData = try? Data(contentsOf: Paths.resolve(cert.profilePath)),
              let profile = ProvisioningProfileInfo.read(profileData),
              profile.certificates.count == 1 else { return nil }
        return profile.certificates.first
    }

    /// Pergunta ao servidor (que consulta o OCSP da Apple) se o certificado foi
    /// revogado. Envia só o certificado público. `nil` quando não deu para checar.
    func appleRevocationStatus(for cert: Certificate, serverBase: String) async -> AppleRevocation? {
        guard let der = publicCertificateDER(for: cert),
              let url = URL(string: "\(serverBase)/api/xsign/cert-status") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(KeychainHelper.deviceID, forHTTPHeaderField: "X-XSign-Device")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["certificate": der.base64EncodedString()])

        struct Response: Decodable {
            let status: String
            let revokedAt: String?
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data),
              ["good", "revoked", "unknown"].contains(decoded.status) else { return nil }
        return AppleRevocation(
            status: decoded.status,
            revokedAt: decoded.revokedAt.flatMap(RemoteSigningService.parseServerDate)
        )
    }

    /// Revalida o status pelas datas. A revogação de verdade vem da Apple (OCSP,
    /// `appleRevocationStatus`). Antes, um .p12 que o iOS não conseguia abrir
    /// (formato novo do OpenSSL 3) aparecia aqui como "revogado".
    func checkRevocation(for cert: Certificate) async -> CertStatus {
        status(expiresAt: cert.expiresAt)
    }

    // MARK: - util

    private static func extractEntry(_ entry: Entry, from archive: Archive) throws -> Data {
        var buffer = Data()
        _ = try archive.extract(entry, consumer: { chunk in
            buffer.append(chunk)
        })
        return buffer
    }
}

// MARK: - Leitor Real de Pacotes .ipa (ZIPFoundation)

enum IPAPackageReader {
    struct Metadata {
        var name: String
        var bundleID: String
        var version: String
        var iconData: Data?
    }

    /// Abre o `.ipa` com `ZIPFoundation`, lê `Payload/*.app/Info.plist` e extrai o ícone PNG real.
    static func read(ipaURL: URL) throws -> Metadata {
        guard let archive = Archive(url: ipaURL, accessMode: .read) else {
            throw NSError(domain: "XSign.IPA", code: -1, userInfo: [NSLocalizedDescriptionKey: "Arquivo .ipa inválido."])
        }

        var infoEntry: Entry?
        var appFolderPrefix = ""

        for entry in archive {
            let parts = entry.path.split(separator: "/")
            if parts.count == 3,
               parts[0].lowercased() == "payload",
               parts[1].lowercased().hasSuffix(".app"),
               parts[2].lowercased() == "info.plist" {
                infoEntry = entry
                appFolderPrefix = "\(parts[0])/\(parts[1])/"
                break
            }
        }

        guard let targetInfo = infoEntry else {
            throw NSError(domain: "XSign.IPA", code: -2, userInfo: [NSLocalizedDescriptionKey: "O .ipa não contém Payload/*.app/Info.plist."])
        }

        var plistData = Data()
        _ = try archive.extract(targetInfo, consumer: { plistData.append($0) })

        guard let dict = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            throw NSError(domain: "XSign.IPA", code: -3, userInfo: [NSLocalizedDescriptionKey: "Não foi possível ler o Info.plist do .ipa."])
        }

        let fallbackName = ipaURL.deletingPathExtension().lastPathComponent
        let name = (dict["CFBundleDisplayName"] as? String)
            ?? (dict["CFBundleName"] as? String)
            ?? fallbackName
        let bundleID = (dict["CFBundleIdentifier"] as? String) ?? "com.unknown.app"
        let version = (dict["CFBundleShortVersionString"] as? String)
            ?? (dict["CFBundleVersion"] as? String)
            ?? "1.0"

        // Tentar localizar o ícone dentro de Payload/<App>.app/
        var iconNames: [String] = []
        if let icons = dict["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] {
            if let files = primary["CFBundleIconFiles"] as? [String] {
                iconNames.append(contentsOf: files)
            }
            if let nameStr = primary["CFBundleIconName"] as? String {
                iconNames.append(nameStr)
            }
        }
        if let legacyFiles = dict["CFBundleIconFiles"] as? [String] {
            iconNames.append(contentsOf: legacyFiles)
        }
        iconNames.append(contentsOf: ["AppIcon60x60", "AppIcon76x76", "AppIcon", "Icon-60", "Icon"])

        var bestIconEntry: Entry?
        var bestSize: UInt64 = 0

        for entry in archive {
            guard entry.path.hasPrefix(appFolderPrefix) else { continue }
            let rel = String(entry.path.dropFirst(appFolderPrefix.count))
            guard !rel.contains("/"), rel.lowercased().hasSuffix(".png") else { continue }

            let matchesHint = iconNames.contains { hint in
                rel.lowercased().hasPrefix(hint.lowercased())
            }
            if matchesHint && entry.uncompressedSize >= bestSize {
                bestSize = entry.uncompressedSize
                bestIconEntry = entry
            } else if bestIconEntry == nil && rel.lowercased().contains("icon") {
                bestIconEntry = entry
            }
        }

        var validIconData: Data?
        if let iconEntry = bestIconEntry {
            var rawIcon = Data()
            _ = try? archive.extract(iconEntry, consumer: { rawIcon.append($0) })
            if let uiImage = UIImage(data: rawIcon), let normalPNG = uiImage.pngData() {
                validIconData = normalPNG
            }
        }

        return Metadata(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            bundleID: bundleID.trimmingCharacters(in: .whitespacesAndNewlines),
            version: version.trimmingCharacters(in: .whitespacesAndNewlines),
            iconData: validIconData
        )
    }
}
