import Foundation
import Security
import CommonCrypto
import CryptoKit

// Leitura de .p12 e .mobileprovision sem depender só do `SecPKCS12Import`.
//
// O `SecPKCS12Import` do iOS 17 e anteriores não abre .p12 no formato novo do
// OpenSSL 3 (PBES2 + AES-256 + MAC SHA-256). É o formato de todos os
// certificados que o site entrega hoje, então o XSign dizia "senha incorreta"
// com a senha certa. Aqui a senha é conferida pelo MAC do próprio arquivo
// (RFC 7292) e os certificados públicos saem das "cert bags". A chave privada
// nunca é decifrada no aparelho: quem assina é o servidor.
//
// Este arquivo só usa Foundation, Security, CommonCrypto e CryptoKit, para o
// teste do CI (Tests/CertSmoke) compilar ele sozinho no macOS.

// MARK: - DER/BER

struct ASN1Node {
    let tag: UInt8
    let constructed: Bool
    let bytes: [UInt8]
    let children: [ASN1Node]

    /// OID em texto ("1.2.840.113549.1.7.1").
    var oid: String? {
        guard tag == 0x06, !bytes.isEmpty else { return nil }
        var parts: [UInt64] = []
        var value: UInt64 = 0
        for byte in bytes {
            guard value < (1 << 56) else { return nil }
            value = (value << 7) | UInt64(byte & 0x7F)
            if byte & 0x80 == 0 {
                if parts.isEmpty {
                    let first = min(value / 40, 2)
                    parts.append(first)
                    parts.append(value - first * 40)
                } else {
                    parts.append(value)
                }
                value = 0
            }
        }
        return parts.map(String.init).joined(separator: ".")
    }

    var integerValue: Int? {
        guard tag == 0x02, !bytes.isEmpty, bytes.count <= 8, bytes[0] & 0x80 == 0 else { return nil }
        var value = 0
        for byte in bytes { value = (value << 8) | Int(byte) }
        return value
    }

    /// Conteúdo de um OCTET STRING (ou de um [n] IMPLICIT), inclusive no
    /// formato BER "construído", em que ele vem em pedaços.
    var octetString: [UInt8]? {
        switch tag {
        case 0x04, 0x80:
            return bytes
        case 0x24, 0xA0:
            var out: [UInt8] = []
            for child in children {
                guard let part = child.octetString else { return nil }
                out += part
            }
            return out
        default:
            return nil
        }
    }

    func child(_ index: Int) -> ASN1Node? {
        index < children.count ? children[index] : nil
    }
}

enum ASN1 {
    static func parse(_ data: Data) -> ASN1Node? {
        parse([UInt8](data))
    }

    static func parse(_ bytes: [UInt8]) -> ASN1Node? {
        var index = 0
        return parseNode(bytes, &index, depth: 0)
    }

    private static func parseNode(_ b: [UInt8], _ i: inout Int, depth: Int) -> ASN1Node? {
        guard depth < 48, i < b.count else { return nil }
        let tag = b[i]
        i += 1
        if tag & 0x1F == 0x1F {
            // Tag de vários bytes: não aparece em .p12, só pula.
            while i < b.count, b[i] & 0x80 != 0 { i += 1 }
            i += 1
        }
        guard i < b.count else { return nil }
        let constructed = tag & 0x20 != 0
        var length = Int(b[i])
        i += 1

        if length == 0x80 {
            // Comprimento indefinido (BER): filhos até o marcador 00 00.
            guard constructed else { return nil }
            var kids: [ASN1Node] = []
            while true {
                guard i + 1 < b.count else { return nil }
                if b[i] == 0, b[i + 1] == 0 {
                    i += 2
                    break
                }
                guard let kid = parseNode(b, &i, depth: depth + 1) else { return nil }
                kids.append(kid)
            }
            return ASN1Node(tag: tag, constructed: true, bytes: [], children: kids)
        }
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count >= 1, count <= 4, i + count <= b.count else { return nil }
            length = 0
            for _ in 0..<count {
                length = (length << 8) | Int(b[i])
                i += 1
            }
        }
        guard length >= 0, i + length <= b.count else { return nil }
        let end = i + length
        if constructed {
            var kids: [ASN1Node] = []
            while i < end {
                guard let kid = parseNode(b, &i, depth: depth + 1), i <= end else { return nil }
                kids.append(kid)
            }
            return ASN1Node(tag: tag, constructed: true, bytes: [], children: kids)
        }
        let content = Array(b[i..<end])
        i = end
        return ASN1Node(tag: tag, constructed: false, bytes: content, children: [])
    }
}

