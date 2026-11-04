import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var language: LocalizationManager
    @State private var showUpToDateAlert = false

    var body: some View {
        NavigationStack {
            List {
                if let cert = app.currentCertificate {
                    Section(L.tr("settings.currentCert")) {
                        NavigationLink { CertificatesView() } label: { CertificateCard(cert: cert) }
                    }
                }

                Section {
                    NavigationLink { CertificatesView() } label: {
                        LabeledContent {
                            Text("\(app.certificates.count)")
                        } label: { Label(L.tr("settings.certificates"), systemImage: "checkmark.seal") }
                    }
                    NavigationLink { ImportResourceView() } label: {
                        Label(L.tr("files.import"), systemImage: "tray.and.arrow.down")
                    }
                }

                Section(L.tr("settings.signing")) {
                    NavigationLink(L.tr("settings.defaultOptions")) { SigningServerSettingsView() }
                    Toggle(L.tr("settings.installAfter"), isOn: $app.settings.installAfterSign)
                    Toggle(L.tr("settings.deleteAfter"), isOn: $app.settings.deleteOriginalAfterSign)
                }

                Section(L.tr("settings.general")) {
                    NavigationLink {
                        LanguageView()
                    } label: {
                        LabeledContent {
                            Text(currentLanguageName)
                        } label: { Label(L.tr("settings.language"), systemImage: "globe") }
                    }
                    Picker(selection: $app.settings.appearance) {
                        ForEach(Settings.Appearance.allCases) { Text($0.label).tag($0) }
                    } label: { Label(L.tr("settings.appearance"), systemImage: "circle.lefthalf.filled") }
                    NavigationLink {
                        AppIconView()
                    } label: { Label(L.tr("settings.appIcon"), systemImage: "app.dashed") }
                }

                Section(L.tr("settings.community")) {
                    Link(destination: URL(string: "https://exploiting-ios.online")!) {
                        HStack {
                            Label(L.tr("settings.website"), systemImage: "globe")
                                .foregroundStyle(Color.graphite)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Link(destination: URL(string: "https://discord.gg/UzExbYa2MZ")!) {
                        HStack {
                            Label(L.tr("settings.discord"), systemImage: "bubble.left.and.bubble.right")
                                .foregroundStyle(Color.graphite)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Link(destination: URL(string: "https://t.me/+NJgHs1Dx5ahmMDRk")!) {
                        HStack {
                            Label(L.tr("settings.telegram"), systemImage: "paperplane")
                                .foregroundStyle(Color.graphite)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Link(destination: URL(string: "https://instagram.com/exploiting_ios")!) {
                        HStack {
                            Label(L.tr("settings.instagram"), systemImage: "camera")
                                .foregroundStyle(Color.graphite)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section(L.tr("settings.credits")) {
                    DeveloperCreditCard()
                }

                Section {
                    LabeledContent(L.tr("settings.version"), value: "\(app.currentAppVersion) (\(app.currentAppBuild))")
                    Button {
                        Task {
                            let found = await app.checkForAppUpdate(manual: true)
                            if !found {
                                showUpToDateAlert = true
                            }
                        }
                    } label: {
                        Label(L.tr("settings.checkUpdates"), systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(Color.graphite)
                    }
                    NavigationLink(L.tr("settings.about")) { AboutView() }
                }
            }
            .navigationTitle(L.tr("tab.settings"))
            .navigationBarTitleDisplayMode(.inline)
            .alert(L.tr("common.notice"), isPresented: $showUpToDateAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(L.tr("update.upToDate", app.currentAppVersion))
            }
            .onChange(of: app.settings.appearance) { _ in app.settings.save() }
            .onChange(of: app.settings.installAfterSign) { _ in app.settings.save() }
            .onChange(of: app.settings.deleteOriginalAfterSign) { _ in app.settings.save() }
        }
    }

    private var currentLanguageName: String {
        LocalizationManager.all.first { $0.code == language.code }?.endonym ?? L.tr("language.system")
    }
}

struct SigningServerSettingsView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Form {
            Section(L.tr("settings.serverSection")) {
                TextField("https://exploiting-ios.online", text: $app.settings.serverURL)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            Section {
                LabeledContent(L.tr("settings.deviceQueueID")) {
                    Text("\(KeychainHelper.deviceID.prefix(12))…")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(L.tr("settings.defaultOptions"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: app.settings.serverURL) { _ in app.settings.save() }
    }
}

struct CertificateCard: View {
    let cert: Certificate

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(cert.nickname).font(.subheadline.weight(.semibold))
                Spacer()
                StatusBadge(status: cert.status)
            }
            Text("\(cert.type) · \(cert.teamID)").font(.caption2.monospaced()).foregroundStyle(.secondary)
            if cert.isRevokedByApple {
                Label(
                    cert.appleRevokedAt.map { L.tr("cert.appleRevokedOn", $0.formatted(date: .abbreviated, time: .omitted)) }
                        ?? L.tr("cert.appleRevoked"),
                    systemImage: "exclamationmark.shield"
                )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.brick)
            }
            SignatureLine(progress: cert.validityFraction, warning: cert.status == .expiring || cert.isRevokedByApple)
            if let exp = cert.expiresAt {
                HStack {
                    Text(L.tr("cert.expiresOn", exp.formatted(date: .abbreviated, time: .omitted)))
                    Spacer()
                    if let d = cert.daysLeft { Text(L.tr("cert.daysCount", d)) }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct DeveloperCreditCard: View {
    var body: some View {
        HStack(spacing: 10) {
            Image("LotteAvatar")
                .resizable()
                .scaledToFill()
                .frame(width: 30, height: 30)
                .clipShape(Circle())
            Text("Lotte")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.graphite)
            Spacer()
            Text(L.tr("settings.headDeveloper"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section(L.tr("settings.credits")) {
                DeveloperCreditCard()
            }
            Section { Text(L.tr("about.blurb")).font(.subheadline) }
            Section(L.tr("about.openSource")) {
                LabeledContent("zsign 1.1.3", value: "C++ / OpenSSL")
                LabeledContent("ZIPFoundation", value: "MIT")
                if let licenseURL = Bundle.main.url(forResource: "ellekit-LICENSE", withExtension: "txt"),
                   let license = try? String(contentsOf: licenseURL, encoding: .utf8) {
                    NavigationLink {
                        ScrollView {
                            Text(license)
                                .font(.caption.monospaced())
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .navigationTitle("ElleKit")
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        LabeledContent("ElleKit", value: "BSD-3-Clause")
                    }
                } else {
                    LabeledContent("ElleKit", value: "BSD-3-Clause")
                }
                LabeledContent("Exploiting iOS", value: "OTA itms-services")
            }
        }
        .navigationTitle(L.tr("settings.about"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AppIconView: View {
    @EnvironmentObject private var app: AppState
    private let icons = ["graphite", "paper"]

    var body: some View {
        List {
            ForEach(icons, id: \.self) { icon in
                Button {
                    app.settings.appIcon = icon
                    app.settings.save()
                    if UIApplication.shared.supportsAlternateIcons {
                        UIApplication.shared.setAlternateIconName(icon == "paper" ? "AppIcon-Papel" : nil)
                    }
                } label: {
                    HStack {
                        Text(icon == "graphite" ? L.tr("icon.graphite") : L.tr("icon.paper"))
                        Spacer()
                        if app.settings.appIcon == icon {
                            Image(systemName: "checkmark").foregroundStyle(Color.graphite)
                        }
                    }
                }.foregroundStyle(Color.graphite)
            }
        }
        .navigationTitle(L.tr("settings.appIcon"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
