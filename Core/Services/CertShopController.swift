import SwiftUI
import UIKit
import UserNotifications

/// Pedido em andamento, guardado para continuar depois de fechar o app.
struct PendingCertOrder: Codable, Equatable {
    var token: String
    var planID: String
    var udid: String
    var checkoutURL: URL
    var createdAt: Date
    var paidSeenAt: Date?
    var readySeenAt: Date?
    var importSeconds: Double?
    var importedCertificateID: UUID?
    var successShown: Bool = false
    /// E-mail mandado com o pedido (1.4.2+).
    var email: String?
}

/// Descoberta do UDID pelo perfil em andamento, guardada para sobreviver se o
/// iOS fechar o XSign enquanto a pessoa instala o perfil em Ajustes.
struct UDIDDiscovery: Codable, Equatable {
    var session: String
    /// Plano a comprar assim que o UDID chegar (`nil` = só preencher).
    var buyPlanID: String?
    var startedAt: Date

    /// O servidor guarda a sessão por 1 hora.
    var isExpired: Bool { Date().timeIntervalSince(startedAt) > 3600 }
}

/// Compra de certificado dentro do app: escolhe o plano, cria o pedido no
/// servidor, abre o pagamento numa janela do Safari, acompanha o pedido e
/// importa o certificado sozinho quando fica pronto.
@MainActor
final class CertShopController: ObservableObject {
    // Telas
    @Published var shopPresented = false
    @Published var checkoutURL: URL?
    @Published var progressPresented = false

    // Escolha
    @Published var selectedPlanID = CertPlan.defaultID
    @Published var udidInput = ""
    @Published var udidSource: UDIDSource = .none
    @Published private(set) var udidSourceName: String?
    @Published private(set) var discovery: UDIDDiscovery?
    @Published var emailInput = CustomerEmail.saved

    // Pedido
    @Published private(set) var pending: PendingCertOrder?
    @Published private(set) var order: CertOrder?
    @Published private(set) var log: [SignLogLine] = []
    @Published private(set) var isCreating = false
    @Published private(set) var isRetrying = false
    @Published var errorMessage: String?
    @Published private(set) var importError: String?

    private weak var app: AppState?
    private var pollTask: Task<Void, Never>?
    private var pollGeneration = 0
    private var consecutiveErrors = 0
    private var udidWatch: Task<Void, Never>?
    private var backgroundGuard: BackgroundTaskGuard?

