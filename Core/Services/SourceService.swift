import Foundation

/// Lê fontes (repositórios) de vários formatos e devolve o modelo interno.
/// Cada formato tem um adaptador; o resto do app só conhece `SourceApp`.
struct SourceService {

    enum SourceError: LocalizedError {
        case network, decode
        var errorDescription: String? {
            switch self {
            case .network: return L.tr("source.error.network")
            case .decode:  return L.tr("source.error.decode")
            }
        }
    }

    /// Baixa e interpreta uma fonte a partir da URL.
    func fetch(url: URL) async throws -> (source: Source, apps: [SourceApp]) {
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(from: url)
        } catch {
            throw SourceError.network
        }
        guard let adapter = Self.detect(data) else { throw SourceError.decode }
        return try adapter.parse(data, url: url)
    }

    /// Detecta o formato pelo conteúdo do JSON.
    static func detect(_ data: Data) -> SourceAdapter? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if obj["apps"] != nil { return AltStoreAdapter() }
        if obj["META"] != nil { return ScarletAdapter() }
        return LegacyAdapter()
    }
}

protocol SourceAdapter {
    var format: SourceFormat { get }
    func parse(_ data: Data, url: URL) throws -> (Source, [SourceApp])
}

// MARK: - AltStore (v1 e v2)

struct AltStoreAdapter: SourceAdapter {
    let format: SourceFormat = .altstore

    struct Repo: Decodable {
        var name: String?
        var identifier: String?
        var iconURL: URL?
        var apps: [App]
    }
    struct App: Decodable {
        var name: String
        var bundleIdentifier: String
        var developerName: String?
        var iconURL: URL?
        var version: String?
        var versionDate: Date?
        var downloadURL: URL?
        var size: Int64?
        var localizedDescription: String?
        var versions: [Version]?
    }
    struct Version: Decodable {
        var version: String
        var date: Date?
        var size: Int64?
        var downloadURL: URL
        var localizedDescription: String?
    }

    func parse(_ data: Data, url: URL) throws -> (Source, [SourceApp]) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let repo = try decoder.decode(Repo.self, from: data)
        let sourceID = UUID()
        let source = Source(id: sourceID, url: url, name: repo.name ?? url.host ?? "Source",
                            iconURL: repo.iconURL, format: format,
                            lastFetched: Date(), order: 0, appCount: repo.apps.count)
        let apps: [SourceApp] = repo.apps.map { a in
            let versions: [AppVersion]
            if let vs = a.versions, !vs.isEmpty {
                versions = vs.map { AppVersion(version: $0.version, downloadURL: $0.downloadURL,
                                               size: $0.size, date: $0.date, notes: $0.localizedDescription) }
            } else if let dl = a.downloadURL {
                versions = [AppVersion(version: a.version ?? "1.0", downloadURL: dl, size: a.size,
                                       date: a.versionDate, notes: a.localizedDescription)]
            } else {
                versions = []
            }
            return SourceApp(name: a.name, bundleID: a.bundleIdentifier, developer: a.developerName,
                             iconURL: a.iconURL, sourceID: sourceID, sourceName: source.name,
                             versions: versions)
        }
        return (source, apps)
    }
}

// MARK: - Scarlet e legado (esqueletos a completar com fontes reais)

struct ScarletAdapter: SourceAdapter {
    let format: SourceFormat = .scarlet
    func parse(_ data: Data, url: URL) throws -> (Source, [SourceApp]) {
        // TODO: mapear a chave META e as listas por categoria do formato Scarlet.
        // Testar com uma fonte real antes de confiar neste caminho.
        throw SourceService.SourceError.decode
    }
}

struct LegacyAdapter: SourceAdapter {
    let format: SourceFormat = .legacy
    func parse(_ data: Data, url: URL) throws -> (Source, [SourceApp]) {
        // TODO: JSONs antigos com downloadURL solto, sem a estrutura do AltStore.
        throw SourceService.SourceError.decode
    }
}
