import SwiftUI

struct CertificatesView: View {
    @EnvironmentObject private var app: AppState
    @State private var showImport = false
    @State private var checking = false

    var body: some View {
        List {
            if app.certificates.isEmpty {
                EmptyStateView(title: L.tr("certs.empty.title"),
                               message: L.tr("certs.empty.message"),
                               systemImage: "checkmark.seal")
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    Button {
                        Task { await checkAll() }
                    } label: {
                        HStack {
                            Text(L.tr("certs.verifyAll"))
                            Spacer()
                            if checking { ProgressView().controlSize(.small) }
                            else { Image(systemName: "arrow.clockwise") }
                        }
                    }.foregroundStyle(Color.graphite)
                }
                ForEach(app.certificates) { cert in
                    Section {
                        NavigationLink { CertificateDetailView(cert: cert) } label: {
                            CertificateCard(cert: cert)
                        }
                        .listRowBackground(cert.status == .revoked ? Color.surface.opacity(0.7) : Color.surface)
                    }
                }
            }
        }
        .navigationTitle(L.tr("settings.certificates"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImport = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showImport) { ImportCertificateView() }
    }

    private func checkAll() async {
        checking = true
        for i in app.certificates.indices {
            let status = await app.certificateService.checkRevocation(for: app.certificates[i])
            app.certificates[i].status = status
            app.certificates[i].checkedAt = Date()
        }
        app.persist()
        checking = false
    }
}