private enum OID {
    static let data = "1.2.840.113549.1.7.1"
    static let encryptedData = "1.2.840.113549.1.7.6"
    static let certBag = "1.2.840.113549.1.12.10.1.3"
    static let safeContentsBag = "1.2.840.113549.1.12.10.1.6"
    static let x509Certificate = "1.2.840.113549.1.9.22.1"
    static let localKeyID = "1.2.840.113549.1.9.21"
    static let pbes2 = "1.2.840.113549.1.5.13"
    static let pbkdf2 = "1.2.840.113549.1.5.12"
    static let pkcs12PBEPrefix = "1.2.840.113549.1.12.1."
}

// MARK: - Hash, KDF e cifras

enum PKCS12Hash {
    case sha1, sha224, sha256, sha384, sha512

    /// Algoritmo do MAC (DigestInfo).
    init?(oid: String) {
        switch oid {
        case "1.3.14.3.2.26": self = .sha1
        case "2.16.840.1.101.3.4.2.4": self = .sha224
        case "2.16.840.1.101.3.4.2.1": self = .sha256
        case "2.16.840.1.101.3.4.2.2": self = .sha384
        case "2.16.840.1.101.3.4.2.3": self = .sha512
        default: return nil
        }
    }

    /// PRF do PBKDF2 (hmacWithSHA…).
    init?(hmacOID: String) {
        switch hmacOID {
        case "1.2.840.113549.2.7": self = .sha1
        case "1.2.840.113549.2.8": self = .sha224
        case "1.2.840.113549.2.9": self = .sha256
        case "1.2.840.113549.2.10": self = .sha384
        case "1.2.840.113549.2.11": self = .sha512
        default: return nil
        }
    }

    var outputLength: Int {
        switch self {
        case .sha1: return 20
        case .sha224: return 28
        case .sha256: return 32
        case .sha384: return 48
        case .sha512: return 64
        }
    }

    var blockLength: Int {
        switch self {
        case .sha384, .sha512: return 128
        default: return 64
        }
    }

    func digest(_ input: [UInt8]) -> [UInt8] {
        switch self {
        case .sha1: return Array(Insecure.SHA1.hash(data: input))
        case .sha256: return Array(SHA256.hash(data: input))
        case .sha384: return Array(SHA384.hash(data: input))
        case .sha512: return Array(SHA512.hash(data: input))
        case .sha224:
            var out = [UInt8](repeating: 0, count: 28)
            let count = CC_LONG(input.count)
            _ = CC_SHA224(input, count, &out)
            return out
        }
    }

    private var hmacAlgorithm: CCHmacAlgorithm {
        switch self {
        case .sha1: return CCHmacAlgorithm(kCCHmacAlgSHA1)
        case .sha224: return CCHmacAlgorithm(kCCHmacAlgSHA224)
        case .sha256: return CCHmacAlgorithm(kCCHmacAlgSHA256)
        case .sha384: return CCHmacAlgorithm(kCCHmacAlgSHA384)
        case .sha512: return CCHmacAlgorithm(kCCHmacAlgSHA512)
        }
    }

