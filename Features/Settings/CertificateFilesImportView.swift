import SwiftUI

/// De onde vêm os arquivos do certificado.
enum CertImportSource: String, Identifiable, CaseIterable {
    case esign, ksign, files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .esign: return "ESign"
        case .ksign: return "KSign"
        case .files: return L.tr("certimport.files.title")
        }
    }

    /// Ícone neutro (não usamos as logos dos outros apps).
    var symbol: String {
        switch self {
        case .esign: return "e.square"
        case .ksign: return "k.square"
        case .files: return "folder"
        }
    }

    var steps: [String] {
        switch self {
        case .esign:
            return [L.tr("certimport.esign.step1"), L.tr("certimport.common.step2"), L.tr("certimport.common.step3")]
        case .ksign:
            return [L.tr("certimport.ksign.step1"), L.tr("certimport.common.step2"), L.tr("certimport.common.step3"), L.tr("certimport.ksign.note")]
        case .files:
            return [L.tr("certimport.common.step3")]
        }
    }
}

/// Importa um certificado a partir dos arquivos exportados por outro assinador
/// (.p12 + .mobileprovision, um .zip ou uma pasta), descobrindo a senha sozinho
/// quando ela vem num .txt/.json junto.
struct CertificateFilesImportView: View {
    @EnvironmentObject private var app: AppState
    let source: CertImportSource
    var prefilled: [URL] = []
    var onDone: () -> Void

    @State private var showPicker = false
    @State private var candidate: CertificateService.CertificateCandidate?
    @State private var password = ""
    @State private var nickname = ""
    @State private var errorMessage: String?
    @State private var working = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: source.symbol)
                        .font(.title2)
                        .foregroundStyle(Color.graphite)
                        .frame(width: 44, height: 44)
                        .background(Color.fill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source == .files ? L.tr("certimport.files.header") : L.tr("certimport.from", source.title))
                            .font(.headline)
                        Text(L.tr("certimport.subtitle"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section(L.tr("certimport.howto")) {
                ForEach(Array(source.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(Color.onGraphite)
                            .frame(width: 20, height: 20)
                            .background(Color.graphite, in: Circle())
                        Text(step)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
            }

            Section(L.tr("importcert.files")) {
                Button {
                    showPicker = true
                } label: {
                    Label(L.tr("certimport.pick"), systemImage: "doc.badge.plus")
                        .foregroundStyle(Color.graphite)
                }

                if let candidate {
                    statusRow(L.tr("certimport.p12"), candidate.p12Name, ok: candidate.p12Data != nil)
                    statusRow(L.tr("certimport.profile"), candidate.profileName, ok: candidate.profileData != nil)
                    if candidate.p12Data != nil {
                        HStack(spacing: 10) {
                            Image(systemName: candidate.foundPassword != nil ? "key.fill" : "key")
                                .foregroundStyle(candidate.foundPassword != nil ? Color.moss : Color.ochre)
                                .frame(width: 22)
                            Text(candidate.foundPassword != nil ? L.tr("certimport.password.found") : L.tr("certimport.password.needed"))
                                .font(.subheadline)
                        }
                    }
                }
            }

            if let candidate, candidate.p12Data != nil, candidate.foundPassword == nil {
                Section {
                    SecureField(L.tr("importcert.password"), text: $password)
                } footer: {
                    Text(L.tr("importcert.keychain"))
                }
            }

            if candidate?.profileData != nil {
                Section {
                    TextField(L.tr("importcert.nickname"), text: $nickname)
                }
            }

            if let p = candidate?.profile {
                Section(L.tr("importcert.readFromProfile")) {
                    if let teamName = p.teamName {
                        LabeledContent(L.tr("cert.team"), value: teamName)
                    }
                    LabeledContent(L.tr("cert.teamID")) { Text(p.teamID).font(.caption.monospaced()) }
                    LabeledContent(L.tr("cert.type"), value: p.type)
                    if let exp = p.expiresAt {
                        LabeledContent(L.tr("cert.expires"), value: exp.formatted(date: .abbreviated, time: .omitted))
                    }
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.brick)
                }
            }
        }
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if working {
                    ProgressView()
                } else {
                    Button(L.tr("importcert.import")) { importNow() }
                        .disabled(!(candidate?.p12Data != nil && candidate?.profileData != nil))
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            DocumentPicker(allowsMultipleSelection: true) { urls in
                load(urls)
            }
        }
        .onAppear {
            if candidate == nil && !prefilled.isEmpty { load(prefilled) }
        }
    }

    private func statusRow(_ title: String, _ fileName: String?, ok: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(ok ? Color.moss : Color.brick)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline)
                Text(fileName ?? L.tr("certimport.notFound"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func load(_ urls: [URL]) {
        errorMessage = nil
        working = true
        let service = app.certificateService
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                service.collectCertificateFiles(urls)
            }.value
            withAnimation(.xsignSmooth) {
                candidate = result
                working = false
                if nickname.isEmpty, let p = result.profile {
                    nickname = p.teamName ?? p.name ?? ""
                }
                if result.p12Data == nil && result.profileData == nil {
                    errorMessage = L.tr("certimport.nothingFound")
                }
            }
        }
    }

    private func importNow() {
        guard let c = candidate, let p12 = c.p12Data, let prov = c.profileData else { return }
        let pass = c.foundPassword ?? password
        guard app.certificateService.validateP12(data: p12, password: pass) else {
            withAnimation(.xsignSmooth) { errorMessage = L.tr("certimport.password.wrong") }
            return
        }
        do {
            let cert = try app.certificateService.saveCertificate(
                p12Data: p12,
                profileData: prov,
                password: pass,
                nickname: nickname,
                makeActive: app.certificates.isEmpty
            )
            app.certificates.append(cert)
            app.persist()
            onDone()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
