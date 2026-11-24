import Foundation

// Teste do leitor de certificados (Core/Services/CertificateFiles.swift).
// Uso: certsmoke <pasta gerada por make_fixtures.sh>

let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
var failures = 0

func check(_ ok: Bool, _ label: String) {
    print((ok ? "OK     " : "FALHOU ") + label)
    if !ok { failures += 1 }
}

func file(_ name: String) -> Data {
    guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else {
        print("FALHOU arquivo de teste ausente: \(name)")
        exit(2)
    }
    return data
}

func text(_ value: String) -> Data { Data(value.utf8) }

let leaf = file("leaf.der")

// 1. Senha e certificados em cada formato de .p12
let formats: [(name: String, password: String)] = [
    ("modern.p12", "1"),          // OpenSSL 3 padrão (PBES2 / AES-256 / MAC SHA-256): o formato do site
    ("legacy.p12", "1"),          // OpenSSL -legacy (RC2-40 + 3DES / MAC SHA-1)
    ("libressl.p12", "1"),        // LibreSSL do macOS (formato antigo)
    ("des3.p12", "abc"),          // 3DES nos dois lados
    ("aes128-sha512.p12", "segredo"),
    ("empty.p12", ""),            // sem senha
    ("unicode.p12", "senhá123"),  // senha com acento
    ("chain.p12", "1"),           // com a cadeia (AC + certificado)
    ("ber.p12", "1"),             // BER: comprimentos indefinidos, como no Windows/Java
]

for format in formats {
    let data = file(format.name)
    guard let p12 = PKCS12File(data: data) else {
        check(false, "\(format.name): abre como .p12")
        continue
    }
    check(p12.checkPassword(format.password) == .correct, "\(format.name): senha certa confere")
    check(p12.checkPassword(format.password + "x") == .wrong, "\(format.name): senha errada é recusada")
    check(p12.checkPassword("1234") != .correct || format.password == "1234", "\(format.name): outra senha não confere")
    let certificates = p12.certificates(password: format.password)
    check(certificates.first == leaf, "\(format.name): o certificado da chave sai primeiro (\(certificates.count) no arquivo)")
    check(CertificateScanner.validate(data, password: format.password), "\(format.name): validate aceita")
    check(!CertificateScanner.validate(data, password: format.password + "x"), "\(format.name): validate recusa a errada")
    print("       (SecPKCS12Import deste macOS: \(CertificateScanner.appleAccepts(data, password: format.password) ? "abre" : "não abre"))")
}

let chain = PKCS12File(data: file("chain.p12"))?.certificates(password: "1") ?? []
check(chain.count == 2, "chain.p12: traz os dois certificados")

// .p12 sem MAC: não dá para conferir a senha pelo MAC, mas os certificados saem.
if let noMac = PKCS12File(data: file("nomac.p12")) {
    check(noMac.checkPassword("1") == .unknown, "nomac.p12: sem MAC fica 'não sei'")
    check(noMac.certificates(password: "1").first == leaf, "nomac.p12: certificado sai mesmo assim")
} else {
    check(false, "nomac.p12: abre como .p12")
}

// Arquivos que não são .p12
check(PKCS12File(data: leaf) == nil, "um .cer não é tratado como .p12")
check(PKCS12File(data: text("isto não é um certificado")) == nil, "texto não é .p12")
check(PKCS12File(data: Data([0x30, 0x80, 0x02])) == nil, "DER cortado não trava")

// 2. Perfil
let profileData = file("profile.mobileprovision")
if let profile = ProvisioningProfileInfo.read(profileData) {
    check(profile.uuid == "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0", "perfil: UUID")
    check(profile.teamID == "ABCDE12345", "perfil: Team ID")
    check(profile.teamName == "Teste Ltda", "perfil: nome do time")
    check(profile.certificates == [leaf], "perfil: certificado do desenvolvedor")
    check(profile.type == "In-House (Enterprise)", "perfil: tipo")
    check(CertificateScanner.p12(file("modern.p12"), password: "1", matchesProfile: profile) == true, "modern.p12 combina com o perfil")
    check(CertificateScanner.p12(file("other.p12"), password: "1", matchesProfile: profile) == false, "other.p12 não combina com o perfil")
} else {
    check(false, "perfil: abre")
}
check(ProvisioningProfileInfo.read(text("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>password</key><string>1</string></dict></plist>")) == nil,
      "um .plist qualquer não vira perfil")