    var pbkdf2PRF: CCPseudoRandomAlgorithm {
        switch self {
        case .sha1: return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
        case .sha224: return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA224)
        case .sha256: return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
        case .sha384: return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA384)
        case .sha512: return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512)
        }
    }

    func hmac(key: [UInt8], data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: outputLength)
        let keyCount = key.count
        let dataCount = data.count
        CCHmac(hmacAlgorithm, key, keyCount, data, dataCount, &out)
        return out
    }
}

/// Derivação de chave do PKCS#12 (RFC 7292, apêndice B.2).
enum PKCS12KDF {
    static let keyID: UInt8 = 1
    static let ivID: UInt8 = 2
    static let macID: UInt8 = 3

    static func derive(hash: PKCS12Hash, password: [UInt8], salt: [UInt8], id: UInt8, iterations: Int, length: Int) -> [UInt8] {
        let u = hash.outputLength
        let v = hash.blockLength
        let diversifier = [UInt8](repeating: id, count: v)

        func stretch(_ input: [UInt8]) -> [UInt8] {
            guard !input.isEmpty else { return [] }
            let total = v * ((input.count + v - 1) / v)
            return (0..<total).map { input[$0 % input.count] }
        }

        var block = stretch(salt) + stretch(password)
        var result: [UInt8] = []
        while result.count < length {
            var a = hash.digest(diversifier + block)
            if iterations > 1 {
                for _ in 1..<iterations { a = hash.digest(a) }
            }
            result += a
            if result.count >= length || block.isEmpty { break }
            let b = (0..<v).map { a[$0 % u] }
            var j = 0
            while j < block.count {
                var carry: UInt16 = 1
                var k = v - 1
                while k >= 0 {
                    let sum = UInt16(block[j + k]) + UInt16(b[k]) + carry
                    block[j + k] = UInt8(sum & 0xFF)
                    carry = sum >> 8
                    k -= 1
                }
                j += v
            }
        }
        return Array(result.prefix(length))
    }
}

