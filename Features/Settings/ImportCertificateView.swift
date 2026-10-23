import SwiftUI

struct ImportCertificateView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var p12Loaded = false
    @State private var profileLoaded = false
    @State private var password = ""
    @State private var nickname = ""
    @State private var profile: CertificateService.ProfileInfo?

    var body: some View {
        NavigationStack {
            Form {
                Section(L.tr("importcert.files")) {
                    fileRow("P12", L.tr("importcert.p12"), loaded: p12Loaded) { p12Loaded = true }
                    fileRow("PROV", L.tr("importcert.profile"), loaded: profileLoaded) {
                        profileLoaded = true
                        profile = .init(teamID: "7HQ2K4M9XA", teamName: "Marina Costa", appID: "7HQ2K4M9XA.*",
                                        type: "Apple Development",
                                        expiresAt: Calendar.current.date(byAdding: .day, value: 312, to: Date()),
                                        devices: [], entitlementsCount: 8)
                    }
                }

                Section(L.tr("importcert.data")) {
                    SecureField(L.tr("importcert.password"), text: $password)
                    TextField(L.tr("importcert.nickname"), text: $nickname)
                } footer: {
                    Text(L.tr("importcert.keychain"))
                }

                if let p = profile {
                    Section(L.tr("importcert.readFromProfile")) {
                        LabeledContent(L.tr("cert.team")) { Text(p.teamID).font(.caption.monospaced()) }
                        LabeledContent(L.tr("cert.type"), value: p.type)
                        if let exp = p.expiresAt {
                            LabeledContent(L.tr("cert.validity"), value: exp.formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                }
            }
            .navigationTitle(L.tr("importcert.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L.tr("common.cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.tr("importcert.import")) { importCert() }
                        .disabled(!(p12Loaded && profileLoaded && !password.isEmpty))
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
                Text(title).foregroundStyle(Color.graphite)
                Spacer()
                Image(systemName: loaded ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundStyle(loaded ? Color.moss : Color.ash)
            }
        }
    }

    private func importCert() {
        guard let p = profile else { return }
        let cert = Certificate(
            nickname: nickname.isEmpty ? (p.teamName ?? "Certificado") : nickname,
            teamID: p.teamID, teamName: p.teamName, type: p.type, appID: p.appID,
            expiresAt: p.expiresAt, entitlementsCount: p.entitlementsCount,
            p12Path: "", profilePath: "", keychainKey: UUID().uuidString,
            status: app.certificateService.status(expiresAt: p.expiresAt),
            checkedAt: Date(), inUse: app.certificates.isEmpty)
        app.certificates.append(cert)
        app.persist()
        dismiss()
    }
}
