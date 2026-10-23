import SwiftUI

struct CertificateDetailView: View {
    @EnvironmentObject private var app: AppState
    let cert: Certificate

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
                LabeledContent(L.tr("cert.entitlements"), value: "\(cert.entitlementsCount)")
            }

            Section {
                if !cert.inUse {
                    Button(L.tr("cert.useThis")) { use() }.foregroundStyle(Color.graphite)
                }
                Button(L.tr("cert.export")) {}.foregroundStyle(Color.graphite)
                Button(L.tr("cert.delete"), role: .destructive) { delete() }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func use() {
        for i in app.certificates.indices { app.certificates[i].inUse = (app.certificates[i].id == cert.id) }
        app.persist()
    }

    private func delete() {
        app.certificates.removeAll { $0.id == cert.id }
        app.persist()
    }
}