enum PKCS12Cipher {
    /// Decifra um EncryptedContentInfo (algoritmos PKCS#12 antigos ou PBES2).
    static func decrypt(algorithm: ASN1Node, data: [UInt8], password: String) -> [UInt8]? {
        guard algorithm.tag == 0x30, let oid = algorithm.child(0)?.oid, let params = algorithm.child(1) else { return nil }

        if oid.hasPrefix(OID.pkcs12PBEPrefix) {
            guard let salt = params.child(0)?.octetString,
                  let iterations = params.child(1)?.integerValue, iterations > 0, iterations <= 10_000_000,
                  let kind = Int(oid.dropFirst(OID.pkcs12PBEPrefix.count)) else { return nil }
            let spec: (CCAlgorithm, Int, Int)
            switch kind {
            case 1: spec = (CCAlgorithm(kCCAlgorithmRC4), 16, 0)
            case 2: spec = (CCAlgorithm(kCCAlgorithmRC4), 5, 0)
            case 3: spec = (CCAlgorithm(kCCAlgorithm3DES), 24, 8)
            case 4: spec = (CCAlgorithm(kCCAlgorithm3DES), 16, 8)
            case 5: spec = (CCAlgorithm(kCCAlgorithmRC2), 16, 8)
            case 6: spec = (CCAlgorithm(kCCAlgorithmRC2), 5, 8)
            default: return nil
            }
            let (algorithmID, keyLength, ivLength) = spec
            for encoded in PKCS12File.bmpPasswords(password) {
                var key = PKCS12KDF.derive(hash: .sha1, password: encoded, salt: salt, id: PKCS12KDF.keyID,
                                           iterations: iterations, length: keyLength)
                if kind == 4 { key += key.prefix(8) } // 3DES de 2 chaves: K1 K2 K1
                let iv = ivLength > 0
                    ? PKCS12KDF.derive(hash: .sha1, password: encoded, salt: salt, id: PKCS12KDF.ivID,
                                       iterations: iterations, length: ivLength)
                    : []
                if let out = run(algorithmID, key: key, iv: iv, data: data, padded: ivLength > 0), out.first == 0x30 {
                    return out
                }
            }
            return nil
        }

        guard oid == OID.pbes2,
              let kdf = params.child(0), kdf.child(0)?.oid == OID.pbkdf2,
              let kdfParams = kdf.child(1),
              let salt = kdfParams.child(0)?.octetString,
              let iterations = kdfParams.child(1)?.integerValue, iterations > 0, iterations <= 10_000_000,
              let scheme = params.child(1), let schemeOID = scheme.child(0)?.oid,
              let iv = scheme.child(1)?.octetString else { return nil }

        var explicitKeyLength: Int?
        var prf = PKCS12Hash.sha1
        for extra in kdfParams.children.dropFirst(2) {
            if extra.tag == 0x02 {
                explicitKeyLength = extra.integerValue
            } else if extra.tag == 0x30, let prfOID = extra.child(0)?.oid {
                guard let hash = PKCS12Hash(hmacOID: prfOID) else { return nil }
                prf = hash
            }
        }

        let cipher: (CCAlgorithm, Int)
        switch schemeOID {
        case "2.16.840.1.101.3.4.1.2": cipher = (CCAlgorithm(kCCAlgorithmAES), 16)
        case "2.16.840.1.101.3.4.1.22": cipher = (CCAlgorithm(kCCAlgorithmAES), 24)
        case "2.16.840.1.101.3.4.1.42": cipher = (CCAlgorithm(kCCAlgorithmAES), 32)
        case "1.2.840.113549.3.7": cipher = (CCAlgorithm(kCCAlgorithm3DES), 24)
        default: return nil
        }
        let (algorithmID, keyLength) = cipher
        // No PBES2 a senha entra como UTF-8 (não BMP), igual ao OpenSSL.
        guard let key = pbkdf2(password: Array(password.utf8), salt: salt, prf: prf, iterations: iterations,
                               length: explicitKeyLength ?? keyLength),
              let out = run(algorithmID, key: key, iv: iv, data: data, padded: true),
              out.first == 0x30 else { return nil }
        return out
    }

    static func pbkdf2(password: [UInt8], salt: [UInt8], prf: PKCS12Hash, iterations: Int, length: Int) -> [UInt8]? {
        guard length > 0, length <= 64 else { return nil }
        var derived = [UInt8](repeating: 0, count: length)
        let chars = password.map { CChar(bitPattern: $0) }
        let charCount = chars.count
        let saltCount = salt.count
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), chars, charCount, salt, saltCount,
                                          prf.pbkdf2PRF, UInt32(iterations), &derived, length)
        return status == Int32(kCCSuccess) ? derived : nil
    }

    private static func run(_ algorithm: CCAlgorithm, key: [UInt8], iv: [UInt8], data: [UInt8], padded: Bool) -> [UInt8]? {
        guard !data.isEmpty else { return nil }
        var out = [UInt8](repeating: 0, count: data.count + 64)
        let outCount = out.count
        let keyCount = key.count
        let dataCount = data.count
        var moved = 0
        let options = padded ? CCOptions(kCCOptionPKCS7Padding) : CCOptions(0)
        let status = CCCrypt(CCOperation(kCCDecrypt), algorithm, options, key, keyCount, iv,
                             data, dataCount, &out, outCount, &moved)
        guard status == CCCryptorStatus(kCCSuccess) else { return nil }
        return Array(out.prefix(moved))
    }
}

// MARK: - .p12

struct PKCS12File {
    enum PasswordCheck: Equatable { case correct, wrong, unknown }

    private let authSafe: [UInt8]
    private let mac: (hash: PKCS12Hash, digest: [UInt8], salt: [UInt8], iterations: Int)?

