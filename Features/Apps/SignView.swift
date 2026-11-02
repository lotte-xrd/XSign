import SwiftUI
import UniformTypeIdentifiers

struct SignView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let app: AppItem

    @State private var options = SignOptions()
    @State private var name: String
    @State private var bundleID: String
    @State private var version: String
    @State private var running = false
    @State private var showIconPicker = false

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
                        Button {
                            showIconPicker = true
                        } label: {
                            ZStack(alignment: .bottomTrailing) {
                                AppIconThumb(
                                    name: name,
                                    data: options.iconData,
                                    iconPath: app.iconPath,
                                    url: app.iconURL,
                                    size: 50
                                )
                                Image(systemName: "pencil")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Color.onGraphite)
                                    .frame(width: 18, height: 18)
                                    .background(Color.graphite, in: Circle())
                                    .overlay(Circle().stroke(Color.stoneBG, lineWidth: 2))
                                    .offset(x: 4, y: 4)
                            }
                        }
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(.subheadline.weight(.semibold))
                            Text(bundleID).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            if app.downloadURL != nil {
                                Text(L.tr("sign.directDownload"))
                                    .font(.caption2)
                                    .foregroundStyle(Color.moss)
                            }
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
                        NavigationLink {
                            ImportCertificateView()
                        } label: {
                            HStack {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.brick)
                                Text(L.tr("sign.noCert")).foregroundStyle(Color.brick)
                            }
                        }
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
            .fileImporter(isPresented: $showIconPicker, allowedContentTypes: [.image]) { res in
                if case .success(let url) = res {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if let d = try? Data(contentsOf: url) {
                        options.iconData = d
                    }
                }
            }
            .fullScreenCover(isPresented: $running) {
                if let cert = certificate {
                    SignProgressView(app: app, certificate: cert, options: finalOptions) {
                        dismiss()
                    }
                }
            }
        }
    }

    private var finalOptions: SignOptions {
        var o = options
        o.name = name
        o.bundleID = bundleID
        o.version = version
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

/// Lista de tweaks/dylibs reais da pasta Tweaks + seletor de arquivos.
struct TweaksView: View {
    @Binding var options: SignOptions
    @State private var showPicker = false
    @State private var availableTweaks: [URL] = []

    var body: some View {
        List {
            Section {
                ForEach(options.injections) { inj in
                    Label(inj.name, systemImage: "puzzlepiece.extension")
                }
                .onDelete { options.injections.remove(atOffsets: $0) }

                Button {
                    showPicker = true
                } label: {
                    Label(L.tr("files.import"), systemImage: "plus.circle")
                }
            } footer: {
                Text(L.tr("tweaks.footer"))
            }

            if !availableTweaks.isEmpty {
                Section(L.tr("files.tweaks")) {
                    ForEach(availableTweaks, id: \.path) { url in
                        let added = options.injections.contains { $0.name == url.lastPathComponent }
                        Button {
                            if !added {
                                options.injections.append(Injection(name: url.lastPathComponent, path: Paths.relative(url)))
                            }
                        } label: {
                            HStack {
                                Text(url.lastPathComponent)
                                Spacer()
                                Image(systemName: added ? "checkmark.circle.fill" : "plus")
                                    .foregroundStyle(added ? Color.moss : Color.graphite)
                            }
                        }
                        .foregroundStyle(Color.graphite)
                    }
                }
            }
        }
        .navigationTitle(L.tr("sign.tweaks"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadTweaksFolder() }
        .sheet(isPresented: $showPicker) {
            DocumentPicker(allowsMultipleSelection: true) { urls in
                Paths.ensure()
                for u in urls {
                    let dest = Paths.tweaks.appendingPathComponent(u.lastPathComponent)
                    try? FileManager.default.removeItem(at: dest)
                    try? FileManager.default.copyItem(at: u, to: dest)
                    if !options.injections.contains(where: { $0.name == dest.lastPathComponent }) {
                        options.injections.append(Injection(name: dest.lastPathComponent, path: Paths.relative(dest)))
                    }
                }
                loadTweaksFolder()
            }
        }
    }

    private func loadTweaksFolder() {
        availableTweaks = ((try? FileManager.default.contentsOfDirectory(
            at: Paths.tweaks,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).filter { ["dylib", "deb"].contains($0.pathExtension.lowercased()) }
    }
}
