import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var language: LocalizationManager

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

                Section("Comunidade & Links Oficiais") {
                    Link(destination: URL(string: "https://exploiting-ios.online")!) {
                        HStack {
                            Label("XSign Website", systemImage: "safari.fill")
                                .foregroundStyle(Color.graphite)
                            Spacer()
                            Text("exploiting-ios.online")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Link(destination: URL(string: "https://discord.gg/UzExbYa2MZ")!) {
                        HStack {
                            Label("Discord", systemImage: "bubble.left.and.bubble.right.fill")
                                .foregroundStyle(Color.graphite)
                            Spacer()
                            Text("Entrar no servidor")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Link(destination: URL(string: "https://t.me/+NJgHs1Dx5ahmMDRk")!) {
                        HStack {
                            Label("Telegram", systemImage: "paperplane.fill")
                                .foregroundStyle(Color.graphite)
                            Spacer()
                            Text("Canal oficial")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Link(destination: URL(string: "https://instagram.com/exploiting_ios")!) {
                        HStack {
                            Label("Instagram", systemImage: "camera.fill")
                                .foregroundStyle(Color.graphite)
                            Spacer()
                            Text("@exploiting_ios")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Créditos") {
                    DeveloperCreditCard()
                }

                Section {
                    LabeledContent(L.tr("settings.version"), value: "1.0.0 (1)")
                    NavigationLink(L.tr("settings.about")) { AboutView() }
                }
            }
            .navigationTitle(L.tr("tab.settings"))
            .navigationBarTitleDisplayMode(.inline)
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
            Section("Servidor de Assinatura (zsign + OTA)") {
                TextField("https://exploiting-ios.online", text: $app.settings.serverURL)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            Section {
                LabeledContent("Device Queue ID") {
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
            SignatureLine(progress: cert.validityFraction, warning: cert.status == .expiring)
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
        HStack(spacing: 14) {
            Image("LotteAvatar")
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(Color.graphite.opacity(0.25), lineWidth: 1.5)
                )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Lotte")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Color.graphite)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(Color.moss)
                }
                Text("Head Developer · XSign")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("Exploiting iOS (exploiting-ios.online)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section("Head Developer") {
                DeveloperCreditCard()
            }
            Section { Text(L.tr("about.blurb")).font(.subheadline) }
            Section(L.tr("about.openSource")) {
                LabeledContent("zsign 1.1.3", value: "Assinatura C++/OpenSSL")
                LabeledContent("ZIPFoundation", value: "Leitura e pacotes .ipa")
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