    /// `nil` quando os bytes não são um .p12.
    init?(data: Data) {
        guard let root = ASN1.parse(data), root.tag == 0x30,
              root.child(0)?.integerValue != nil,
              let contentInfo = root.child(1), contentInfo.tag == 0x30,
              contentInfo.child(0)?.oid == OID.data,
              let wrapper = contentInfo.child(1), wrapper.tag == 0xA0,
              let octets = wrapper.child(0)?.octetString else { return nil }
        authSafe = octets

        if let macData = root.child(2), macData.tag == 0x30,
           let digestInfo = macData.child(0),
           let algorithmOID = digestInfo.child(0)?.child(0)?.oid,
           let hash = PKCS12Hash(oid: algorithmOID),
           let digest = digestInfo.child(1)?.octetString,
           let salt = macData.child(1)?.octetString {
            let iterations = macData.child(2)?.integerValue ?? 1
            mac = (hash, digest, salt, iterations)
        } else {
            mac = nil
        }
    }

    /// Confere a senha pelo MAC do arquivo. `.unknown` quando o arquivo não tem
    /// MAC ou usa um algoritmo que não conhecemos (aí vale o SecPKCS12Import).
    func checkPassword(_ password: String) -> PasswordCheck {
        guard let mac, mac.iterations > 0, mac.iterations <= 10_000_000 else { return .unknown }
        for encoded in Self.bmpPasswords(password) {
            let key = PKCS12KDF.derive(hash: mac.hash, password: encoded, salt: mac.salt, id: PKCS12KDF.macID,
                                       iterations: mac.iterations, length: mac.hash.outputLength)
            if mac.hash.hmac(key: key, data: authSafe) == mac.digest { return .correct }
        }
        return .wrong
    }

    /// Certificados públicos (DER). O que tem a chave privada vem primeiro.
    func certificates(password: String) -> [Data] {
        guard let safe = ASN1.parse(authSafe), safe.tag == 0x30 else { return [] }
        var withKey: [Data] = []
        var others: [Data] = []
        for info in safe.children where info.tag == 0x30 {
            guard let type = info.child(0)?.oid,
                  let wrapper = info.child(1), wrapper.tag == 0xA0,
                  let content = wrapper.child(0) else { continue }
            var contents: [UInt8]?
            if type == OID.data {
                contents = content.octetString
            } else if type == OID.encryptedData,
                      let encryptedInfo = content.child(1),
                      let algorithm = encryptedInfo.child(1),
                      let encrypted = encryptedInfo.child(2)?.octetString {
                contents = PKCS12Cipher.decrypt(algorithm: algorithm, data: encrypted, password: password)
            }
            if let contents, let node = ASN1.parse(contents) {
                collect(node, depth: 0, withKey: &withKey, others: &others)
            }
        }
        return withKey + others
    }

    private func collect(_ safeContents: ASN1Node, depth: Int, withKey: inout [Data], others: inout [Data]) {
        guard depth < 4, safeContents.tag == 0x30 else { return }
        for bag in safeContents.children where bag.tag == 0x30 {
            guard let bagID = bag.child(0)?.oid,
                  let wrapper = bag.child(1), wrapper.tag == 0xA0,
                  let value = wrapper.child(0) else { continue }
            if bagID == OID.certBag {
                guard value.child(0)?.oid == OID.x509Certificate,
                      let certWrapper = value.child(1), certWrapper.tag == 0xA0,
                      let der = certWrapper.child(0)?.octetString, !der.isEmpty else { continue }
                let hasKey = bag.child(2).map { attributes in
                    attributes.children.contains { $0.child(0)?.oid == OID.localKeyID }
                } ?? false
                if hasKey { withKey.append(Data(der)) } else { others.append(Data(der)) }
            } else if bagID == OID.safeContentsBag {
                collect(value, depth: depth + 1, withKey: &withKey, others: &others)
            }
        }
    }

