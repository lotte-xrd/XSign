import SwiftUI

/// Estado central do app: dados carregados, serviços e preferências.
@MainActor
final class AppState: ObservableObject {
    @Published var selectedTab: AppTab = .store

    @Published var sources: [Source] = []
    @Published var sourceApps: [SourceApp] = []
    @Published var apps: [AppItem] = []
    @Published var certificates: [Certificate] = []
    @Published var settings = Settings.load()

    @Published var downloads = DownloadManager()

    let sourceService = SourceService()
    let certificateService = CertificateService()
    let installService: InstallService = LocalServerInstallService()
    /// Troque por `ZSignService()` quando o bridge do zsign estiver ligado.
    let signingService: SigningService = MockSigningService()

    var currentCertificate: Certificate? {
        certificates.first(where: { $0.inUse }) ?? certificates.first
    }

    // MARK: - Ciclo de vida

    func bootstrap() async {
        Paths.ensure()
        apps = await Store.shared.load([AppItem].self, from: "apps")
        certificates = await Store.shared.load([Certificate].self, from: "certificates")
        sources = await Store.shared.load([Source].self, from: "sources")
        if apps.isEmpty && certificates.isEmpty { loadSampleData() }
    }

    func persist() {
        Task {
            await Store.shared.save(apps, to: "apps")
            await Store.shared.save(certificates, to: "certificates")
            await Store.shared.save(sources, to: "sources")
        }
    }

    // MARK: - Deep links (xsign://)

    func handle(url: URL) {
        guard url.scheme == "xsign",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let target = comps.queryItems?.first(where: { $0.name == "url" })?.value,
              let inner = URL(string: target) else { return }
        switch url.host {
        case "add":
            selectedTab = .store
            pendingSourceURL = inner
        case "download":
            selectedTab = .downloads
            downloads.start(name: inner.lastPathComponent, url: inner)
        default:
            break
        }
    }

    /// URL de fonte vinda de um link, para a tela "Adicionar fontes" pré-preencher.
    @Published var pendingSourceURL: URL?

    // MARK: - Fontes

    func addSource(url: URL) async throws {
        let result = try await sourceService.fetch(url: url)
        var source = result.source
        source.order = sources.count
        sources.append(source)
        sourceApps.removeAll { $0.sourceID == source.id }
        sourceApps.append(contentsOf: result.apps)
        persist()
    }

    func removeSource(_ source: Source) {
        sources.removeAll { $0.id == source.id }
        sourceApps.removeAll { $0.sourceID == source.id }
        persist()
    }

    // MARK: - Apps

    func delete(_ app: AppItem) {
        apps.removeAll { $0.id == app.id }
        try? FileManager.default.removeItem(atPath: app.filePath)
        persist()
    }

    // MARK: - Dados de exemplo (primeiro arranque)

    private func loadSampleData() {
        let cal = Calendar.current
        certificates = [
            Certificate(nickname: "Pessoal", teamID: "7HQ2K4M9XA", teamName: "Marina Costa",
                        type: "Apple Development", appID: "7HQ2K4M9XA.*",
                        issuedAt: cal.date(byAdding: .day, value: -53, to: Date()),
                        expiresAt: cal.date(byAdding: .day, value: 312, to: Date()),
                        devices: ["00008120-0012", "00008110-0019", "00008030-0023"],
                        entitlementsCount: 8, p12Path: "", profilePath: "", keychainKey: "sample.personal",
                        status: .valid, checkedAt: Date(), inUse: true),
            Certificate(nickname: "Testes", teamID: "3LP8W2QZ1C", type: "Apple Development",
                        expiresAt: cal.date(byAdding: .day, value: 6, to: Date()),
                        p12Path: "", profilePath: "", keychainKey: "sample.test", status: .expiring),
            Certificate(nickname: "Empresa X", teamID: "9DX4N7T2PB", type: "iPhone Distribution",
                        expiresAt: cal.date(byAdding: .day, value: -4, to: Date()),
                        p12Path: "", profilePath: "", keychainKey: "sample.corp", status: .revoked),
        ]
        apps = [
            AppItem(name: "Lumen Player", bundleID: "com.lumen.player", version: "4.2.1",
                    filePath: Paths.unsigned.appendingPathComponent("lumen.ipa").path, size: 88_080_384),
            AppItem(name: "Pixel Emu", bundleID: "com.pixel.emu", version: "1.9.3",
                    filePath: Paths.unsigned.appendingPathComponent("pixel.ipa").path, size: 48_234_496),
            AppItem(name: "Notas Plus", bundleID: "com.notas.plus", version: "2.8.0",
                    filePath: Paths.unsigned.appendingPathComponent("notas.ipa").path, size: 23_068_672),
        ]
    }
}

// MARK: - Preferências

struct Settings: Codable {
    enum Appearance: String, Codable, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var colorScheme: ColorScheme? {
            switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
        }
        var label: String {
            switch self {
            case .system: return L.tr("appearance.system")
            case .light:  return L.tr("appearance.light")
            case .dark:   return L.tr("appearance.dark")
            }
        }
    }

    var appearance: Appearance = .system
    var installAfterSign = true
    var deleteOriginalAfterSign = false
    var autoImportDownloads = true
    var deleteAfterImport = false
    var installMethod = "localServer"
    var appIcon = "graphite"

    static func load() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: "settings"),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "settings") }
    }
}
