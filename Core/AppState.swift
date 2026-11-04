import SwiftUI
import UIKit
import Combine

/// Informações de nova versão retornadas pelo servidor ou GitHub.
struct AppUpdateInfo: Identifiable, Codable, Equatable {
    var id: String { "\(version)-\(build ?? "1")" }
    let version: String
    let build: String?
    let ipaUrl: String?
    let installUrl: String?
    let notes: String?
}

/// Estado central do app: dados reais persistidos, serviços e preferências.
@MainActor
final class AppState: ObservableObject {
    @Published var selectedTab: AppTab = .apps

    /// Origem do XSign que já vem pronto na lista de Apps.
    static let officialOrigin = "XSign Official"

    /// Versão (CFBundleShortVersionString) do XSign instalado.
    static var bundleShortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    static var builtInXSignApp: SourceApp { builtInXSignApp(version: bundleShortVersion) }

    /// XSign oficial da Loja; `version` é a do link "latest" quando já conhecida.
    static func builtInXSignApp(version: String) -> SourceApp {
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
                    version: version,
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

    // Estado da Splash de abertura (1), HUD de carregamento (2) e Auto-Update OTA
    @Published var isBootstrapping: Bool = true
    @Published var bootProgress: Double = 0.22
    @Published var bootStatusText: String = L.tr("loading.boot.certs")
    @Published var activeHUDTitle: String? = nil
    @Published var availableUpdate: AppUpdateInfo? = nil
    @Published var selfUpdateTarget: AppItem? = nil
    /// Aviso de certificado revogado pela Apple (mostrado uma vez por revogação).
    @Published var revocationAlert: String? = nil

    /// Versão publicada no link "latest" (vem da checagem de atualização).
    private var latestRemoteVersion: String?

    /// Versão que o XSign oficial baixa hoje: a do "latest" ou, sem rede, a instalada.
    var latestXSignVersion: String { latestRemoteVersion ?? currentAppVersion }

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
        downloads.notificationsEnabled = { [weak self] in
            self?.settings.notifyDownloads ?? true
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

        // Se nenhum certificado foi importado ainda, importa automaticamente o certificado que instalou o próprio XSign
        if certificates.isEmpty, let embeddedCert = certificateService.importEmbeddedAppCertificate(makeActive: true) {
            certificates.append(embeddedCert)
            persist()
        }

        // Atualiza status de validade dos certificados carregados
        for i in certificates.indices {
            certificates[i].status = certificateService.status(expiresAt: certificates[i].expiresAt)
        }

        // Na primeira abertura, já deixa o próprio XSign importado em Apps vinculado ao certificado instalado
        if !UserDefaults.standard.bool(forKey: "xsign.seededOwnApp") {
            UserDefaults.standard.set(true, forKey: "xsign.seededOwnApp")
            let releaseURL = URL(string: "https://github.com/lotte-xrd/XSign/releases/download/latest/XSign-unsigned.ipa")
            let activeCert = currentCertificate
            let ownUnsigned = AppItem(
                name: "XSign",
                bundleID: Bundle.main.bundleIdentifier ?? "com.xsign.app",
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
                iconPath: nil,
                iconURL: nil,
                filePath: "",
                downloadURL: releaseURL,
                size: 0,
                state: .unsigned,
                certificateID: activeCert?.id,
                certificateName: activeCert?.nickname,
                origin: Self.officialOrigin
            )
            if !apps.contains(where: { $0.name == "XSign" && $0.state == .unsigned }) {
                apps.insert(ownUnsigned, at: 0)
            }
            if let cert = activeCert, !apps.contains(where: { $0.name == "XSign" && $0.state == .signed }) {
                let ownSigned = AppItem(
                    name: "XSign",
                    bundleID: Bundle.main.bundleIdentifier ?? "com.xsign.app",
                    version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
                    iconPath: nil,
                    iconURL: nil,
                    filePath: "",
                    downloadURL: releaseURL,
                    size: 0,
                    state: .signed,
                    certificateID: cert.id,
                    certificateName: cert.nickname,
                    signedAt: Date(),
                    origin: Self.officialOrigin
                )
                apps.append(ownSigned)
            }
            persist()
        }
        // O rótulo de versão foi gravado na primeira abertura; acerta para a versão atual.
        refreshOfficialXSignEntries()

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
        importFinishedBackgroundSigns()
        resumePendingInstallIfNeeded()
        Task { _ = await checkForAppUpdate(manual: false) }
        Task { await refreshAppleRevocation(force: false) }

        // Atualiza todas as fontes cadastradas em segundo plano
        if !sources.isEmpty {
            await refreshAllSources()
        }
    }

    // MARK: - Auto-Update OTA (Sem App Store)

    var currentAppVersion: String {
        Self.bundleShortVersion
    }

    var currentAppBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    @discardableResult
    func checkForAppUpdate(manual: Bool = false) async -> Bool {
        if manual {
            withAnimation(.easeInOut(duration: 0.2)) {
                activeHUDTitle = L.tr("loading.hud.checkingUpdate")
            }
        }
        defer {
            if manual {
                withAnimation(.easeInOut(duration: 0.2)) {
                    activeHUDTitle = nil
                }
            }
        }

        let base = settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let ts = Int(Date().timeIntervalSince1970)
        var candidates: [URL] = []
        if let serverVersionURL = URL(string: "\(base)/api/xsign/version?t=\(ts)") {
            candidates.append(serverVersionURL)
        }
        if let ghVersionURL = URL(string: "https://raw.githubusercontent.com/lotte-xrd/XSign/main/version.json?t=\(ts)") {
            candidates.append(ghVersionURL)
        }

        for url in candidates {
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
            req.setValue("XSign/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
            req.setValue(KeychainHelper.deviceID, forHTTPHeaderField: "X-XSign-Device")
            if let cert = currentCertificate {
                req.setValue(cert.teamID, forHTTPHeaderField: "X-XSign-TeamID")
                if let appID = cert.appID {
                    req.setValue(appID, forHTTPHeaderField: "X-XSign-AppID")
                }
            }
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let info = try? JSONDecoder().decode(AppUpdateInfo.self, from: data) else {
                continue
            }

            let remoteVersion = info.version.trimmingCharacters(in: .whitespacesAndNewlines)
            if !remoteVersion.isEmpty, remoteVersion != latestRemoteVersion {
                latestRemoteVersion = remoteVersion
                ensureBuiltInXSign()
                refreshOfficialXSignEntries()
            }

            if Self.isNewerVersion(
                remoteVersion: info.version,
                remoteBuild: info.build,
                localVersion: currentAppVersion,
                localBuild: currentAppBuild
            ) {
                availableUpdate = info
                return true
            }
            return false
        }
        return false
    }

    func triggerSelfUpdate(_ info: AppUpdateInfo) {
        availableUpdate = nil
        // 1) Se o servidor já devolveu um link OTA itms-services:// pré-assinado com o mesmo certificado
        if let directOTA = info.installUrl, !directOTA.isEmpty {
            Task {
                try? await openInstall(directOTA, bundleID: Bundle.main.bundleIdentifier)
            }
            return
        }

        // 2) Assina o novo .ipa automaticamente no servidor usando o certificado ativo do usuário e instala via OTA por cima!
        let ipaURLString = info.ipaUrl ?? "https://github.com/lotte-xrd/XSign/releases/download/latest/XSign-unsigned.ipa"
        guard let remoteURL = URL(string: ipaURLString) else { return }

        let target = AppItem(
            name: "XSign",
            bundleID: Bundle.main.bundleIdentifier ?? "com.xsign.app",
            version: info.version,
            iconPath: nil,
            iconURL: nil,
            filePath: "",
            downloadURL: remoteURL,
            size: 0,
            state: .unsigned,
            certificateID: currentCertificate?.id,
            certificateName: currentCertificate?.nickname,
            origin: "XSign Auto-Update"
        )
        selfUpdateTarget = target
    }

    // MARK: - Fechar o app para a atualização entrar

    /// O iOS só troca o XSign por uma versão nova com o app fechado. Quando o
    /// link aberto instala o próprio XSign, o app fecha sozinho assim que a
    /// pessoa responde ao pedido de instalação do iOS.
    private var exitArmedForUpdate = false

    /// Instalação que ficou para quando o app voltar para a tela (o iOS não
    /// abre o pedido de instalação com o app em segundo plano).
    private var pendingInstall: (url: String, bundleID: String?)?

    /// Abre um link itms-services://; se for o próprio XSign, prepara o fechamento.
    func openInstall(_ installURL: String, bundleID: String?) async throws {
        guard UIApplication.shared.applicationState == .active else {
            pendingInstall = (installURL, bundleID)
            return
        }
        let isSelf = bundleID != nil && bundleID == Bundle.main.bundleIdentifier
        if isSelf { exitArmedForUpdate = true }
        do {
            try await installService.openInstallURL(installURL)
        } catch {
            if isSelf { exitArmedForUpdate = false }
            throw error
        }
    }

    /// Ao voltar para a tela: instala o que ficou pendente ou o que veio de uma
    /// notificação tocada.
    func resumePendingInstallIfNeeded() {
        if let tapped = PendingNotificationAction.takeInstall() {
            pendingInstall = tapped
        }
        guard let next = pendingInstall, UIApplication.shared.applicationState == .active else { return }
        pendingInstall = nil
        Task { try? await openInstall(next.url, bundleID: next.bundleID) }
    }

    /// Chamado quando a cena volta a ficar ativa (o pedido de instalação sumiu)
    /// ou vai para o segundo plano.
    func closeForUpdateIfArmed(immediately: Bool) {
        guard exitArmedForUpdate else { return }
        exitArmedForUpdate = false
        if immediately {
            exit(0)
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            activeHUDTitle = L.tr("update.closing")
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            // Vai para a tela inicial, como o botão de início, e encerra o processo.
            UIApplication.shared.perform(#selector(NSXPCConnection.suspend))
            try? await Task.sleep(nanoseconds: 500_000_000)
            exit(0)
        }
    }

    // MARK: - Instalar um app assinado (renova o link vencido sozinho)

    /// Instala um app da aba Assinados. Se o link do servidor venceu (24 h) ou
    /// sumiu, assina de novo com as mesmas opções e instala, sem pedir nada.
    func installSigned(_ item: AppItem) async throws {
        if let url = item.installURL, !url.isEmpty, await installLinkIsAlive(item) {
            try await openInstall(url, bundleID: item.bundleID)
            return
        }
        try await renewAndInstall(item)
    }

    private func installLinkIsAlive(_ item: AppItem) async -> Bool {
        if let expiresAt = item.expiresAt, expiresAt.timeIntervalSinceNow < 120 { return false }
        guard let manifest = Self.manifestURL(fromInstallURL: item.installURL) else { return true }
        var request = URLRequest(url: manifest, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("XSign/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return true // sem rede: tenta o link mesmo assim
        }
        return (200...299).contains(http.statusCode)
    }

    private static func manifestURL(fromInstallURL installURL: String?) -> URL? {
        guard let installURL,
              let components = URLComponents(string: installURL),
              let raw = components.queryItems?.first(where: { $0.name == "url" })?.value else { return nil }
        return URL(string: raw)
    }

    /// De onde reassinar um item: o .ipa original no aparelho ou o link de origem.
    func signingInput(for item: AppItem) -> AppItem {
        guard item.state == .signed else { return item }
        var input = item
        if let source = item.sourcePath, !source.isEmpty,
           FileManager.default.fileExists(atPath: Paths.resolve(source).path) {
            input.filePath = source
        } else {
            input.filePath = ""
        }
        input.downloadURL = item.sourceURL ?? item.downloadURL
        return input
    }

    private func renewAndInstall(_ item: AppItem) async throws {
        let input = signingInput(for: item)
        guard !input.filePath.isEmpty || input.downloadURL != nil else {
            throw Self.appError(L.tr("renew.noSource"))
        }
        guard let certificate = certificates.first(where: { $0.id == item.certificateID }) ?? currentCertificate else {
            throw Self.appError(L.tr("sign.noCert"))
        }
        let options = item.signOptions ?? SignOptions(name: item.name, bundleID: item.bundleID, version: item.version)

        withAnimation(.easeInOut(duration: 0.2)) { activeHUDTitle = L.tr("renew.hud") }
        var last: SignProgress?
        for await update in signingService.sign(app: input, certificate: certificate, options: options) {
            last = update
        }
        withAnimation(.easeInOut(duration: 0.2)) { activeHUDTitle = nil }

        guard let done = last, done.finished, let installURL = done.installURL else {
            throw Self.appError(last?.error ?? L.tr("renew.failed"))
        }
        if let i = apps.firstIndex(where: { $0.id == item.id }) {
            apps[i].installURL = done.installURL
            apps[i].signedDownloadURL = done.downloadURL
            apps[i].shareURL = done.shareURL
            apps[i].expiresAt = done.expiresAt
            apps[i].filePath = done.outputPath ?? apps[i].filePath
            apps[i].signedAt = Date()
            persist()
        }
        try await openInstall(installURL, bundleID: done.finalBundleID ?? item.bundleID)
    }

    private static func appError(_ message: String) -> NSError {
        NSError(domain: "XSign", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - Assinaturas que terminaram com o app fechado

    /// O iOS pode encerrar o XSign enquanto o servidor assina. A resposta fica
    /// salva em disco e o app entra na aba Assinados na próxima abertura.
    func importFinishedBackgroundSigns() {
        for job in PendingSignStore.takeFinished() {
            guard let data = job.resultData,
                  let decoded = try? JSONDecoder().decode(RemoteSigningService.RemoteSignResponse.self, from: data),
                  let certificate = certificates.first(where: { $0.id == job.certificateID }) ?? currentCertificate
            else { continue }
            var progress = SignProgress(steps: [], fraction: 1)
            progress.finished = true
            progress.outputPath = decoded.downloadUrl
            progress.installURL = decoded.installUrl
            progress.downloadURL = decoded.downloadUrl
            progress.shareURL = decoded.shareUrl
            progress.finalName = decoded.appName
            progress.finalBundleID = decoded.bundleIdentifier
            progress.finalVersion = decoded.bundleVersion
            progress.fileSize = decoded.fileSize
            progress.expiresAt = decoded.expiresAt.flatMap(RemoteSigningService.parseServerDate)
            registerSigned(original: job.app, certificate: certificate, options: job.options, progress: progress)
        }
    }

    // MARK: - Revogação pela Apple (OCSP)

    /// Consulta a Apple (pelo servidor) e avisa uma vez quando um certificado
    /// aparece revogado. Só informa: a assinatura continua liberada.
    func refreshAppleRevocation(force: Bool) async {
        let base = settings.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        var newlyRevoked: [String] = []
        for cert in certificates {
            if !force, let last = cert.appleCheckedAt, Date().timeIntervalSince(last) < 6 * 60 * 60 { continue }
            guard let result = await certificateService.appleRevocationStatus(for: cert, serverBase: base),
                  let i = certificates.firstIndex(where: { $0.id == cert.id }) else { continue }
            let wasRevoked = certificates[i].isRevokedByApple
            certificates[i].appleStatus = result.status
            certificates[i].appleRevokedAt = result.revokedAt
            certificates[i].appleCheckedAt = Date()
            if result.status == "revoked" && !wasRevoked {
                let since = result.revokedAt?.formatted(date: .abbreviated, time: .omitted)
                newlyRevoked.append(since.map { "\(cert.nickname) (\($0))" } ?? cert.nickname)
            }
        }
        persist()
        if !newlyRevoked.isEmpty {
            revocationAlert = L.tr("revoked.alert.body", newlyRevoked.joined(separator: ", "))
        }
    }

    private static func isNewerVersion(remoteVersion: String, remoteBuild: String?, localVersion: String, localBuild: String) -> Bool {
        let rParts = remoteVersion.split(separator: ".").compactMap { Int($0) }
        let lParts = localVersion.split(separator: ".").compactMap { Int($0) }
        let count = max(rParts.count, lParts.count)
        for i in 0..<count {
            let r = i < rParts.count ? rParts[i] : 0
            let l = i < lParts.count ? lParts[i] : 0
            if r > l { return true }
            if r < l { return false }
        }
        if let rb = remoteBuild.flatMap({ Int($0) }), let lb = Int(localBuild), rb > lb {
            return true
        }
        return false
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
        let builtIn = AppState.builtInXSignApp(version: latestXSignVersion)
        sourceApps.removeAll { $0.bundleID == builtIn.bundleID && $0.sourceID == nil }
        sourceApps.insert(builtIn, at: 0)
    }

    /// Item do XSign que vem pronto na lista de Apps e ainda não tem arquivo
    /// próprio: só aponta para o link "latest" do GitHub.
    func isOfficialPlaceholder(_ item: AppItem) -> Bool {
        item.origin == Self.officialOrigin
            && item.filePath.isEmpty
            && (item.installURL ?? "").isEmpty
    }

    /// Mantém o rótulo de versão desses itens igual à realidade: o não assinado
    /// mostra a versão que o link "latest" baixa; o assinado, a instalada.
    private func refreshOfficialXSignEntries() {
        var changed = false
        for i in apps.indices where isOfficialPlaceholder(apps[i]) {
            let version = apps[i].state == .signed ? currentAppVersion : latestXSignVersion
            if apps[i].version != version {
                apps[i].version = version
                changed = true
            }
        }
        if changed { persist() }
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

    /// Registra o resultado de uma assinatura na aba Assinados (usado pela
    /// assinatura individual e pela assinatura em lote).
    @discardableResult
    func registerSigned(original app: AppItem, certificate: Certificate, options: SignOptions, progress: SignProgress) -> AppItem {
        var signed = app
        signed.id = UUID()
        signed.state = .signed
        signed.certificateID = certificate.id
        signed.certificateName = certificate.nickname
        signed.signedAt = Date()
        signed.filePath = progress.outputPath ?? app.filePath
        signed.installURL = progress.installURL
        signed.signedDownloadURL = progress.downloadURL
        signed.shareURL = progress.shareURL
        signed.name = progress.finalName ?? options.name ?? app.name
        signed.bundleID = progress.finalBundleID ?? options.bundleID ?? app.bundleID
        signed.version = progress.finalVersion ?? options.version ?? app.version
        signed.expiresAt = progress.expiresAt
        signed.signOptions = options
        if app.state == .unsigned {
            let isLocal = !app.filePath.isEmpty && !app.filePath.hasPrefix("http")
            signed.sourcePath = isLocal ? app.filePath : nil
            signed.sourceURL = app.downloadURL
        } else {
            signed.sourcePath = app.sourcePath ?? ((!app.filePath.isEmpty && !app.filePath.hasPrefix("http")) ? app.filePath : nil)
            signed.sourceURL = app.sourceURL ?? app.downloadURL
        }
        if let fSize = progress.fileSize, fSize > 0 {
            signed.size = fSize
        }

        apps.insert(signed, at: 0)
        if app.state == .signed, isOfficialPlaceholder(app) {
            // O assinado de verdade substitui o item sem arquivo que veio pronto.
            apps.removeAll { $0.id == app.id }
            persist()
        } else if settings.deleteOriginalAfterSign, app.state == .unsigned {
            delete(app)
        } else {
            persist()
        }
        return signed
    }

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
    /// Opcional para não quebrar a leitura de ajustes salvos por versões antigas.
    var notifyDownloadsPref: Bool?

    var notifyDownloads: Bool {
        get { notifyDownloadsPref ?? true }
        set { notifyDownloadsPref = newValue }
    }

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