    /// Senha em BMPString (UTF-16 big-endian com 00 00 no fim). Senha vazia é
    /// testada nas duas formas que os geradores usam.
    static func bmpPasswords(_ password: String) -> [[UInt8]] {
        if password.isEmpty { return [[0, 0], []] }
        var out: [UInt8] = []
        for unit in password.utf16 {
            out.append(UInt8(unit >> 8))
            out.append(UInt8(unit & 0xFF))
        }
        out += [0, 0]
        return [out]
    }
}

// MARK: - .mobileprovision

struct ProvisioningProfileInfo {
    var uuid: String?
    var name: String?
    var teamID: String
    var teamName: String?
    var appID: String?
    var type: String
    var issuedAt: Date?
    var expiresAt: Date?
    var devices: [String]
    var entitlementsCount: Int
    /// Certificados públicos (DER) que o perfil aceita.
    var certificates: [Data]

    static func read(_ data: Data) -> ProvisioningProfileInfo? {
        guard let dict = plist(from: data),
              dict["TeamIdentifier"] != nil || dict["Entitlements"] != nil || dict["DeveloperCertificates"] != nil
        else { return nil }

        let entitlements = dict["Entitlements"] as? [String: Any]
        let appID = entitlements?["application-identifier"] as? String
        let teamID = (dict["TeamIdentifier"] as? [String])?.first
            ?? appID?.split(separator: ".").first.map(String.init) ?? "—"
        let type = (dict["ProvisionsAllDevices"] as? Bool == true) ? "In-House (Enterprise)"
            : (dict["ProvisionedDevices"] != nil ? "Apple Development / Ad-Hoc" : "App Store Distribution")

        return ProvisioningProfileInfo(
            uuid: (dict["UUID"] as? String)?.uppercased(),
            name: dict["Name"] as? String,
            teamID: teamID,
            teamName: dict["TeamName"] as? String,
            appID: appID,
            type: type,
            issuedAt: dict["CreationDate"] as? Date,
            expiresAt: dict["ExpirationDate"] as? Date,
            devices: dict["ProvisionedDevices"] as? [String] ?? [],
            entitlementsCount: entitlements?.count ?? 0,
            certificates: dict["DeveloperCertificates"] as? [Data] ?? []
        )
    }

    /// O plist XML que vem dentro do envelope CMS do perfil.
    static func plist(from data: Data) -> [String: Any]? {
        guard let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>", range: start.upperBound..<text.endIndex),
              let xml = text[start.lowerBound..<end.upperBound].data(using: .isoLatin1)
        else { return nil }
        return (try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil)) as? [String: Any]
    }
}

// MARK: - Separar os arquivos e achar a senha

/// Um arquivo encontrado na importação: solto, numa pasta ou dentro de um .zip.
struct CertificateFileEntry {
    var name: String
    var data: Data
}

/// O que foi encontrado nos arquivos escolhidos.
struct CertificateScanResult {
    var p12Data: Data?
    var p12Name: String?
    var profileData: Data?
    var profileName: String?
    var profile: ProvisioningProfileInfo?
    var passwordHints: [String] = []
    /// Senha do .p12 já conferida.
    var foundPassword: String?
    /// `false`: o .p12 e o perfil são de certificados diferentes. `nil`: não deu para saber.
    var pairMatches: Bool?
    /// O .p12 escolhido não abriu como .p12 nenhum.
    var p12Unreadable = false

    var isComplete: Bool { p12Data != nil && profileData != nil }
}

enum CertificateScanner {
    /// Senhas comuns de quem vende certificado, testadas depois das que vierem nos arquivos.
    static let commonPasswords = ["1", "", "1234", "123456", "123", "0000", "12345678", "password", "apple", "NexCerts"]

