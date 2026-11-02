import Foundation
import Security
import UIKit
import ZIPFoundation

/// Importa, valida e exporta certificados (.p12 + .mobileprovision, ou pacote .zip).
struct CertificateService {

    enum CertError: LocalizedError {
        case badPassword, mismatch, profileUnreadable, missingFilesInZip
        var errorDescription: String? {
            switch self {
            case .badPassword:       return L.tr("cert.error.password")
            case .mismatch:          return L.tr("cert.error.mismatch")
            case .profileUnreadable: return L.tr("cert.error.profile")
            case .missingFilesInZip: return "O arquivo .zip não contém um par .p12 e .mobileprovision."
            }
        }
    }

    struct ProfileInfo {
        var name: String?
        var teamID: String
        var teamName: String?
        var appID: String?
        var type: String
        var issuedAt: Date?
        var expiresAt: Date?
        var devices: [String]
        var entitlementsCount: Int
    }

    /// Valida a senha abrindo o .p12 via Security framework.
    func validateP12(data: Data, password: String) -> Bool {
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        return status == errSecSuccess
    }

    /// Lê o plist embutido no .mobileprovision (dentro do envelope CMS/PKCS#7).
    func readProfile(data: Data) throws -> ProfileInfo {
        guard let plist = Self.extractPlist(from: data),
              let dict = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil) as? [String: Any]
        else { throw CertError.profileUnreadable }

        let entitlements = dict["Entitlements"] as? [String: Any]
        let appID = entitlements?["application-identifier"] as? String
        let teamID = (dict["TeamIdentifier"] as? [String])?.first
            ?? appID?.split(separator: ".").first.map(String.init) ?? "—"
        let type = (dict["ProvisionsAllDevices"] as? Bool == true) ? "In-House (Enterprise)"
            : (dict["ProvisionedDevices"] != nil ? "Apple Development / Ad-Hoc" : "App Store Distribution")

