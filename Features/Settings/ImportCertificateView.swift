import SwiftUI

struct ImportCertificateView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    private enum PickerKind {
        case p12, profile, zip
    }

    @State private var showPicker = false
    @State private var pickerKind: PickerKind = .p12
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
                        pickerKind = .zip
                        showPicker = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.zipper")
                                .font(.headline)
                                .frame(width: 30, height: 30)
                                .background(Color.fill, in: RoundedRectangle(cornerRadius: 7))
                                .foregroundStyle(Color.graphite)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L.tr("importcert.zipTitle"))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.graphite)
                                Text(L.tr("importcert.zipSubtitle"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.ash)
                        }
                    }
                }

                Section(L.tr("certimport.section")) {
                    ForEach([CertImportSource.esign, CertImportSource.ksign]) { src in
                        NavigationLink {
                            CertificateFilesImportView(source: src, onDone: { dismiss() })
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: src.symbol)
                                    .font(.headline)
                                    .frame(width: 30, height: 30)
                                    .background(Color.fill, in: RoundedRectangle(cornerRadius: 7))
                                    .foregroundStyle(Color.graphite)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L.tr("certimport.from", src.title))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.graphite)
                                    Text(L.tr("certimport.subtitle"))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section(L.tr("importcert.files")) {
                    fileRow("P12", p12FileName ?? L.tr("importcert.p12"), loaded: p12Data != nil) {
                        pickerKind = .p12
                        showPicker = true
                    }
                    fileRow("PROV", profileFileName ?? L.tr("importcert.profile"), loaded: profileData != nil) {
                        pickerKind = .profile
                        showPicker = true
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
            .sheet(isPresented: $showPicker) {
                DocumentPicker(allowsMultipleSelection: false) { urls in
                    handlePickedURLs(urls)
                }
            }
        }
    }

    private func handlePickedURLs(_ urls: [URL]) {
        errorMessage = nil
        guard let url = urls.first else { return }

        let ext = url.pathExtension.lowercased()

        if ext == "zip" || (pickerKind == .zip && ext != "p12" && ext != "mobileprovision") {
            do {
                let cert = try app.certificateService.importFromZip(url: url, makeActive: app.certificates.isEmpty)
                app.certificates.append(cert)
                app.persist()
                dismiss()
                return
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            errorMessage = L.tr("cert.error.profile")
            return
        }

        let isProvision = ext == "mobileprovision"
            || ext == "provisionprofile"
            || (try? app.certificateService.readProfile(data: data)) != nil

        if pickerKind == .profile || isProvision {
            do {
                let parsed = try app.certificateService.readProfile(data: data)
                profileData = data
                profileFileName = url.lastPathComponent
                profile = parsed
                if nickname.isEmpty, let t = parsed.teamName ?? parsed.name {
                    nickname = t
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            p12Data = data
            p12FileName = url.lastPathComponent
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
        Task {
            withAnimation(.easeInOut(duration: 0.2)) {
                app.activeHUDTitle = L.tr("loading.hud.importingCert")
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            defer {
                withAnimation(.easeInOut(duration: 0.2)) {
                    app.activeHUDTitle = nil
                }
            }
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
}