// 3. Achar o par e a senha nos arquivos escolhidos
func scan(_ entries: [(String, Data)]) -> CertificateScanResult {
    CertificateScanner.scan(entries.map { CertificateFileEntry(name: $0.0, data: $0.1) })
}

var result = scan([
    ("certificate.p12", file("modern.p12")),
    ("profile.mobileprovision", profileData),
    ("SENHA-PASSWORD.txt", text("Senha do certificado (P12) / Certificate (P12) password: 1\r\nUDID: 00008030-001A2B3C4D5E6F7A\r\n")),
])
check(result.isComplete && result.foundPassword == "1" && result.pairMatches == true, "zip do site: par completo, senha 1")

result = scan([
    ("pkg/cert.p12", file("des3.p12")),
    ("pkg/embedded.mobileprovision", profileData),
    ("pkg/密码.txt", text("密码：abc\n")),
])
check(result.foundPassword == "abc" && result.pairMatches == true, "senha no .txt em chinês (密码：abc)")

result = scan([
    ("a.p12", file("aes128-sha512.p12")),
    ("a.mobileprovision", profileData),
    ("info.json", text("{\"certificate\": {\"password\": \"segredo\", \"udid\": \"x\"}}")),
])
check(result.foundPassword == "segredo", "senha num .json")

result = scan([
    ("a.p12", file("aes128-sha512.p12")),
    ("a.mobileprovision", profileData),
    ("senha.txt", text("segredo")),
])
check(result.foundPassword == "segredo", "senha sozinha num .txt")

result = scan([
    ("a.p12", file("unicode.p12")),
    ("a.mobileprovision", profileData),
    ("pass.txt", text("\u{FEFF}Password = senhá123\r\n")),
])
check(result.foundPassword == "senhá123", "senha com acento e BOM")

result = scan([
    ("a.p12", file("des3.p12")),
    ("a.mobileprovision", profileData),
    ("leia.txt", text("987654")),
])
check(result.foundPassword == nil && result.isComplete, "senha desconhecida: pede para digitar")

result = scan([("a.p12", file("empty.p12")), ("a.mobileprovision", profileData)])
check(result.foundPassword == "", "sem senha: acha a senha vazia")

result = scan([
    ("errado.p12", file("other.p12")),
    ("certo.p12", file("modern.p12")),
    ("outro.mobileprovision", file("other.mobileprovision")),
    ("perfil.mobileprovision", profileData),
])
check(result.p12Name == "errado.p12" && result.profileName == "outro.mobileprovision" && result.pairMatches == true
      || result.p12Name == "certo.p12" && result.profileName == "perfil.mobileprovision" && result.pairMatches == true,
      "dois pares misturados: escolhe um par que combina (\(result.p12Name ?? "-") + \(result.profileName ?? "-"))")

result = scan([("cert.p12", file("other.p12")), ("perfil.mobileprovision", profileData)])
check(result.pairMatches == false, "par trocado é detectado")

result = scan([("arquivo1", file("modern.p12")), ("arquivo2", profileData)])
check(result.isComplete && result.foundPassword == "1", "arquivos sem extensão são reconhecidos")

result = scan([
    ("__MACOSX/._certificate.p12", Data([0x00, 0x05, 0x16, 0x07])),
    ("certificate.p12", file("ber.p12")),
    ("profile.mobileprovision", profileData),
    (".DS_Store", Data([0, 0, 0, 1])),
])
check(result.isComplete && result.foundPassword == "1", "ignora __MACOSX e .DS_Store")

result = scan([("profile.mobileprovision", profileData)])
check(result.p12Data == nil && result.profileData != nil, "só o perfil: falta o .p12")

print(failures == 0 ? "\nTudo certo." : "\n\(failures) verificação(ões) falharam.")
exit(failures == 0 ? 0 : 1)