    static func scan(_ entries: [CertificateFileEntry]) -> CertificateScanResult {
        var p12s: [(name: String, data: Data)] = []
        var profiles: [(name: String, data: Data, info: ProvisioningProfileInfo)] = []
        var strong: [String] = []
        var weak: [String] = []

        for entry in entries {
            let base = (entry.name as NSString).lastPathComponent
            let lower = base.lowercased()
            if entry.name.lowercased().contains("__macosx") || base.hasPrefix("._") || lower == ".ds_store" { continue }
            let ext = (lower as NSString).pathExtension

            if ext == "p12" || ext == "pfx" {
                if !p12s.contains(where: { $0.data == entry.data }) { p12s.append((base, entry.data)) }
            } else if ext == "mobileprovision" || ext == "provisionprofile" {
                if let info = ProvisioningProfileInfo.read(entry.data), !profiles.contains(where: { $0.data == entry.data }) {
                    profiles.append((base, entry.data, info))
                }
            } else {
                // Outra extensão (ou nenhuma): pode ser um .p12/.mobileprovision renomeado.
                let textLike = ["txt", "json", "plist", "md", "rtf", "text", ""].contains(ext)
                let mayBeDER = entry.data.first == 0x30 && entry.data.count <= 4 * 1024 * 1024
                if mayBeDER, PKCS12File(data: entry.data) != nil {
                    if !p12s.contains(where: { $0.data == entry.data }) { p12s.append((base, entry.data)) }
                } else if mayBeDER, let info = ProvisioningProfileInfo.read(entry.data) {
                    if !profiles.contains(where: { $0.data == entry.data }) { profiles.append((base, entry.data, info)) }
                } else if textLike, entry.data.count <= 256 * 1024 {
                    let hints = passwordHints(from: entry.data)
                    strong.append(contentsOf: hints.strong)
                    weak.append(contentsOf: hints.weak)
                }
            }
        }

        var seen = Set<String>()
        let candidates = (strong + weak + commonPasswords).filter { seen.insert($0).inserted }.prefix(64).map { $0 }

        var result = CertificateScanResult()
        result.passwordHints = candidates

        // Cada .p12: senha (entre as candidatas) e certificados públicos.
        let p12Infos: [(name: String, data: Data, password: String?, certificates: [Data], readable: Bool)] = p12s.map { p12 in
            let file = PKCS12File(data: p12.data)
            let password = candidates.first { quickPasswordCheck(p12.data, file: file, password: $0) }
            let certificates = password.map { certificatesOf(p12.data, file: file, password: $0) } ?? []
            return (p12.name, p12.data, password, certificates, file != nil || password != nil)
        }

        var chosenP12 = p12Infos.first(where: { $0.password != nil }) ?? p12Infos.first
        var chosenProfile = profiles.first
        var matched = false
        search: for p12 in p12Infos where !p12.certificates.isEmpty {
            for profile in profiles where !profile.info.certificates.isEmpty {
                if p12.certificates.contains(where: { profile.info.certificates.contains($0) }) {
                    chosenP12 = p12
                    chosenProfile = profile
                    matched = true
                    break search
                }
            }
        }

        if let p12 = chosenP12 {
            result.p12Data = p12.data
            result.p12Name = p12.name
            result.foundPassword = p12.password
            result.p12Unreadable = !p12.readable
        }
        if let profile = chosenProfile {
            result.profileData = profile.data
            result.profileName = profile.name
            result.profile = profile.info
        }
        if matched {
            result.pairMatches = true
        } else if let p12 = chosenP12, let profile = chosenProfile,
                  !p12.certificates.isEmpty, !profile.info.certificates.isEmpty {
            result.pairMatches = false
        }
        return result
    }

    /// Confere a senha: pelo MAC quando o arquivo tem um que conhecemos, senão
    /// pelo SecPKCS12Import. Rápido o bastante para testar várias candidatas.
    static func quickPasswordCheck(_ data: Data, file: PKCS12File?, password: String) -> Bool {
        switch file?.checkPassword(password) ?? .unknown {
        case .correct: return true
        case .wrong: return false
        case .unknown: return appleAccepts(data, password: password)
        }
    }

