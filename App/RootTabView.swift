import SwiftUI

/// As cinco abas: Apps em primeiro lugar, seguido de Downloads, Loja, Arquivos e Ajustes.
struct RootTabView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var shop: CertShopController

    var body: some View {
        TabView(selection: $app.selectedTab) {
            AppsView()
                .tabItem { Label(L.tr("tab.apps"), systemImage: "square.stack.3d.up") }
                .tag(AppTab.apps)

            DownloadsView()
                .tabItem { Label(L.tr("tab.downloads"), systemImage: "arrow.down.circle") }
                .badge(app.downloads.activeCount)
                .tag(AppTab.downloads)

            StoreView()
                .tabItem { Label(L.tr("tab.store"), systemImage: "square.grid.2x2") }
                .tag(AppTab.store)

            FilesView()
                .tabItem { Label(L.tr("tab.files"), systemImage: "folder") }
                .tag(AppTab.files)

            SettingsView()
                .tabItem { Label(L.tr("tab.settings"), systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        // Compra de certificado: planos e pagamento numa folha, andamento em tela cheia.
        .sheet(isPresented: $shop.shopPresented) {
            CertShopSheet()
                .environmentObject(app)
                .environmentObject(shop)
        }
        .fullScreenCover(isPresented: $shop.progressPresented) {
            CertProgressView()
                .environmentObject(app)
                .environmentObject(shop)
        }
        // Resultado de um arquivo aberto de fora (Arquivos, Safari, "Abrir com").
        .alert(
            app.importNotice?.title ?? "",
            isPresented: Binding(
                get: { app.importNotice != nil },
                set: { if !$0 { app.importNotice = nil } }
            )
        ) {
            Button("OK", role: .cancel) { app.importNotice = nil }
        } message: {
            Text(app.importNotice?.message ?? "")
        }
        // Certificado aberto de fora sem a senha ou sem o outro arquivo. Fica num
        // fundo próprio para não disputar com a folha da compra.
        .background(
            Color.clear.sheet(item: $app.certificateImportRequest) { request in
                NavigationStack {
                    CertificateFilesImportView(
                        source: .files,
                        prefilled: request.urls,
                        onDone: { app.finishCertificateImportRequest(imported: true) }
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L.tr("common.cancel")) { app.finishCertificateImportRequest(imported: false) }
                        }
                    }
                }
                .environmentObject(app)
            }
        )
    }
}

enum AppTab: Hashable {
    case apps, downloads, store, files, settings
}
