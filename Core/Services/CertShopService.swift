import Foundation
import UIKit
import Security

// MARK: - Planos (os mesmos pacotes do site exploiting-ios.online)

/// Plano de certificado vendido dentro do app. Preços e regras iguais aos do
/// site; o servidor confere tudo de novo antes de cobrar.
struct CertPlan: Identifiable, Hashable {
    let id: String
    let priceBrl: Int
    let priceUsd: Int
    let popular: Bool
    /// Dias de garantia; `nil` = sem garantia.
    let warrantyDays: Int?
    let allIOS: Bool
    let jit: Bool

    static let all: [CertPlan] = [
        CertPlan(id: "random", priceBrl: 40, priceUsd: 8, popular: false, warrantyDays: nil, allIOS: false, jit: false),
        CertPlan(id: "instant", priceBrl: 60, priceUsd: 12, popular: false, warrantyDays: nil, allIOS: false, jit: false),
        CertPlan(id: "instant40", priceBrl: 99, priceUsd: 20, popular: false, warrantyDays: 40, allIOS: true, jit: true),
        CertPlan(id: "instant300", priceBrl: 125, priceUsd: 25, popular: true, warrantyDays: 300, allIOS: true, jit: true),
    ]

    static let defaultID = "instant300"

    static func find(_ id: String) -> CertPlan? { all.first { $0.id == id } }

    static var cheapest: CertPlan { all.min { $0.priceBrl < $1.priceBrl } ?? all[0] }

    var title: String { L.tr("shop.plan.\(id).title") }
    var subtitle: String { L.tr("shop.plan.\(id).subtitle") }
    var price: String { CertShop.formatPrice(brl: priceBrl, usd: priceUsd) }
    /// Todos os planos valem 12 meses.
    var validityText: String { L.tr("shop.validity.12m") }
    var warrantyText: String {
        warrantyDays.map { L.tr("shop.warranty.days", $0) } ?? L.tr("shop.warranty.none")
    }

    struct Chip: Hashable {
        let text: String
        let warning: Bool
    }

    var chips: [Chip] {
        [
            Chip(text: L.tr("shop.chip.12m"), warning: false),
            Chip(text: warrantyDays.map { L.tr("shop.chip.warranty", $0) } ?? L.tr("shop.chip.noWarranty"), warning: warrantyDays == nil),
            Chip(text: allIOS ? L.tr("shop.chip.allIOS") : L.tr("shop.chip.ios16"), warning: !allIOS),
            Chip(text: jit ? L.tr("shop.chip.jit") : L.tr("shop.chip.noJit"), warning: !jit),
        ]
    }
}

enum CertShop {
    /// "pt", "en" ou "es": idioma das páginas de pagamento e de UDID.
    static var lang: String {
        let value = L.tr("shop.lang")
        return ["pt", "en", "es"].contains(value) ? value : "en"
    }

    /// Em português o preço aparece em reais (Pix); nos outros idiomas, em dólar (cartão).
    static var usesBRL: Bool { lang == "pt" }

    static func formatPrice(brl: Int, usd: Int) -> String {
        usesBRL ? "R$ \(brl),00" : "US$ \(usd).00"
    }
}

// MARK: - Pedido

struct CertOrder: Codable, Equatable {
    var id: String
    var planId: String
    var packageName: String?
    var udid: String
    var status: String
    var method: String?
    var priceBrl: Int?
    var priceUsd: Int?
    var totalPix: String?
    var totalCard: String?
    var paidAmount: String?
    var error: String?
    var upstreamMessage: String?
    var createdAt: String?
    var paidAt: String?
    var issuedAt: String?
    var readyAt: String?

    /// Mesmo número que a página de pagamento mostra.
    var number: String { String(id.prefix(8)).uppercased() }

    var isAwaitingPayment: Bool { status == "awaiting_payment" }
    var isExpired: Bool { status == "expired" }
    var isReady: Bool { status == "ready" }
    var isFailed: Bool { status == "failed" }
    /// Pago (mesmo que a emissão tenha falhado e precise tentar de novo).
    var isPaid: Bool {
        ["paid", "issuing", "pending", "ready"].contains(status) || (isFailed && paidAt != nil)
    }

    var paidDate: Date? { paidAt.flatMap(CertShop.parseDate) }

    /// "Pix · R$ 126,25" ou "Cartão · US$ 26.67".
    var paymentSummary: String? {
        guard let method else { return nil }
        let label = method == "pix" ? "Pix" : L.tr("shop.method.card")
        return [label, paidAmount].compactMap { $0 }.joined(separator: " · ")
    }
}

