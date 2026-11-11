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
    }
}

enum AppTab: Hashable {
    case apps, downloads, store, files, settings
}
