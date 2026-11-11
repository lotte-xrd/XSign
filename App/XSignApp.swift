import SwiftUI

@main
struct XSignApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appState = AppState()
    @StateObject private var language = LocalizationManager.shared

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootTabView()
                    .environmentObject(appState)
                    .environmentObject(appState.certShop)
                    .environmentObject(language)
                    .alert(
                        L.tr("revoked.alert.title"),
                        isPresented: Binding(
                            get: { appState.revocationAlert != nil },
                            set: { if !$0 { appState.revocationAlert = nil } }
                        )
                    ) {
                        Button("OK", role: .cancel) { appState.revocationAlert = nil }
                    } message: {
                        Text(appState.revocationAlert ?? "")
                    }

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
            .onReceive(NotificationCenter.default.publisher(for: .xsignOpenDownloads)) { _ in
                appState.selectedTab = .downloads
            }
            .onReceive(NotificationCenter.default.publisher(for: .xsignOpenApps)) { _ in
                appState.selectedTab = .apps
            }
            .onReceive(NotificationCenter.default.publisher(for: .xsignInstallFromNotification)) { _ in
                appState.selectedTab = .apps
                appState.resumePendingInstallIfNeeded()
            }
            .task { await appState.bootstrap() }
            .alert(
                appState.availableUpdate.map { L.tr("update.available.title", $0.version) } ?? "",
                isPresented: Binding(
                    get: { appState.availableUpdate != nil },
                    set: { if !$0 { appState.availableUpdate = nil } }
                )
            ) {
                if let update = appState.availableUpdate {
                    Button(L.tr("update.now")) {
                        appState.triggerSelfUpdate(update)
                    }
                    Button(L.tr("update.later"), role: .cancel) {
                        appState.availableUpdate = nil
                    }
                }
            } message: {
                Text(appState.availableUpdate?.notes ?? L.tr("update.available.defaultNotes"))
            }
            .fullScreenCover(item: $appState.selfUpdateTarget) { target in
                if let cert = appState.currentCertificate {
                    SignProgressView(
                        app: target,
                        certificate: cert,
                        options: SignOptions(name: target.name, bundleID: target.bundleID, version: target.version)
                    )
                    .environmentObject(appState)
                    .environmentObject(language)
                } else {
                    SignView(app: target)
                        .environmentObject(appState)
                        .environmentObject(language)
                }
            }
            .onChange(of: scenePhase) { newPhase in
                switch newPhase {
                case .active:
                    appState.startHeartbeatLoop()
                    appState.closeForUpdateIfArmed(immediately: false)
                    if !appState.isBootstrapping {
                        appState.importFinishedBackgroundSigns()
                        appState.resumePendingInstallIfNeeded()
                        appState.certShop.appBecameActive()
                        Task { await appState.refreshAppleRevocation(force: false) }
                    }
                case .background:
                    Task { await appState.sendHeartbeat(state: "background") }
                    appState.certShop.appEnteredBackground()
                    appState.closeForUpdateIfArmed(immediately: true)
                default:
                    break
                }
            }
        }
    }
}
