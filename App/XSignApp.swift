import SwiftUI

@main
struct XSignApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var language = LocalizationManager.shared

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootTabView()
                    .environmentObject(appState)
                    .environmentObject(language)

                if let hudTitle = appState.activeHUDTitle {
                    LoadingHUDView(title: hudTitle)
                        .transition(.opacity)
                        .zIndex(10)
                }

                if appState.isBootstrapping {
                    SplashView(
                        progress: appState.bootProgress,
                        statusText: appState.bootStatusText
                    )
                    .transition(.opacity)
                    .zIndex(20)
                }
            }
            .environment(\.locale, language.locale)
            .environment(\.layoutDirection, language.isRTL ? .rightToLeft : .leftToRight)
            .tint(.graphite)
            .preferredColorScheme(appState.settings.appearance.colorScheme)
            .id(language.code) // recria a árvore ao trocar de idioma
            .onOpenURL { appState.handle(url: $0) }
            .task { await appState.bootstrap() }
        }
    }
}