extension CertShop {
    static func parseDate(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

struct CertificatePayload: Codable, Equatable {
    var p12: String
    var mobileprovision: String
    var password: String
}

struct CertOrderResponse: Codable {
    var order: CertOrder
    var certificate: CertificatePayload?
}

struct CertOrderCreated: Codable {
    var order: CertOrder
    var token: String
    var checkoutUrl: String
}

struct FoundUDID: Codable {
    var udid: String
    var product: String?
    var version: String?
}

// MARK: - API do servidor (server/xsignStore.js)

struct CertShopAPI {
    let baseURL: URL

    struct APIError: LocalizedError {
        let message: String
        var status: Int = 0
        var errorDescription: String? { message }
    }

    /// Mesmo servidor da assinatura (Ajustes › Servidor).
    static func current() -> CertShopAPI {
        let raw = (UserDefaults.standard.string(forKey: "xsign.serverURL") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let fallback = URL(string: "https://exploiting-ios.online")!
        guard !raw.isEmpty, let url = URL(string: raw), url.scheme != nil else {
            return CertShopAPI(baseURL: fallback)
        }
        return CertShopAPI(baseURL: url)
    }

    func createOrder(planID: String, udid: String, email: String) async throws -> CertOrderCreated {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let body: [String: Any] = ["planId": planID, "udid": udid, "email": email, "lang": CertShop.lang, "appVersion": version]
        return try await send(request("api/xsign/store/orders", method: "POST", body: body), as: CertOrderCreated.self)
    }

    func order(token: String) async throws -> CertOrderResponse {
        try await send(request("api/xsign/store/orders/\(token)"), as: CertOrderResponse.self)
    }

    /// Pedido pago cuja emissão falhou: tenta de novo sem cobrar outra vez.
    func retry(token: String) async throws -> CertOrderResponse {
        try await send(request("api/xsign/store/orders/\(token)/retry", method: "POST", body: [:]), as: CertOrderResponse.self)
    }

    /// UDID enviado pelo perfil de descoberta; `nil` enquanto o iPhone não mandou.
    func foundUDID(session: String) async throws -> FoundUDID? {
        do {
            return try await send(request("api/xsign/udid/\(session)"), as: FoundUDID.self)
        } catch let error as APIError where error.status == 404 {
            return nil
        }
    }

    /// Perfil "Profile Service" aberto direto no Safari: o iOS já pergunta se
    /// pode baixar, sem passar pela página de instruções. Depois de instalado,
    /// o Safari volta para a página do UDID, que abre o XSign sozinha.
    func udidProfileURL(session: String) -> URL {
        baseURL.appendingPathComponent("xsign/udid/\(session)/perfil.mobileconfig")
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 30
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(KeychainHelper.deviceID, forHTTPHeaderField: "X-XSign-Device")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw APIError(message: L.tr("shop.error.network"))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let serverMessage = json?["error"] as? String
            let message: String
            switch status {
            case 429: message = L.tr("shop.error.tooMany")
            case 502, 503, 504: message = serverMessage ?? L.tr("shop.error.unavailable")
            default: message = serverMessage ?? L.tr("shop.error.server", status)
            }
            throw APIError(message: message, status: status)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError(message: L.tr("shop.error.response"), status: status)
        }
    }
}

// MARK: - E-mail do cliente

/// E-mail pedido na compra: vai para o recibo do Mercado Pago ou do Stripe e
/// para o aviso de venda. Fica salvo para a próxima compra.
enum CustomerEmail {
    private static let key = "xsign.certshop.email"

    static func normalize(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count <= 254,
              value.range(of: #"^[^\s@"'<>]+@[^\s@"'<>]+\.[a-z]{2,}$"#, options: .regularExpression) != nil
        else { return nil }
        return value
    }

    static var saved: String { UserDefaults.standard.string(forKey: key) ?? "" }

    static func remember(_ email: String) {
        UserDefaults.standard.set(email, forKey: key)
    }
}

// MARK: - UDID deste iPhone

/// O iOS não deixa um app ler o UDID. Ele vem do perfil que instalou o XSign
/// (quando é de um único aparelho, só pode ser este), do UDID já confirmado
/// antes neste iPhone, de um certificado importado com um único aparelho, do
/// perfil de descoberta pelo Safari ou do próprio usuário.
enum UDIDSource: String, Codable {
    case none, embedded, saved, certificate, profile, manual
}

enum DeviceUDID {
    static func normalize(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        func isHex<S: StringProtocol>(_ s: S) -> Bool { !s.isEmpty && s.unicodeScalars.allSatisfy { hex.contains($0) } }

        if value.count == 24, isHex(value) {
            value = String(value.prefix(8)) + "-" + String(value.dropFirst(8))
        }
        if value.count == 40, isHex(value) { return value.lowercased() }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count == 2, parts[0].count == 8, parts[1].count == 16, isHex(parts[0]), isHex(parts[1]) {
            return value.uppercased()
        }
        return nil
    }

    /// UDID do perfil embutido no XSign, quando ele é de um único aparelho.
    static func fromEmbeddedProfile() -> String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let info = try? CertificateService().readProfile(data: data),
              info.devices.count == 1 else { return nil }
        return normalize(info.devices[0])
    }

    private static let savedKey = "xsign.device.udid"

    /// UDID já confirmado neste iPhone (perfil embutido ou perfil de descoberta).
    static var saved: String? {
        KeychainHelper.read(key: savedKey).flatMap(normalize)
    }

    /// Guarda o UDID confirmado no Keychain, só deste aparelho (não vai para
    /// backups restaurados em outro iPhone), para não pedir de novo.
    static func remember(_ udid: String) {
        guard let value = normalize(udid), value != saved else { return }
        KeychainHelper.save(key: savedKey, value: value, thisDeviceOnly: true)
    }

    /// UDID de um certificado importado que vale para um único aparelho.
    static func fromCertificates(_ certificates: [Certificate]) -> (udid: String, name: String)? {
        let single = certificates
            .filter { $0.devices.count == 1 }
            .sorted { ($0.inUse ? 0 : 1) < ($1.inUse ? 0 : 1) }
        guard let cert = single.first, let udid = normalize(cert.devices[0]) else { return nil }
        return (udid, cert.nickname)
    }

    /// "iPhone · iOS 18.1"
    @MainActor static var deviceLabel: String {
        "\(UIDevice.current.model) · iOS \(UIDevice.current.systemVersion)"
    }

    static func newSessionID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
