import SwiftUI

/// Troca de idioma em tempo real, sem reiniciar o app.
///
/// `Text("key")` do SwiftUI usa o bundle principal, que não acompanha a troca
/// em runtime. Por isso usamos `L.tr("key")`, que lê do `.lproj` do idioma
/// escolhido, e recriamos a árvore com `.id(language.code)` na raiz.
///
/// Observação de concorrência: a classe NÃO é `@MainActor` e `L.tr` é uma função
/// livre. Assim ela pode ser chamada de qualquer contexto — inclusive de
/// `errorDescription`, de propriedades de enums e de closures de serviços — sem
/// erro de isolamento de ator. As mutações de `code` vêm sempre da interface
/// (main thread).
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    /// "system" ou um código como "pt-BR", "en", "es".
    @Published var code: String {
        didSet {
            UserDefaults.standard.set(code, forKey: Self.key)
            apply()
        }
    }

    private static let key = "appLanguage"

    /// Todos os idiomas planejados. `shipping` marca os que já têm tradução.
    static let all: [Language] = [
        .init(code: "en", endonym: "English", shipping: true),
        .init(code: "pt-BR", endonym: "Português (Brasil)", shipping: true),
        .init(code: "es", endonym: "Español", shipping: true),
        .init(code: "zh-Hans", endonym: "简体中文", shipping: false),
        .init(code: "zh-Hant", endonym: "繁體中文", shipping: false),
        .init(code: "vi", endonym: "Tiếng Việt", shipping: false),
        .init(code: "ru", endonym: "Русский", shipping: false),
        .init(code: "tr", endonym: "Türkçe", shipping: false),
        .init(code: "ar", endonym: "العربية", shipping: false),
        .init(code: "id", endonym: "Bahasa Indonesia", shipping: false),
        .init(code: "ja", endonym: "日本語", shipping: false),
        .init(code: "ko", endonym: "한국어", shipping: false),
        .init(code: "fr", endonym: "Français", shipping: false),
        .init(code: "de", endonym: "Deutsch", shipping: false),
    ]

    private init() {
        code = UserDefaults.standard.string(forKey: Self.key) ?? "system"
        apply()
    }

    var locale: Locale { code == "system" ? .autoupdatingCurrent : Locale(identifier: resolvedCode) }
    var isRTL: Bool { locale.language.characterDirection == .rightToLeft }

    private var resolvedCode: String { Self.resolve(code) }

    /// Atualiza o cache lido por `L.tr`.
    private func apply() {
        L.bundle = Self.bundle(for: resolvedCode)
        L.locale = locale
    }

    private static func resolve(_ code: String) -> String {
        code == "system" ? (Bundle.main.preferredLocalizations.first ?? "en") : code
    }

    private static func bundle(for code: String) -> Bundle {
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let b = Bundle(path: path) {
            return b
        }
        // tenta a raiz do idioma ("pt-BR" -> "pt") e cai no bundle principal
        if let base = code.split(separator: "-").first,
           let path = Bundle.main.path(forResource: String(base), ofType: "lproj"),
           let b = Bundle(path: path) {
            return b
        }
        return .main
    }
}

struct Language: Identifiable, Hashable {
    var id: String { code }
    let code: String
    let endonym: String       // nome no próprio idioma
    let shipping: Bool
}

/// Atalho global para traduzir. Uso: `L.tr("sign.button")`.
///
/// Função livre (não isolada a ator), para ser chamada de qualquer lugar. O
/// bundle e o locale são atualizados pelo `LocalizationManager` a cada troca.
enum L {
    static var bundle: Bundle = .main
    static var locale: Locale = .autoupdatingCurrent

    static func tr(_ key: String, _ args: CVarArg...) -> String {
        let format = bundle.localizedString(forKey: key, value: key, table: nil)
        return args.isEmpty ? format : String(format: format, locale: locale, arguments: args)
    }
}
