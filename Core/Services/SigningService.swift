import Foundation

/// Motor de assinatura. As telas falam só com este protocolo e consomem o
/// progresso como `AsyncStream`; nunca tocam no motor nativo diretamente.
protocol SigningService {
    func sign(app: AppItem, certificate: Certificate, options: SignOptions) -> AsyncStream<SignProgress>
}

// MARK: - Implementação real (a integrar no macOS)

/// Ponte para o zsign (C++/OpenSSL), vendorizado em `Vendor/zsign/` com um
/// wrapper Obj-C++. O pipeline é o do blueprint:
///
/// 1. extrair o `Payload/*.app` (ZIPFoundation);
/// 2. aplicar as mudanças no Info.plist (nome, bundle ID, versão, ícone,
///    remoção de extensões em `PlugIns/` e de `UISupportedDevices`);
/// 3. injetar `.dylib`/`.deb` em `Frameworks/` (opcional);
/// 4. assinar de dentro para fora com o par .p12 + perfil, gerando
///    `CodeResources` e embutindo o perfil;
/// 5. recompactar em `Apps/Signed/<id>/App.ipa`.
///
/// Este arquivo é só a casca Swift: o trabalho pesado fica no wrapper do zsign.
/// Enquanto o bridge não está ligado, injetar `MockSigningService` para rodar a UI.
struct ZSignService: SigningService {
    func sign(app: AppItem, certificate: Certificate, options: SignOptions) -> AsyncStream<SignProgress> {
        AsyncStream { continuation in
            Task {
                // TODO: chamar o wrapper do zsign aqui e repassar o progresso real.
                // Ex.: ZSignBridge.sign(ipaPath:, p12Path:, password:, profilePath:, options:) { step in ... }
                continuation.yield(SignProgress(steps: SignStepKind.allCases.map { SignStep(kind: $0) },
                                                fraction: 0,
                                                error: "ZSignService não implementado neste scaffold."))
                continuation.finish()
            }
        }
    }
}

// MARK: - Mock para rodar a interface sem o motor nativo

/// Emite o mesmo progresso do motor real, em tempo simulado, para desenvolver a
/// tela de assinatura sem precisar do zsign compilado.
struct MockSigningService: SigningService {
    func sign(app: AppItem, certificate: Certificate, options: SignOptions) -> AsyncStream<SignProgress> {
        AsyncStream { continuation in
            Task {
                var steps = SignStepKind.allCases
                    .filter { $0 != .install }
                    .filter { $0 != .inject || !options.injections.isEmpty }
                    .map { SignStep(kind: $0) }

                let durations: [SignStepKind: Double] = [
                    .extract: 1.2, .modify: 0.3, .inject: 0.4, .sign: 4.1, .pack: 0.4
                ]

                for i in steps.indices {
                    let kind = steps[i].kind
                    steps[i].state = .running(detail: kind == .sign ? L.tr("sign.detail.binaries", 23) : nil)
                    continuation.yield(SignProgress(steps: steps, fraction: Double(i) / Double(steps.count)))
                    try? await Task.sleep(nanoseconds: UInt64((durations[kind] ?? 0.5) * 1_000_000_000) / 3)
                    steps[i].state = .done(seconds: durations[kind])
                }

                let out = Paths.signed.appendingPathComponent("\(app.id.uuidString)/App.ipa").path
                continuation.yield(SignProgress(steps: steps, fraction: 1, finished: true, outputPath: out))
                continuation.finish()
            }
        }
    }
}
