import SwiftUI
import UIKit
import Combine

/// Estado central do app: dados reais persistidos, serviços e preferências.
@MainActor
final class AppState: ObservableObject {
    @Published var selectedTab: AppTab = .apps

    static var builtInXSignApp: SourceApp {
        SourceApp(
            name: "XSign",
            bundleID: "com.xsign.app",
            developer: "Lotte",
            subtitle: L.tr("store.xsign.subtitle"),
            category: "Utilities",
            iconURL: nil,
            sourceID: nil,
            sourceName: "XSign Official",
            versions: [
                AppVersion(
                    version: "1.0.0",
                    downloadURL: URL(string: "https://github.com/lotte-xrd/XSign/releases/download/latest/XSign-unsigned.ipa")!,
                    size: nil,
                    date: Date(),
                    notes: L.tr("store.xsign.notes")
                )
            ]
        )
    }

    @Published var sources: [Source] = []
    @Published var sourceApps: [SourceApp] = [AppState.builtInXSignApp]
    @Published var apps: [AppItem] = []
    @Published var certificates: [Certificate] = []
    @Published var settings = Settings.load()

    @Published var downloads = DownloadManager()
    @Published var lastImportMessage: String?

    // Estado da Splash de abertura (1) e do HUD de carregamento (2)
    @Published var isBootstrapping: Bool = true
    @Published var bootProgress: Double = 0.22
    @Published var bootStatusText: String = L.tr("loading.boot.certs")
    @Published var activeHUDTitle: String? = nil

    let sourceService = SourceService()
    let certificateService = CertificateService()
    let installService: InstallService = OTAInstallService()
    let signingService: SigningService = RemoteSigningService()

    private var downloadsCancellable: AnyCancellable?
    private var languageCancellable: AnyCancellable?
    private var heartbeatTask: Task<Void, Never>?

    var currentCertificate: Certificate? {
        certificates.first(where: { $0.inUse }) ?? certificates.first
    }

    init() {
        downloadsCancellable = downloads.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        languageCancellable = LocalizationManager.shared.$code.sink { [weak self] _ in
            Task { @MainActor in
                self?.ensureBuiltInXSign()
            }
        }
        downloads.onDownloadFinished = { [weak self] task, fileURL in
            guard let self else { return }
            Task { @MainActor in
                if self.settings.autoImportDownloads {
                    _ = try? self.importIPA(
                        from: fileURL,
                        origin: task.sourceName ?? task.url.host,
                        downloadURL: task.url,
                        fallbackIconURL: task.iconURL,
                        deleteSourceFile: self.settings.deleteAfterImport
                    )
                }
            }
        }
    }

    // MARK: - Ciclo de vida

    func bootstrap() async {
        guard isBootstrapping else { return }
        Paths.ensure()
        _ = KeychainHelper.deviceID // garante o UUID fixo do aparelho no Keychain

        bootProgress = 0.28
        bootStatusText = L.tr("loading.boot.certs")

        apps = await Store.shared.load([AppItem].self, from: "apps")
        certificates = await Store.shared.load([Certificate].self, from: "certificates")
        sources = await Store.shared.load([Source].self, from: "sources")
        sourceApps = await Store.shared.load([SourceApp].self, from: "sourceAppsCache")
        ensureBuiltInXSign()

        // Atualiza status de validade dos certificados carregados
        for i in certificates.indices {
            certificates[i].status = certificateService.status(expiresAt: certificates[i].expiresAt)
        }

        try? await Task.sleep(nanoseconds: 350_000_000)
        bootProgress = 0.72
        bootStatusText = L.tr("loading.boot.sources")

        try? await Task.sleep(nanoseconds: 350_000_000)
        bootProgress = 1.0
        bootStatusText = L.tr("loading.boot.ready")

        try? await Task.sleep(nanoseconds: 220_000_000)
        withAnimation(.easeInOut(duration: 0.35)) {
            isBootstrapping = false
        }

        startHeartbeatLoop()

        // Atualiza todas as fontes cadastradas em segundo plano
        if !sources.isEmpty {
            await refreshAllSources()
        }
    }

    // MARK: - Heartbeat de instalações ativas (/count no servidor)

    func startHeartbeatLoop() {
        heartbeatTask?.cancel()
        heartbeatTask = Task {
            while !Task.isCancelled {
                await sendHeartbeat(state: "active")
                try? await Task.sleep(nanoseconds: 60_000_000_000) // a cada 60s
            }
        }
    }

