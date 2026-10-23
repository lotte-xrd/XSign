import Foundation
import Security

/// Importa e valida certificados (par .p12 + .mobileprovision).
///
/// A leitura do .p12 usa `SecPKCS12Import` (Security framework, padrão da Apple).
/// A leitura do perfil é o plist assinado dentro do .mobileprovision. A checagem
/// de revogação (OCSP) é um ponto de integração — o endereço vem do próprio
/// certificado (Authority Information Access).
struct CertificateService {

    enum CertError: LocalizedError {
        case badPassword, mismatch, profileUnreadable
        var errorDescription: String? {
            switch self {
            case .badPassword:       return L.tr("cert.error.password")
            case .mismatch:          return L.tr("cert.error.mismatch")
            case .profileUnreadable: return L.tr("cert.error.profile")
            }
        }
    }

    struct ProfileInfo {
        var teamID: String
        var teamName: String?
        var appID: String?
        var type: String
        var expiresAt: Date?
        var devices: [String]
        var entitlementsCount: Int
    }

    /// Valida a senha abrindo o .p12. Retorna true se a senha abre o arquivo.
    func validateP12(data: Data, password: String) -> Bool {
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        return status == errSecSuccess
    }

    /// Lê o plist embutido no .mobileprovision (está entre marcadores PKCS#7).
    func readProfile(data: Data) throws -> ProfileInfo {
        guard let plist = Self.extractPlist(from: data),
              let dict = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil) as? [String: Any]
        else { throw CertError.profileUnreadable }

        let entitlements = dict["Entitlements"] as? [String: Any]
        let appID = entitlements?["application-identifier"] as? String
        let teamID = (dict["TeamIdentifier"] as? [String])?.first
            ?? appID?.split(separator: ".").first.map(String.init) ?? "—"
        let type = (dict["ProvisionsAllDevices"] as? Bool == true) ? "In-House"
            : (dict["ProvisionedDevices"] != nil ? "Apple Development" : "Distribution")

        return ProfileInfo(
            teamID: teamID,
            teamName: dict["TeamName"] as? String,
            appID: appID,
            type: type,
            expiresAt: dict["ExpirationDate"] as? Date,
            devices: dict["ProvisionedDevices"] as? [String] ?? [],
            entitlementsCount: entitlements?.count ?? 0
        )
    }

    /// Deriva o status a partir das datas. A revogação exige a consulta online abaixo.
    func status(expiresAt: Date?) -> CertStatus {
        guard let expiresAt else { return .unknown }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day ?? -1
        if days < 0 { return .expired }
        if days <= 7 { return .expiring }
        return .valid
    }

    /// Checagem de revogação por OCSP.
    /// Ponto de integração: montar a requisição OCSP (DER) para o endereço do
    /// campo Authority Information Access do certificado e interpretar "good" /
    /// "revoked" / "unknown". Sem rede, o status fica `.unknown` e o app assina
    /// avisando que não foi confirmado.
    func checkRevocation(for cert: Certificate) async -> CertStatus {
        // TODO: implementar OCSP no macOS. Placeholder preserva o status por data.
        return status(expiresAt: cert.expiresAt)
    }

    // MARK: - util

    /// Extrai o payload XML plist de dentro do container PKCS#7 do perfil.
    private static func extractPlist(from data: Data) -> Data? {
        guard let text = String(data: data, encoding: .ascii) ?? String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>")
        else { return nil }
        let slice = text[start.lowerBound..<end.upperBound]
        return slice.data(using: .isoLatin1)
    }
}
