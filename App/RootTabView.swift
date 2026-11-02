import SwiftUI

/// As cinco abas: Apps em primeiro lugar, seguido de Downloads, Loja, Arquivos e Ajustes.
struct RootTabView: View {
    @EnvironmentObject private var app: AppState

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
    }
}

enum AppTab: Hashable {
    case apps, downloads, store, files, settings
}
