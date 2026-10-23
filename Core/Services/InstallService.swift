import Foundation

/// Instalação de um `.ipa` assinado via `itms-services`.
///
/// O iOS só instala fora da App Store por `itms-services`, que exige um
/// `manifest.plist` servido por HTTPS com certificado TLS confiável. A
/// implementação de produção sobe um servidor HTTPS local (Swifter/FlyingFox)
/// em 127.0.0.1, publica o `.ipa`, o manifest e o ícone, e abre a URL
/// `itms-services://`. Usar `beginBackgroundTask` para o servidor não morrer
/// antes de o download terminar.
protocol InstallService {
    func install(ipaPath: String, bundleID: String, version: String, title: String) async throws
}

struct LocalServerInstallService: InstallService {
    func install(ipaPath: String, bundleID: String, version: String, title: String) async throws {
        // TODO (macOS):
        // 1. iniciar o servidor HTTPS local com o certificado TLS embutido;
        // 2. servir /app.ipa e /manifest.plist (ver ManifestBuilder);
        // 3. abrir itms-services://?action=download-manifest&url=https://.../manifest.plist
        throw NSError(domain: "XSign.Install", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "LocalServerInstallService não implementado neste scaffold."])
    }
}

/// Monta o manifest.plist exigido pelo itms-services.
enum ManifestBuilder {
    static func make(ipaURL: String, bundleID: String, version: String, title: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>items</key><array><dict>
            <key>assets</key><array><dict>
              <key>kind</key><string>software-package</string>
              <key>url</key><string>\(ipaURL)</string>
            </dict></array>
            <key>metadata</key><dict>
              <key>bundle-identifier</key><string>\(bundleID)</string>
              <key>bundle-version</key><string>\(version)</string>
              <key>kind</key><string>software</string>
              <key>title</key><string>\(title)</string>
            </dict>
          </dict></array>
        </dict></plist>
        """
    }
}
