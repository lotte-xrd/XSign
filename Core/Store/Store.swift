import Foundation
import Security

/// Persistência em JSON dentro de Documents/Store.
actor Store {
    static let shared = Store()

    private let dir: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
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

/// Pastas padrão em Documents e utilitários de armazenamento real.
enum Paths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var unsigned: URL   { documents.appendingPathComponent("Apps/Unsigned", isDirectory: true) }
    static var signed: URL     { documents.appendingPathComponent("Apps/Signed", isDirectory: true) }
    static var icons: URL      { documents.appendingPathComponent("Apps/Icons", isDirectory: true) }
    static var certs: URL      { documents.appendingPathComponent("Certificates", isDirectory: true) }
    static var tweaks: URL     { documents.appendingPathComponent("Tweaks", isDirectory: true) }
    static var downloads: URL  { documents.appendingPathComponent("Downloads", isDirectory: true) }
    static var sourceCache: URL { documents.appendingPathComponent("Sources/cache", isDirectory: true) }

    static func ensure() {
        for u in [unsigned, signed, icons, certs, tweaks, downloads, sourceCache] {
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        }
    }

    /// Converte uma URL dentro de Documents num caminho relativo seguro para persistir no JSON.
    static func relative(_ url: URL) -> String {
        let docPath = documents.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        if target.hasPrefix(docPath + "/") {
            return String(target.dropFirst(docPath.count + 1))
        }
        return target
    }

    /// Resolve um caminho salvo (relativo ou absoluto de container antigo) para a URL atual em Documents.
    static func resolve(_ stored: String) -> URL {
        guard !stored.isEmpty else { return documents }
        if !stored.hasPrefix("/") {
            return documents.appendingPathComponent(stored)
        }
        if FileManager.default.fileExists(atPath: stored) {
            return URL(fileURLWithPath: stored)
        }
        if let range = stored.range(of: "/Documents/") {
            let rel = String(stored[range.upperBound...])
            return documents.appendingPathComponent(rel)
        }
        return URL(fileURLWithPath: stored)
    }

    /// Calcula o tamanho real em bytes de uma pasta no dispositivo.
    static func folderSize(_ folder: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               values.isRegularFile == true,
               let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

/// Gerencia o UUID fixo do aparelho (`X-XSign-Device`) e senhas no Keychain do iOS.
enum KeychainHelper {
    private static let service = "com.xsign.app.keychain"
    private static let deviceKey = "xsign.device.uuid"

    /// Identificador único fixo por aparelho, persistido no Keychain para a fila do servidor.
    static var deviceID: String {
        if let existing = read(key: deviceKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        save(key: deviceKey, value: fresh)
        return fresh
    }

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
