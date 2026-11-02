import Foundation
import UIKit

/// Instalação de um `.ipa` assinado via `itms-services://` servido por `https://exploiting-ios.online`.
protocol InstallService {
    func install(ipaPath: String, bundleID: String, version: String, title: String) async throws
    func openInstallURL(_ installURLString: String) async throws
}

struct OTAInstallService: InstallService {
    func install(ipaPath: String, bundleID: String, version: String, title: String) async throws {
        if ipaPath.hasPrefix("itms-services://") || ipaPath.hasPrefix("https://") {
            try await openInstallURL(ipaPath)
            return
        }
        throw NSError(
            domain: "XSign.Install",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Assine o aplicativo primeiro para gerar o link de instalação OTA."]
        )
    }

    func openInstallURL(_ installURLString: String) async throws {
        guard let url = URL(string: installURLString) else {
            throw NSError(
                domain: "XSign.Install",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "URL de instalação inválida."]
            )
        }
        let opened = await MainActor.run { () -> Bool in
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return true
        }
        if !opened {
            throw NSError(
                domain: "XSign.Install",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "O iOS não pôde abrir o link itms-services."]
            )
        }
    }
}