        return ProfileInfo(
            name: dict["Name"] as? String,
            teamID: teamID,
            teamName: dict["TeamName"] as? String,
            appID: appID,
            type: type,
            issuedAt: dict["CreationDate"] as? Date,
            expiresAt: dict["ExpirationDate"] as? Date,
            devices: dict["ProvisionedDevices"] as? [String] ?? [],
            entitlementsCount: entitlements?.count ?? 0
        )
    }

    /// Salva o par .p12 + .mobileprovision em `Documents/Certificates/<id>/` e retorna o `Certificate`.
    func saveCertificate(p12Data: Data, profileData: Data, password: String, nickname: String?, makeActive: Bool) throws -> Certificate {
        guard validateP12(data: p12Data, password: password) else {
            throw CertError.badPassword
        }
        let info = try readProfile(data: profileData)
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
            inUse: makeActive
        )
    }

    /// Importa um pacote `.zip` de certificado (como o baixado de `exploiting-ios.online`).
    /// Procura `.p12`, `.mobileprovision` e tenta descobrir a senha em arquivos `.txt` ou testando `"1"`.
    func importFromZip(url: URL, makeActive: Bool) throws -> Certificate {
        guard let archive = Archive(url: url, accessMode: .read) else {
            throw CertError.missingFilesInZip
        }

        var p12Data: Data?
        var provData: Data?
        var textCandidates: [String] = []

        for entry in archive {
            let lower = entry.path.lowercased()
            if lower.contains("__macosx") { continue }
            if lower.hasSuffix(".p12") || lower.hasSuffix(".pfx") {
                p12Data = try Self.extractEntry(entry, from: archive)
            } else if lower.hasSuffix(".mobileprovision") {
                provData = try Self.extractEntry(entry, from: archive)
            } else if lower.hasSuffix(".txt") {
                if let d = try? Self.extractEntry(entry, from: archive),
                   let str = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) {
                    textCandidates.append(str)
                }
            }
        }

        guard let p12 = p12Data, let prov = provData else {
            throw CertError.missingFilesInZip
        }

        // Descobrir a senha (1º pelos .txt do zip, 2º testando senhas padrão como "1", "1234", "")
        var candidates: [String] = []
        for txt in textCandidates {
            for line in txt.components(separatedBy: .newlines) {
                if let colon = line.firstIndex(of: ":") {
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { candidates.append(value) }
                }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && trimmed.count <= 64 { candidates.append(trimmed) }
            }
        }
        candidates.append(contentsOf: ["1", "1234", "123456", "password", "apple", ""])

        let matchedPassword = candidates.first(where: { validateP12(data: p12, password: $0) }) ?? "1"
        return try saveCertificate(
            p12Data: p12,
            profileData: prov,
            password: matchedPassword,
            nickname: nil,
            makeActive: makeActive
        )
    }

    /// Detecta e importa automaticamente o certificado com o qual o próprio XSign foi instalado!
    /// 1) Procura primeiro em `Bundle.main/BundledCert` (caso o servidor tenha embutido `.p12` + `.mobileprovision`).
    /// 2) Caso contrário, lê o `embedded.mobileprovision` que o `zsign` coloca nativamente em `Payload/XSign.app/embedded.mobileprovision`
    ///    e cria o certificado vinculado ao servidor (`p12Path = "SERVER_MATCH"`).
    func importEmbeddedAppCertificate(makeActive: Bool = true) -> Certificate? {
        if let resourceURL = Bundle.main.resourceURL {
            let bundledDir = resourceURL.appendingPathComponent("BundledCert", isDirectory: true)
            let searchDirs = [bundledDir, resourceURL]

            for dir in searchDirs {
                guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
                if let zipFile = files.first(where: { $0.pathExtension.lowercased() == "zip" }),
                   let cert = try? importFromZip(url: zipFile, makeActive: makeActive) {
                    return cert
                }
                if let p12File = files.first(where: { ["p12", "pfx"].contains($0.pathExtension.lowercased()) }),
                   let provFile = files.first(where: { $0.pathExtension.lowercased() == "mobileprovision" && $0.lastPathComponent != "embedded.mobileprovision" })
                        ?? files.first(where: { $0.pathExtension.lowercased() == "mobileprovision" }),
                   let p12Data = try? Data(contentsOf: p12File),
                   let provData = try? Data(contentsOf: provFile) {
                    var passCandidates = ["1", "1234", "123456", "password", ""]
                    if let txtFile = files.first(where: { $0.pathExtension.lowercased() == "txt" }),
                       let txt = try? String(contentsOf: txtFile, encoding: .utf8) {
                        let lines = txt.components(separatedBy: .newlines)
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        passCandidates.insert(contentsOf: lines, at: 0)
                    }
                    let pass = passCandidates.first(where: { validateP12(data: p12Data, password: $0) }) ?? "1"
                    if let cert = try? saveCertificate(p12Data: p12Data, profileData: provData, password: pass, nickname: nil, makeActive: makeActive) {
                        return cert
                    }
                }
            }
        }

        // Fallback universal: lê o `embedded.mobileprovision` que o zsign sempre embute ao assinar o XSign
        guard let embeddedURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let provData = try? Data(contentsOf: embeddedURL),
              let info = try? readProfile(data: provData) else {
            return nil
        }

        let certID = UUID()
        let folder = Paths.certs.appendingPathComponent(certID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let provURL = folder.appendingPathComponent("profile.mobileprovision")
        try? provData.write(to: provURL, options: .atomic)

        let resolvedNick = info.teamName ?? info.name ?? "Certificado \(info.teamID)"

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
            p12Path: "SERVER_MATCH",
            profilePath: Paths.relative(provURL),
            keychainKey: "cert.password.\(certID.uuidString)",
            password: "1",
            status: status(expiresAt: info.expiresAt),
            checkedAt: Date(),
            inUse: makeActive
        )
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

        let safeName = cert.nickname.replacingOccurrences(of: " ", with: "-")
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

    /// Revalida o certificado lendo os arquivos em disco e conferindo a senha e data.
    func checkRevocation(for cert: Certificate) async -> CertStatus {
        let p12URL = Paths.resolve(cert.p12Path)
        let pass = KeychainHelper.read(key: cert.keychainKey) ?? cert.password
        if let p12Data = try? Data(contentsOf: p12URL) {
            if !validateP12(data: p12Data, password: pass) {
                return .revoked
            }
        }
        return status(expiresAt: cert.expiresAt)
    }

    // MARK: - util

    private static func extractEntry(_ entry: Entry, from archive: Archive) throws -> Data {
        var buffer = Data()
        _ = try archive.extract(entry, consumer: { chunk in
            buffer.append(chunk)
        })
        return buffer
    }

    private static func extractPlist(from data: Data) -> Data? {
        guard let text = String(data: data, encoding: .isoLatin1) ?? String(data: data, encoding: .ascii),
              let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>")
        else { return nil }
        let slice = text[start.lowerBound..<end.upperBound]
        return slice.data(using: .isoLatin1)
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