    /// Confere uma senha só (a que o usuário digitou). Se o MAC disser que não,
    /// ainda pergunta ao SecPKCS12Import, por garantia.
    static func validate(_ data: Data, password: String) -> Bool {
        let file = PKCS12File(data: data)
        if file?.checkPassword(password) == .correct { return true }
        return appleAccepts(data, password: password)
    }

    /// Certificados públicos do .p12 (DER), o da chave primeiro.
    static func certificates(of data: Data, password: String) -> [Data] {
        certificatesOf(data, file: PKCS12File(data: data), password: password)
    }

    /// `false` quando dá para afirmar que o .p12 não é do perfil; `nil` quando não dá para saber.
    static func p12(_ data: Data, password: String, matchesProfile profile: ProvisioningProfileInfo) -> Bool? {
        let fromP12 = certificates(of: data, password: password)
        guard !fromP12.isEmpty, !profile.certificates.isEmpty else { return nil }
        return fromP12.contains { profile.certificates.contains($0) }
    }

    private static func certificatesOf(_ data: Data, file: PKCS12File?, password: String) -> [Data] {
        if let file {
            let found = file.certificates(password: password)
            if !found.isEmpty { return found }
        }
        guard let identity = appleIdentity(data, password: password) else { return [] }
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return [] }
        return [SecCertificateCopyData(certificate) as Data]
    }

    static func appleAccepts(_ data: Data, password: String) -> Bool {
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var items: CFArray?
        return SecPKCS12Import(data as CFData, options as CFDictionary, &items) == errSecSuccess
    }

    private static func appleIdentity(_ data: Data, password: String) -> SecIdentity? {
        let options: [String: Any] = [kSecImportExportPassphrase as String: password]
        var items: CFArray?
        guard SecPKCS12Import(data as CFData, options as CFDictionary, &items) == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] else { return nil }
        return (identity as! SecIdentity)
    }

    /// Possíveis senhas num arquivo de texto/JSON/plist. `strong` = valores de chaves
    /// com nome de senha; `weak` = demais linhas/valores curtos.
    static func passwordHints(from data: Data) -> (strong: [String], weak: [String]) {
        var strong: [String] = []
        var weak: [String] = []
        let passwordWords = ["pass", "pwd", "senha", "contrase", "clave", "密码", "mật khẩu", "mat khau"]

        func isPasswordKey(_ key: String) -> Bool {
            let lower = key.lowercased()
            return passwordWords.contains { lower.contains($0) }
        }

        func walk(_ value: Any, key: String?) {
            if let dict = value as? [String: Any] {
                for (k, v) in dict { walk(v, key: k) }
            } else if let array = value as? [Any] {
                for v in array { walk(v, key: key) }
            } else if let s = value as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count <= 64 else { return }
                if let key, isPasswordKey(key) { strong.append(trimmed) } else if !trimmed.isEmpty { weak.append(trimmed) }
            } else if let n = value as? NSNumber, let key, isPasswordKey(key) {
                strong.append(n.stringValue)
            }
        }

        // Só JSON de verdade (objeto ou lista): um .txt com "1234" também é JSON válido.
        if let json = try? JSONSerialization.jsonObject(with: data, options: []), json is [String: Any] || json is [Any] {
            walk(json, key: nil)
            return (strong, weak)
        }
        if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           !(plist is String) {
            walk(plist, key: nil)
            return (strong, weak)
        }

        var text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1) ?? ""
        text = text.replacingOccurrences(of: "\u{FEFF}", with: "")
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, line.count <= 160 else { continue }
            // "Senha do certificado (P12) / Password: 1", "密码：1", "pass = 1"
            if let separator = line.firstIndex(where: { $0 == ":" || $0 == "=" || $0 == "：" }) {
                let key = String(line[..<separator])
                let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty && value.count <= 64 {
                    if isPasswordKey(key) { strong.append(value) } else { weak.append(value) }
                }
            }
            if line.count <= 64 { weak.append(line) }
        }
        return (strong, weak)
    }
}