    func sendHeartbeat(state: String) async {
        let base = settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard let url = URL(string: "\(base)/api/xsign/heartbeat") else { return }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("XSign/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        req.setValue(KeychainHelper.deviceID, forHTTPHeaderField: "X-XSign-Device")

        let payload: [String: String] = [
            "deviceId": KeychainHelper.deviceID,
            "model": UIDevice.current.model,
            "iosVersion": UIDevice.current.systemVersion,
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
            "locale": Locale.current.identifier,
            "state": state
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        _ = try? await URLSession.shared.data(for: req)
    }

    func persist() {
        let currentApps = apps
        let currentCerts = certificates
        let currentSources = sources
        let currentSourceApps = sourceApps
        Task {
            await Store.shared.save(currentApps, to: "apps")
            await Store.shared.save(currentCerts, to: "certificates")
            await Store.shared.save(currentSources, to: "sources")
            await Store.shared.save(currentSourceApps, to: "sourceAppsCache")
        }
    }

    // MARK: - Deep links (xsign:// e abertura direta de arquivos .ipa / .p12 / .mobileprovision / .zip)

    func handle(url: URL) {
        if url.isFileURL {
            Task {
                _ = try? await importResourcesWithHUD(urls: [url])
            }
            return
        }
        guard url.scheme == "xsign",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let target = comps.queryItems?.first(where: { $0.name == "url" })?.value,
              let inner = URL(string: target) else { return }
        switch url.host {
        case "add", "source":
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

    // MARK: - Fontes (Repositórios)

    func addSource(url: URL) async throws {
        let existing = sources.first(where: { $0.url.absoluteString.lowercased() == url.absoluteString.lowercased() })
        let result = try await sourceService.fetch(url: url, existingID: existing?.id)
        var source = result.source
        if let idx = sources.firstIndex(where: { $0.id == source.id }) {
            source.order = sources[idx].order
            sources[idx] = source
        } else {
            source.order = sources.count
            sources.append(source)
        }
        sourceApps.removeAll { $0.sourceID == source.id }
        sourceApps.append(contentsOf: result.apps)
        ensureBuiltInXSign()
        persist()
    }

    func refreshAllSources() async {
        for source in sources {
            try? await addSource(url: source.url)
        }
        ensureBuiltInXSign()
    }

    func removeSource(_ source: Source) {
        sources.removeAll { $0.id == source.id }
        sourceApps.removeAll { $0.sourceID == source.id }
        ensureBuiltInXSign()
        persist()
    }

    private func ensureBuiltInXSign() {
        sourceApps.removeAll { $0.bundleID == AppState.builtInXSignApp.bundleID && $0.sourceID == nil }
        sourceApps.insert(AppState.builtInXSignApp, at: 0)
    }

    // MARK: - Importador Universal de Recursos (.ipa, .zip, .p12, .mobileprovision, .deb, .dylib, .json)

    @discardableResult
    func importResourcesWithHUD(urls: [URL]) async throws -> String? {
        guard !urls.isEmpty else { return nil }
        let firstExt = urls.first?.pathExtension.lowercased() ?? ""
        let hudLabel: String
        switch firstExt {
        case "ipa":
            hudLabel = L.tr("loading.hud.importingIPA")
        case "zip", "p12", "pfx", "mobileprovision", "provisionprofile":
            hudLabel = L.tr("loading.hud.importingCert")
        default:
            hudLabel = L.tr("loading.hud.importingResource")
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            activeHUDTitle = hudLabel
        }
        defer {
            withAnimation(.easeInOut(duration: 0.2)) {
                activeHUDTitle = nil
            }
        }

        try? await Task.sleep(nanoseconds: 450_000_000)
        var lastMsg: String?
        for u in urls {
            lastMsg = try importResource(url: u)
        }
        return lastMsg
    }

    @discardableResult
    func importResource(url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        switch ext {
        case "ipa":
            let item = try importIPA(from: url, origin: "Arquivos", downloadURL: nil, fallbackIconURL: nil, deleteSourceFile: false)
            selectedTab = .apps
            return "App importado: \(item.name)"

        case "zip":
            let cert = try certificateService.importFromZip(url: url, makeActive: certificates.isEmpty)
            certificates.append(cert)
            persist()
            return "Certificado importado: \(cert.nickname)"

        case "p12", "pfx":
            Paths.ensure()
            let stagedP12 = Paths.certs.appendingPathComponent("staged.p12")
            try? FileManager.default.removeItem(at: stagedP12)
            try FileManager.default.copyItem(at: url, to: stagedP12)
            let stagedProv = Paths.certs.appendingPathComponent("staged.mobileprovision")
            if FileManager.default.fileExists(atPath: stagedProv.path),
               let p12Data = try? Data(contentsOf: stagedP12),
               let provData = try? Data(contentsOf: stagedProv) {
                let cert = try certificateService.saveCertificate(
                    p12Data: p12Data,
                    profileData: provData,
                    password: "1",
                    nickname: nil,
                    makeActive: certificates.isEmpty
                )
                try? FileManager.default.removeItem(at: stagedP12)
                try? FileManager.default.removeItem(at: stagedProv)
                certificates.append(cert)
                persist()
                return "Certificado importado: \(cert.nickname)"
            }
            return "Arquivo .p12 carregado. Selecione também o .mobileprovision."

        case "mobileprovision", "provisionprofile":
            Paths.ensure()
            let stagedProv = Paths.certs.appendingPathComponent("staged.mobileprovision")
            try? FileManager.default.removeItem(at: stagedProv)
            try FileManager.default.copyItem(at: url, to: stagedProv)
            let stagedP12 = Paths.certs.appendingPathComponent("staged.p12")
            if FileManager.default.fileExists(atPath: stagedP12.path),
               let p12Data = try? Data(contentsOf: stagedP12),
               let provData = try? Data(contentsOf: stagedProv) {
                let cert = try certificateService.saveCertificate(
                    p12Data: p12Data,
                    profileData: provData,
                    password: "1",
                    nickname: nil,
                    makeActive: certificates.isEmpty
                )
                try? FileManager.default.removeItem(at: stagedP12)
                try? FileManager.default.removeItem(at: stagedProv)
                certificates.append(cert)
                persist()
                return "Certificado importado: \(cert.nickname)"
            }
            return "Perfil carregado. Selecione também o .p12."

        case "deb", "dylib":
            Paths.ensure()
            let dest = Paths.tweaks.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
            return "Tweak importado: \(url.lastPathComponent)"

        case "json", "txt":
            let content = try String(contentsOf: url, encoding: .utf8)
            let candidateURLs = content
                .components(separatedBy: .newlines)
                .compactMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .filter { $0.scheme == "http" || $0.scheme == "https" }
            if !candidateURLs.isEmpty {
                Task {
                    for u in candidateURLs { try? await addSource(url: u) }
                }
                return "\(candidateURLs.count) fonte(s) adicionada(s)"
            }
            if let result = try? Data(contentsOf: url) {
                let tempURL = Paths.sourceCache.appendingPathComponent(url.lastPathComponent)
                try? result.write(to: tempURL)
            }
            return "Arquivo de fontes processado"

        default:
            let dest = Paths.downloads.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: url, to: dest)
            return "Arquivo salvo em Downloads"
        }
    }

    @discardableResult
    func importIPA(
        from sourceURL: URL,
        origin: String?,
        downloadURL: URL?,
        fallbackIconURL: URL? = nil,
        deleteSourceFile: Bool = false
    ) throws -> AppItem {
        Paths.ensure()
        let appID = UUID()
        let fileName = sourceURL.lastPathComponent.lowercased().hasSuffix(".ipa")
            ? sourceURL.lastPathComponent
            : "\(sourceURL.lastPathComponent).ipa"
        let destURL = Paths.unsigned.appendingPathComponent("\(appID.uuidString)-\(fileName)")

        if sourceURL.standardizedFileURL != destURL.standardizedFileURL {
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            if deleteSourceFile {
                try? FileManager.default.removeItem(at: sourceURL)
            }
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 0
        let metadata = try? IPAPackageReader.read(ipaURL: destURL)

        var savedIconPath: String? = nil
        if let iconData = metadata?.iconData {
            let iconURL = Paths.icons.appendingPathComponent("\(appID.uuidString).png")
            if (try? iconData.write(to: iconURL, options: .atomic)) != nil {
                savedIconPath = Paths.relative(iconURL)
            }
        }

        let item = AppItem(
            id: appID,
            name: metadata?.name ?? sourceURL.deletingPathExtension().lastPathComponent,
            bundleID: metadata?.bundleID ?? "com.imported.app",
            version: metadata?.version ?? "1.0",
            iconPath: savedIconPath,
            iconURL: fallbackIconURL,
            filePath: Paths.relative(destURL),
            downloadURL: downloadURL,
            size: fileSize,
            state: .unsigned,
            origin: origin
        )

        apps.insert(item, at: 0)
        persist()
        return item
    }

    // MARK: - Apps

    func delete(_ app: AppItem) {
        apps.removeAll { $0.id == app.id }
        if !app.filePath.isEmpty && !app.filePath.hasPrefix("http") {
            try? FileManager.default.removeItem(at: Paths.resolve(app.filePath))
        }
        if let iconPath = app.iconPath {
            try? FileManager.default.removeItem(at: Paths.resolve(iconPath))
        }
        persist()
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
    var installMethod = "remoteServer"
    var serverURL = "https://exploiting-ios.online"
    var appIcon = "graphite"

    static func load() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: "settings"),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        UserDefaults.standard.set(s.serverURL, forKey: "xsign.serverURL")
        return s
    }

    func save() {
        UserDefaults.standard.set(serverURL, forKey: "xsign.serverURL")
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "settings")
        }
    }
}
