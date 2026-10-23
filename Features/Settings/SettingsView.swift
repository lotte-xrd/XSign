import SwiftUI

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
                    NavigationLink(L.tr("settings.defaultOptions")) { EmptyView() }
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

                Section {
                    LabeledContent(L.tr("settings.version"), value: "1.0.0 (1)")
                    NavigationLink(L.tr("settings.about")) { AboutView() }
                }
            }
            .navigationTitle(L.tr("tab.settings"))
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: app.settings.appearance) { _ in app.settings.save() }
            .onChange(of: app.settings.installAfterSign) { _ in app.settings.save() }
        }
    }

    private var currentLanguageName: String {
        LocalizationManager.all.first { $0.code == language.code }?.endonym ?? L.tr("language.system")
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

struct AboutView: View {
    var body: some View {
        List {
            Section { Text(L.tr("about.blurb")).font(.subheadline) }
            Section(L.tr("about.openSource")) {
                LabeledContent("zsign", value: "assinatura")
                LabeledContent("ZIPFoundation", value: "ipa")
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
                    app.settings.appIcon = icon; app.settings.save()
                    // UIApplication.shared.setAlternateIconName(icon == "paper" ? "AppIcon-Papel" : nil)
                } label: {
                    HStack {
                        Text(icon == "graphite" ? L.tr("icon.graphite") : L.tr("icon.paper"))
                        Spacer()
                        if app.settings.appIcon == icon { Image(systemName: "checkmark").foregroundStyle(Color.graphite) }
                    }
                }.foregroundStyle(Color.graphite)
            }
        }
        .navigationTitle(L.tr("settings.appIcon"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
