import Foundation

/// Persistência simples: cada coleção vira um JSON em Documents. O blueprint
/// prevê Core Data para produção; para o scaffold, JSON mantém tudo legível e
/// sem dependência de modelo .xcdatamodeld.
actor Store {
    static let shared = Store()

    private let dir: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601; return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("Store", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func load<T: Decodable>(_ type: [T].Type, from name: String) -> [T] {
        let url = dir.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([T].self, from: data)) ?? []
    }

    func save<T: Encodable>(_ value: [T], to name: String) {
        let url = dir.appendingPathComponent("\(name).json")
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Pastas padrão em Documents (espelham o blueprint).
enum Paths {
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let unsigned   = documents.appendingPathComponent("Apps/Unsigned", isDirectory: true)
    static let signed     = documents.appendingPathComponent("Apps/Signed", isDirectory: true)
    static let certs      = documents.appendingPathComponent("Certificates", isDirectory: true)
    static let tweaks     = documents.appendingPathComponent("Tweaks", isDirectory: true)
    static let downloads  = documents.appendingPathComponent("Downloads", isDirectory: true)
    static let sourceCache = documents.appendingPathComponent("Sources/cache", isDirectory: true)

    static func ensure() {
        for u in [unsigned, signed, certs, tweaks, downloads, sourceCache] {
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        }
    }
}
