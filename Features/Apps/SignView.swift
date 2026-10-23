import SwiftUI

struct SignView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let app: AppItem

    @State private var options = SignOptions()
    @State private var name: String
    @State private var bundleID: String
    @State private var version: String
    @State private var running = false

    init(app: AppItem) {
        self.app = app
        _name = State(initialValue: app.name)
        _bundleID = State(initialValue: app.bundleID)
        _version = State(initialValue: app.version)
    }

    private var certificate: Certificate? { appState.currentCertificate }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        ZStack(alignment: .bottomTrailing) {
                            AppIconThumb(name: name, data: options.iconData, size: 46)
                            Image(systemName: "pencil")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.onGraphite)
                                .frame(width: 18, height: 18)
                                .background(Color.graphite, in: Circle())
                                .overlay(Circle().stroke(Color.stoneBG, lineWidth: 2))
                                .offset(x: 5, y: 5)
                        }
                        VStack(alignment: .leading) {
                            Text(name).font(.subheadline.weight(.semibold))
                            Text(bundleID).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }

                Section(L.tr("sign.certificate")) {
                    if let cert = certificate {
                        NavigationLink {
                            CertificatesView()
                        } label: {
                            HStack {
                                Image(systemName: "checkmark.seal")
                                VStack(alignment: .leading) {
                                    Text(cert.nickname).font(.subheadline.weight(.semibold))
                                    if let d = cert.daysLeft {
                                        Text(L.tr("cert.expiresInDays", d)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                StatusBadge(status: cert.status)
                            }
                        }
                    } else {
                        Text(L.tr("sign.noCert")).foregroundStyle(Color.brick)
                    }
                }

                Section(L.tr("detail.info")) {
                    LabeledTextField(label: L.tr("sign.name"), text: $name)
                    LabeledTextField(label: L.tr("detail.bundleid"), text: $bundleID, mono: true)
                    LabeledTextField(label: L.tr("detail.version"), text: $version)
                }

                Section(L.tr("sign.options")) {
                    NavigationLink {
                        TweaksView(options: $options)
                    } label: {
                        LabeledContent(L.tr("sign.tweaks"), value: "\(options.injections.count)")
                    }
                    Toggle(L.tr("sign.removeExtensions"), isOn: $options.removeExtensions)
                    Toggle(L.tr("sign.removeDeviceRestriction"), isOn: $options.removeDeviceRestriction)
                    Toggle(L.tr("sign.fileSharing"), isOn: $options.fileSharing)
                }
            }
            .navigationTitle(L.tr("apps.action.sign"))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(title: L.tr("sign.button"), enabled: certificate?.status.canSign ?? false) {
                    running = true
                }
                .padding(Spacing.screen)
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.tr("common.cancel")) { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $running) {
                if let cert = certificate {
                    SignProgressView(app: app, certificate: cert, options: finalOptions)
                }
            }
        }
    }

    private var finalOptions: SignOptions {
        var o = options
        o.name = name; o.bundleID = bundleID; o.version = version
        return o
    }
}

struct LabeledTextField: View {
    let label: String
    @Binding var text: String
    var mono = false

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            TextField(label, text: $text)
                .multilineTextAlignment(.trailing)
                .font(mono ? .callout.monospaced() : .body)
                .autocorrectionDisabled(mono)
                .textInputAutocapitalization(mono ? .never : .sentences)
        }
    }
}

/// Lista de tweaks/dylibs a injetar.
struct TweaksView: View {
    @Binding var options: SignOptions

    var body: some View {
        List {
            Section {
                ForEach(options.injections) { inj in
                    Label(inj.name, systemImage: "puzzlepiece.extension")
                }
                .onDelete { options.injections.remove(atOffsets: $0) }
            } footer: {
                Text(L.tr("tweaks.footer"))
            }
        }
        .navigationTitle(L.tr("sign.tweaks"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