    private static let storeKey = "xsign.certshop.pending"
    private static let discoveryKey = "xsign.certshop.udidDiscovery"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let saved = try? JSONDecoder().decode(PendingCertOrder.self, from: data) {
            pending = saved
            selectedPlanID = saved.planID
        }
        if let data = UserDefaults.standard.data(forKey: Self.discoveryKey),
           let saved = try? JSONDecoder().decode(UDIDDiscovery.self, from: data), !saved.isExpired {
            discovery = saved
            if let plan = saved.buyPlanID { selectedPlanID = plan }
        } else {
            UserDefaults.standard.removeObject(forKey: Self.discoveryKey)
        }
    }

    func attach(_ app: AppState) {
        self.app = app
    }

    // MARK: - Estado para as telas

    var selectedPlan: CertPlan { CertPlan.find(selectedPlanID) ?? CertPlan.all[CertPlan.all.count - 1] }
    var normalizedUDID: String? { DeviceUDID.normalize(udidInput) }
    var normalizedEmail: String? { CustomerEmail.normalize(emailInput) }
    var pendingPlan: CertPlan? { pending.flatMap { CertPlan.find($0.planID) } }
    var isImported: Bool { pending?.importedCertificateID != nil }
    var discoveringUDID: Bool { discovery != nil }
    /// Sem UDID nenhum: o botão Comprar descobre pelo perfil antes de cobrar.
    var needsUDIDDiscovery: Bool { udidInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var importedCertificate: Certificate? {
        guard let id = pending?.importedCertificateID else { return nil }
        return app?.certificates.first { $0.id == id }
    }

    /// Pedido aberto, ainda sem pagamento, para o plano e o UDID escolhidos.
    var openCheckoutForSelection: PendingCertOrder? {
        guard let pending, pending.importedCertificateID == nil,
              order?.isAwaitingPayment ?? true,
              pending.planID == selectedPlanID,
              pending.udid == normalizedUDID,
              pending.email == normalizedEmail else { return nil }
        return pending
    }

    enum BannerState { case offer, awaitingPayment, working, failed }

    /// O que o cartão da tela Apps mostra (`nil` = nada).
    func bannerState(certificates: [Certificate], current: Certificate?) -> BannerState? {
        if let pending, pending.importedCertificateID == nil, let order, !order.isExpired {
            if order.isAwaitingPayment { return .awaitingPayment }
            if order.isFailed || (order.isReady && importError != nil) { return .failed }
            return .working
        }
        guard let current else { return .offer }
        if !current.status.canSign || current.status == .expiring || current.isRevokedByApple { return .offer }
        return nil
    }

    // MARK: - Abrir a compra

    func openShop() {
        errorMessage = nil
        prepareUDID()
        if let order, !isImported, order.isPaid {
            progressPresented = true
            return
        }
        shopPresented = true
        if pending != nil, !isImported { startPolling() }
    }

    /// Preenche o UDID com a melhor fonte, sem apagar o que o usuário digitou.
    func prepareUDID() {
        if normalizedUDID != nil, udidSource != .none { return }
        if let embedded = DeviceUDID.fromEmbeddedProfile() {
            DeviceUDID.remember(embedded)
            setUDID(embedded, source: .embedded)
        } else if let saved = DeviceUDID.saved {
            setUDID(saved, source: .saved)
        } else if let fromCert = DeviceUDID.fromCertificates(app?.certificates ?? []) {
            setUDID(fromCert.udid, source: .certificate, name: fromCert.name)
        } else if let pending, pending.importedCertificateID == nil {
            setUDID(pending.udid, source: .manual)
        }
    }

    func userEditedUDID(_ value: String) {
        udidInput = value
        udidSource = .manual
        udidSourceName = nil
    }

    private func setUDID(_ value: String, source: UDIDSource, name: String? = nil) {
        udidInput = value
        udidSource = source
        udidSourceName = name
    }

    // MARK: - Descobrir o UDID pelo perfil ("Profile Service")
    //
    // O iOS não entrega o UDID a nenhum app. O mais perto de automático é o
    // perfil de descoberta: o XSign abre o perfil no Safari, a pessoa instala
    // em Ajustes, o iPhone manda o UDID ao servidor e o Safari abre o XSign de
    // volta. O app preenche sozinho, guarda o UDID e, se veio do botão
    // Comprar, segue direto para o pagamento. Só acontece uma vez por iPhone.

    /// `thenBuy`: quando o UDID chegar, cria o pedido e abre o pagamento.
    func startUDIDDiscovery(thenBuy: Bool = false) {
        errorMessage = nil
        discovery = UDIDDiscovery(
            session: DeviceUDID.newSessionID(),
            buyPlanID: thenBuy ? selectedPlanID : nil,
            startedAt: Date()
        )
        saveDiscovery()
        openUDIDProfile()
    }

    /// Abre (de novo) o perfil da descoberta em andamento.
    func openUDIDProfile() {
        guard let session = discovery?.session else { return }
        UIApplication.shared.open(CertShopAPI.current().udidProfileURL(session: session))
    }

    /// Link xsign://udid?session=…&value=… vindo da página do UDID.
    func receiveUDIDLink(session: String?, value: String?) {
        // Com o app abrindo do zero, espera a tela inicial: resume() confere no servidor.
        guard let current = discovery, app?.isBootstrapping != true else { return }
        if let session, session == current.session, let value, let udid = DeviceUDID.normalize(value) {
            finishUDIDDiscovery(udid)
        } else {
            Task { await checkUDIDSession() }
        }
    }

    func checkUDIDSession() async {
        guard let current = discovery else { return }
        if current.isExpired {
            cancelUDIDDiscovery()
            return
        }
        if let found = try? await CertShopAPI.current().foundUDID(session: current.session),
           let udid = DeviceUDID.normalize(found.udid), discovery?.session == current.session {
            finishUDIDDiscovery(udid)
        }
    }

    /// Com o app aberto, confere a cada 3 s se o UDID já chegou (cobre quem
    /// volta ao XSign sem tocar em "Abrir" no Safari).
    private func watchUDIDSession() {
        udidWatch?.cancel()
        guard discovery != nil else { return }
        udidWatch = Task {
            for _ in 0..<60 {
                guard !Task.isCancelled, self.discovery != nil,
                      UIApplication.shared.applicationState == .active else { return }
                await self.checkUDIDSession()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func finishUDIDDiscovery(_ udid: String) {
        let planToBuy = discovery?.buyPlanID
        stopUDIDDiscovery()
        DeviceUDID.remember(udid)
        setUDID(udid, source: .profile)
        errorMessage = nil
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        guard !progressPresented else { return }
        let wasPresented = shopPresented
        shopPresented = true
        guard let planToBuy else { return }
        selectedPlanID = planToBuy
        Task {
            // Se a folha da compra precisou abrir agora, espera ela aparecer.
            if !wasPresented { try? await Task.sleep(nanoseconds: 650_000_000) }
            await buy()
        }
    }

    func cancelUDIDDiscovery() {
        stopUDIDDiscovery()
    }

    private func stopUDIDDiscovery() {
        udidWatch?.cancel()
        udidWatch = nil
        discovery = nil
        saveDiscovery()
    }

    private func saveDiscovery() {
        if let discovery, let data = try? JSONEncoder().encode(discovery) {
            UserDefaults.standard.set(data, forKey: Self.discoveryKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.discoveryKey)
        }
    }

    // MARK: - Comprar

    func buy() async {
        guard !isCreating, discovery == nil else { return }
        guard let email = normalizedEmail else {
            let empty = emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            errorMessage = L.tr(empty ? "shop.email.missing" : "shop.email.invalid")
            return
        }
        // Guarda já: se o UDID ainda vai ser descoberto, a compra continua com ele.
        CustomerEmail.remember(email)
        guard let udid = normalizedUDID else {
            if needsUDIDDiscovery {
                // Primeira compra neste iPhone: confirma o UDID pelo perfil e continua sozinho.
                startUDIDDiscovery(thenBuy: true)
            } else {
                errorMessage = L.tr("shop.udid.invalid")
            }
            return
        }
        errorMessage = nil

        if let open = openCheckoutForSelection {
            checkoutURL = open.checkoutURL
            startPolling()
            return
        }

        isCreating = true
        defer { isCreating = false }

        // O pedido anterior pode ter sido pago enquanto isso: mostra ele em vez de cobrar de novo.
        if pending != nil, !isImported {
            _ = await pollOnce()
            if order?.isPaid == true {
                showProgress()
                return
            }
        }

        requestNotificationPermission()
        do {
            let created = try await CertShopAPI.current().createOrder(planID: selectedPlanID, udid: udid, email: email)
            guard let url = URL(string: created.checkoutUrl) else {
                throw CertShopAPI.APIError(message: L.tr("shop.error.response"))
            }
            stopPolling()
            pending = PendingCertOrder(
                token: created.token,
                planID: selectedPlanID,
                udid: created.order.udid,
                checkoutURL: url,
                createdAt: Date(),
                email: email
            )
            order = created.order
            importError = nil
            log = []
            addLog(.info, L.tr("shop.log.order", created.order.number, selectedPlan.title))
            addLog(.detail, "UDID \(created.order.udid)")
            save()
            checkoutURL = url
            startPolling()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// A janela de pagamento foi fechada (OK ou gesto).
    func checkoutClosed() {
        checkoutURL = nil
        Task { await pollOnce() }
    }

    /// Esquece o pedido aberto (o servidor deixa expirar sozinho).
    func discardOpenOrder() {
        guard order?.isPaid != true else { return }
        clearPending()
    }

    // MARK: - Andamento

    func showProgress() {
        let wasPresenting = shopPresented || checkoutURL != nil
        checkoutURL = nil
        shopPresented = false
        guard !progressPresented else { return }
        Task {
            // Espera a folha fechar antes de abrir a tela cheia.
            if wasPresenting { try? await Task.sleep(nanoseconds: 650_000_000) }
            progressPresented = true
        }
    }

    /// "Continuar em segundo plano": fecha a tela e segue acompanhando.
    func hideProgress() {
        progressPresented = false
    }

    /// Fecha a tela final. Com o certificado importado, o pedido termina aqui.
    func closeProgress() {
        progressPresented = false
        if isImported || order?.isExpired == true {
            clearPending()
        }
    }

    func retry() async {
        guard let token = pending?.token, !isRetrying else { return }
        isRetrying = true
        defer { isRetrying = false }
        importError = nil
        addLog(.info, L.tr("shop.log.retry"))

        if order?.isReady == true {
            // O certificado já existe no servidor; só baixa e importa de novo.
            startPolling()
            return
        }
        do {
            let response = try await CertShopAPI.current().retry(token: token)
            apply(response.order)
            startPolling()
        } catch {
            addLog(.error, error.localizedDescription)
        }
    }

    // MARK: - Ciclo de vida do app

    /// Fim do bootstrap: retoma o pedido salvo e a descoberta do UDID.
    func resume() {
        if discovery != nil { watchUDIDSession() }
        guard let pending else { return }
        if pending.importedCertificateID != nil {
            if importedCertificate == nil || pending.successShown {
                clearPending()
            } else {
                presentSuccess()
            }
            return
        }
        startPolling()
    }

    func appBecameActive() {
        backgroundGuard?.end()
        backgroundGuard = nil
        if discovery != nil { watchUDIDSession() }
        guard let pending else { return }
        if pending.importedCertificateID != nil {
            if !pending.successShown, importedCertificate != nil { presentSuccess() }
            return
        }
        startPolling()
    }

    /// Pede ao iOS alguns segundos a mais para seguir acompanhando o pedido pago.
    func appEnteredBackground() {
        guard pollTask != nil, order?.isPaid == true, backgroundGuard == nil else { return }
        backgroundGuard = BackgroundTaskGuard(name: "xsign.certshop")
    }

    // MARK: - Consulta ao servidor

    func startPolling() {
        guard pollTask == nil, let pending, pending.importedCertificateID == nil else { return }
        pollGeneration += 1
        let generation = pollGeneration
        pollTask = Task {
            while !Task.isCancelled {
                let again = await self.pollOnce()
                if !again || Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: self.pollInterval)
            }
            // Só limpa se nenhuma outra consulta começou depois desta.
            guard self.pollGeneration == generation else { return }
            self.pollTask = nil
            self.backgroundGuard?.end()
            self.backgroundGuard = nil
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        pollGeneration += 1
    }

    private var pollInterval: UInt64 {
        let base: Double = (order?.isAwaitingPayment ?? true) ? 4 : 3
        let backoff = min(30, base * pow(2, Double(min(consecutiveErrors, 4))))
        return UInt64(backoff * 1_000_000_000)
    }

    /// Consulta o pedido uma vez. Devolve `false` quando não precisa consultar de novo.
    @discardableResult
    func pollOnce() async -> Bool {
        guard let token = pending?.token, pending?.importedCertificateID == nil else { return false }
        do {
            let response = try await CertShopAPI.current().order(token: token)
            consecutiveErrors = 0
            guard pending?.token == token else { return false } // trocou de pedido no meio
            apply(response.order)
            let current = response.order
            if current.isReady {
                if let certificate = response.certificate { importCertificate(certificate) }
                return pending?.importedCertificateID == nil && importError == nil
            }
            if current.isExpired || current.isFailed { return false }
            if current.isAwaitingPayment {
                guard let createdAt = pending?.createdAt else { return false }
                // Sem a janela de pagamento aberta, para de consultar depois de 2 h.
                return checkoutURL != nil || shopPresented || Date().timeIntervalSince(createdAt) < 2 * 3600
            }
            return true
        } catch let error as CertShopAPI.APIError where error.status == 403 || error.status == 404 {
            if order?.isPaid == true {
                addLog(.error, error.message)
            } else {
                clearPending()
            }
            return false
        } catch {
            consecutiveErrors += 1
            return true
        }
    }

    private func apply(_ new: CertOrder) {
        let previous = order
        order = new
        guard previous?.status != new.status else { return }

        if new.isPaid, previous?.isPaid != true {
            addLog(.success, L.tr("shop.log.paid", new.paymentSummary ?? "—"))
        }
        switch new.status {
        case "issuing":
            addLog(.info, L.tr("shop.log.issuing"))
        case "pending":
            addLog(.detail, new.upstreamMessage.map { L.tr("shop.log.pendingWith", $0) } ?? L.tr("shop.log.pending"))
        case "ready":
            addLog(.success, L.tr("shop.log.ready"))
        case "failed":
            addLog(.error, new.error ?? L.tr("shop.error.generic"))
        case "expired":
            addLog(.warning, L.tr("shop.log.expired"))
        default:
            break
        }

        if new.isPaid, pending?.paidSeenAt == nil {
            pending?.paidSeenAt = Date()
            save()
        }
        if new.isReady, pending?.readySeenAt == nil {
            pending?.readySeenAt = Date()
            save()
        }
        // Pagamento confirmado com a janela aberta: fecha a janela e mostra o andamento.
        if previous?.isAwaitingPayment == true, new.isPaid {
            showProgress()
        }
    }

    // MARK: - Importar o certificado

    private func importCertificate(_ payload: CertificatePayload) {
        guard let app, var current = pending, current.importedCertificateID == nil else { return }
        guard let p12 = Data(base64Encoded: payload.p12),
              let profile = Data(base64Encoded: payload.mobileprovision) else {
            importError = L.tr("shop.error.response")
            addLog(.error, L.tr("shop.error.response"))
            return
        }
        let started = Date()
        addLog(.info, L.tr("shop.log.importing"))
        do {
            let planTitle = CertPlan.find(current.planID)?.title ?? ""
            let cert = try app.certificateService.saveCertificate(
                p12Data: p12,
                profileData: profile,
                password: payload.password,
                nickname: "XSign · \(planTitle)",
                makeActive: true
            )
            for index in app.certificates.indices { app.certificates[index].inUse = false }
            app.certificates.append(cert)
            app.persist()

            current.importedCertificateID = cert.id
            current.importSeconds = Date().timeIntervalSince(started)
            pending = current
            save()
            importError = nil
            addLog(.success, L.tr("shop.log.imported", cert.nickname))
            Task { await app.refreshAppleRevocation(force: false) }

            if UIApplication.shared.applicationState == .active {
                presentSuccess()
            } else {
                notifyReady(name: cert.nickname)
            }
        } catch {
            importError = error.localizedDescription
            addLog(.error, L.tr("shop.log.importFailed", error.localizedDescription))
        }
    }

    private func presentSuccess() {
        pending?.successShown = true
        save()
        if progressPresented { return }
        showProgress()
    }

    // MARK: - Notificação

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func notifyReady(name: String) {
        let content = UNMutableNotificationContent()
        content.title = L.tr("shop.notify.title")
        content.body = L.tr("shop.notify.body", name)
        content.sound = .default
        content.userInfo = [DownloadNotifier.targetKey: "apps"]
        let request = UNNotificationRequest(identifier: "xsign.certshop.ready", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    // MARK: - Persistência e log

    private func addLog(_ level: SignLogLevel, _ text: String) {
        withAnimation(.xsignSmooth) {
            log.append(SignLogLine(level: level, text: text))
        }
    }

    private func save() {
        if let pending, let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.storeKey)
        }
    }

    private func clearPending() {
        stopPolling()
        pending = nil
        order = nil
        log = []
        importError = nil
        save()
    }
}
