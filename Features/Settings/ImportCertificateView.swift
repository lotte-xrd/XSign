import SwiftUI
import UniformTypeIdentifiers

struct ImportCertificateView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    private enum PickerKind: Identifiable {
        case p12, profile, zip
        var id: Self { self }
    }

    @State private var activePicker: PickerKind?
    @State private var p12Data: Data?
    @State private var p12FileName: String?
    @State private var profileData: Data?
    @State private var profileFileName: String?
    @State private var password = "1"
    @State private var nickname = ""
    @State private var profile: CertificateService.ProfileInfo?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        activePicker = .zip
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.zipper")
                                .font(.headline)
                                .frame(width: 30, height: 30)
                                .background(Color.fill, in: RoundedRectangle(cornerRadius: 7))
                                .foregroundStyle(Color.graphite)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Importar pacote .zip")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.graphite)
                                Text("Pacote com .p12 + .mobileprovision (ex: Exploiting iOS)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.ash)
                        }
                    }
                }

                Section(L.tr("importcert.files")) {
                    fileRow("P12", p12FileName ?? L.tr("importcert.p12"), loaded: p12Data != nil) {
                        activePicker = .p12
                    }
                    fileRow("PROV", profileFileName ?? L.tr("importcert.profile"), loaded: profileData != nil) {
                        activePicker = .profile
                    }
                }

                Section {
                    SecureField(L.tr("importcert.password"), text: $password)
                    TextField(L.tr("importcert.nickname"), text: $nickname)
                } header: {
                    Text(L.tr("importcert.data"))
                } footer: {
                    Text(L.tr("importcert.keychain"))
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.brick)
                    }
                }

                if let p = profile {
                    Section(L.tr("importcert.readFromProfile")) {
                        if let teamName = p.teamName {
                            LabeledContent(L.tr("cert.team"), value: teamName)
                        }
                        LabeledContent(L.tr("cert.teamID")) { Text(p.teamID).font(.caption.monospaced()) }
                        LabeledContent(L.tr("cert.type"), value: p.type)
                        if let appID = p.appID {
                            LabeledContent(L.tr("cert.appID")) { Text(appID).font(.caption.monospaced()) }
                        }
                        if let exp = p.expiresAt {
                            LabeledContent(L.tr("cert.validity"), value: exp.formatted(date: .abbreviated, time: .omitted))
                        }
                        LabeledContent(L.tr("cert.devices"), value: "\(p.devices.count)")
                    }
                }
            }
            .navigationTitle(L.tr("importcert.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L.tr("common.cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.tr("importcert.import")) { importCert() }
                        .disabled(!(p12Data != nil && profileData != nil && !password.isEmpty))
                }
            }
            .fileImporter(
                isPresented: Binding(get: { activePicker != nil }, set: { if !$0 { activePicker = nil } }),
                allowedContentTypes: allowedTypes(for: activePicker)
            ) { result in
                handlePickedFile(result)
            }
        }
    }

    private func allowedTypes(for kind: PickerKind?) -> [UTType] {
        switch kind {
        case .zip:
            return [.zip, .archive, .data]
        case .p12:
            return [UTType(filenameExtension: "p12") ?? .data, .pkcs12, .data]
        case .profile:
            return [UTType(filenameExtension: "mobileprovision") ?? .data, .data]
        case .none:
            return [.data]
        }
    }

    private func handlePickedFile(_ result: Result<URL, Error>) {
        guard let kind = activePicker else { return }
        activePicker = nil
        errorMessage = nil

        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            switch kind {
            case .zip:
                do {
                    let cert = try app.certificateService.importFromZip(url: url, makeActive: app.certificates.isEmpty)
                    app.certificates.append(cert)
                    app.persist()
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                }

            case .p12:
                if let d = try? Data(contentsOf: url), !d.isEmpty {
                    p12Data = d
                    p12FileName = url.lastPathComponent
                } else {
                    errorMessage = "Não foi possível ler o arquivo .p12."
                }

            case .profile:
                do {
                    let d = try Data(contentsOf: url)
                    let parsed = try app.certificateService.readProfile(data: d)
                    profileData = d
                    profileFileName = url.lastPathComponent
                    profile = parsed
                    if nickname.isEmpty, let t = parsed.teamName ?? parsed.name {
                        nickname = t
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func fileRow(_ ext: String, _ title: String, loaded: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(ext).font(.system(size: 8, weight: .semibold).monospaced())
                    .frame(width: 30, height: 30).background(Color.fill, in: RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(.secondary)
                Text(title).foregroundStyle(Color.graphite).lineLimit(1)
                Spacer()
                Image(systemName: loaded ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundStyle(loaded ? Color.moss : Color.ash)
            }
        }
    }

    private func importCert() {
        guard let p12 = p12Data, let prov = profileData else { return }
        do {
            let cert = try app.certificateService.saveCertificate(
                p12Data: p12,
                profileData: prov,
                password: password,
                nickname: nickname,
                makeActive: app.certificates.isEmpty
            )
            app.certificates.append(cert)
            app.persist()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
