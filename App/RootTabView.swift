import SwiftUI

/// As cinco abas, na ordem do blueprint: encontrar, baixar, assinar, guardar, configurar.
struct RootTabView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        TabView(selection: $app.selectedTab) {
            StoreView()
                .tabItem { Label(L.tr("tab.store"), systemImage: "square.grid.2x2") }
                .tag(AppTab.store)

            DownloadsView()
                .tabItem { Label(L.tr("tab.downloads"), systemImage: "arrow.down.circle") }
                .badge(app.downloads.activeCount)
                .tag(AppTab.downloads)

            AppsView()
                .tabItem { Label(L.tr("tab.apps"), systemImage: "square.stack.3d.up") }
                .tag(AppTab.apps)

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
    case store, downloads, apps, files, settings
}
