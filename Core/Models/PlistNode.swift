import Foundation

/// Nó editável de uma property list (usado pelo visualizador de entitlements e
/// pelo editor de .plist do gerenciador de arquivos).
final class PlistNode: ObservableObject, Identifiable {
    enum Kind: String, CaseIterable, Identifiable {
        case dictionary, array, string, integer, real, boolean, date, data
        var id: String { rawValue }

        var label: String {
            switch self {
            case .dictionary: return "Dictionary"
            case .array: return "Array"
            case .string: return "String"
            case .integer: return "Number"
            case .real: return "Real"
            case .boolean: return "Boolean"
            case .date: return "Date"
            case .data: return "Data"
            }
        }

        var isContainer: Bool { self == .dictionary || self == .array }
    }

    let id = UUID()
    @Published var key: String
    @Published var kind: Kind
    @Published var string: String = ""
    @Published var integer: Int = 0
    @Published var real: Double = 0
    @Published var boolean: Bool = false
    @Published var date: Date = Date()
    @Published var data: Data = Data()
    @Published var children: [PlistNode] = []

    init(key: String, kind: Kind) {
        self.key = key
        self.kind = kind
    }

    init(key: String, value: Any) {
        self.key = key
        switch value {
        case let dict as [String: Any]:
            kind = .dictionary
            children = dict.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { PlistNode(key: $0, value: dict[$0] as Any) }
        case let array as [Any]:
            kind = .array
            children = array.enumerated().map { PlistNode(key: "\($0.offset)", value: $0.element) }
        case let s as String:
            kind = .string
            string = s
        case let d as Date:
            kind = .date
            date = d
        case let bytes as Data:
            kind = .data
            data = bytes
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                kind = .boolean
                boolean = number.boolValue
            } else if CFNumberIsFloatType(number as CFNumber) {
                kind = .real
                real = number.doubleValue
            } else {
                kind = .integer
                integer = number.intValue
            }
        default:
            kind = .string
            string = String(describing: value)
        }
    }

    /// Converte de volta para tipos de property list.
    func toAny() -> Any {
        switch kind {
        case .dictionary:
            var dict: [String: Any] = [:]
            for child in children { dict[child.key] = child.toAny() }
            return dict
        case .array:
            return children.map { $0.toAny() }
        case .string: return string
        case .integer: return integer
        case .real: return real
        case .boolean: return boolean
        case .date: return date
        case .data: return data
        }
    }

    /// Valor curto para mostrar na linha.
    var summary: String {
        switch kind {
        case .dictionary, .array:
            return "\(children.count)"
        case .string: return string
        case .integer: return "\(integer)"
        case .real: return "\(real)"
        case .boolean: return boolean ? "true" : "false"
        case .date: return date.formatted(date: .abbreviated, time: .shortened)
        case .data:
            let hex = data.prefix(16).map { String(format: "%02x", $0) }.joined()
            return data.count > 16 ? "<\(hex)…> \(data.count) B" : "<\(hex)>"
        }
    }

    /// Reindexa as chaves de um array depois de inserir/remover.
    func renumberIfArray() {
        guard kind == .array else { return }
        for (i, child) in children.enumerated() { child.key = "\(i)" }
    }

    /// Procura por chave ou valor (em qualquer nível).
    func matches(_ query: String) -> Bool {
        if key.localizedCaseInsensitiveContains(query) { return true }
        if !kind.isContainer && summary.localizedCaseInsensitiveContains(query) { return true }
        return children.contains { $0.matches(query) }
    }

    /// XML da árvore inteira (para copiar).
    func xmlString() -> String {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: toAny(), format: .xml, options: 0) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func setKind(_ newKind: Kind) {
        guard newKind != kind else { return }
        kind = newKind
        if !newKind.isContainer { children = [] }
    }
}
