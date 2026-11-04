import SwiftUI

struct CertificateDetailView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    let cert: Certificate

    @State private var exportedZipURL: URL?
    @State private var exportError: String?

    var body: some View {
        List {
            Section {
                VStack(spacing: 5) {
                    Image(systemName: "checkmark.seal")
                        .font(.title).foregroundStyle(Color.onGraphite)
                        .frame(width: 42, height: 42)
                        .background(Color.graphite, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    Text(cert.nickname).font(.headline)
                    StatusBadge(status: cert.status)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent(L.tr("cert.type"), value: cert.type)
                if let team = cert.teamName { LabeledContent(L.tr("cert.team"), value: team) }
                LabeledContent(L.tr("cert.teamID")) { Text(cert.teamID).font(.caption.monospaced()) }
            }

            Section(L.tr("cert.validity")) {
                if let issued = cert.issuedAt {
                    LabeledContent(L.tr("cert.issued"), value: issued.formatted(date: .abbreviated, time: .omitted))
                }
                if let exp = cert.expiresAt {
                    LabeledContent(L.tr("cert.expires"), value: exp.formatted(date: .abbreviated, time: .omitted))
                }
                SignatureLine(progress: cert.validityFraction, warning: cert.status == .expiring,
                              trailing: cert.daysLeft.map { L.tr("cert.daysCount", $0) })
            }

            Section(L.tr("cert.profile")) {
                if let appID = cert.appID {
                    LabeledContent(L.tr("cert.appID")) { Text(appID).font(.caption.monospaced()) }
                }
                NavigationLink {
                    List(cert.devices, id: \.self) { Text($0).font(.caption.monospaced()) }
                        .navigationTitle(L.tr("cert.devices"))
                } label: {
                    LabeledContent(L.tr("cert.devices"), value: "\(cert.devices.count)")
                }
                NavigationLink {
                    EntitlementsView(
                        title: L.tr("cert.entitlements"),
                        dictionary: app.certificateService.entitlements(for: cert)
                    )
                } label: {
                    LabeledContent(L.tr("cert.entitlements"), value: "\(cert.entitlementsCount)")
                }
            }

            if let exportError {
                Section {
                    Text(exportError).font(.caption).foregroundStyle(Color.brick)
                }
            }

            Section {
                if !cert.inUse {
                    Button(L.tr("cert.useThis")) { use() }.foregroundStyle(Color.graphite)
                }
                Button(L.tr("cert.export")) { exportZip() }.foregroundStyle(Color.graphite)
                Button(L.tr("cert.delete"), role: .destructive) { delete() }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(get: { exportedZipURL != nil }, set: { if !$0 { exportedZipURL = nil } })) {
            if let exportedZipURL { ShareSheet(items: [exportedZipURL]) }
        }
    }

    private func use() {
        for i in app.certificates.indices {
            app.certificates[i].inUse = (app.certificates[i].id == cert.id)
        }
        app.persist()
    }

    private func exportZip() {
        do {
            exportedZipURL = try app.certificateService.exportCertificateZip(cert)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func delete() {
        KeychainHelper.delete(key: cert.keychainKey)
        let folder = Paths.resolve(cert.p12Path).deletingLastPathComponent()
        if folder.path.contains("/Certificates/") {
            try? FileManager.default.removeItem(at: folder)
        }
        app.certificates.removeAll { $0.id == cert.id }
        if !app.certificates.isEmpty && !app.certificates.contains(where: { $0.inUse }) {
            app.certificates[0].inUse = true
        }
        app.persist()
        dismiss()
    }
}
