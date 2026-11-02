import SwiftUI
import UniformTypeIdentifiers

struct AppsView: View {
    @EnvironmentObject private var app: AppState
    @State private var segment: AppState2 = .unsigned
    @State private var query = ""
    @State private var actionTarget: AppItem?
    @State private var signTarget: AppItem?
    @State private var quickSignTarget: AppItem?
    @State private var showIPAImporter = false
    @State private var showCertImporter = false
    @State private var shareItems: [Any] = []
    @State private var showShare = false
    @State private var errorAlertMessage: String?

    private var list: [AppItem] {
        app.apps.filter { $0.state == segment }
            .filter {
                query.isEmpty
                || $0.name.localizedCaseInsensitiveContains(query)
                || $0.bundleID.localizedCaseInsensitiveContains(query)
            }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $segment) {
                    Text(L.tr("apps.unsigned", app.apps.filter { $0.state == .unsigned }.count)).tag(AppState2.unsigned)
                    Text(L.tr("apps.signed", app.apps.filter { $0.state == .signed }.count)).tag(AppState2.signed)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Spacing.screen).padding(.vertical, 8)

                if list.isEmpty {
                    VStack(spacing: 14) {
                        EmptyStateView(title: L.tr("apps.empty.title"), message: L.tr("apps.empty.message"))
                        if segment == .unsigned {
                            PillButton(title: L.tr("apps.importIPA"), filled: true) {
                                showIPAImporter = true
                            }
                        }
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(list) { item in
                            Button { actionTarget = item } label: {
                                AppRow(
                                    item: item,
                                    onSign: { signTarget = item },
                                    onInstall: { installApp(item) }
                                )
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) { app.delete(item) } label: {
                                    Label(L.tr("common.delete"), systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(L.tr("tab.apps"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: L.tr("common.search"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showIPAImporter = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .confirmationDialog(actionTarget?.name ?? "", isPresented: .init(
                get: { actionTarget != nil }, set: { if !$0 { actionTarget = nil } }
            ), titleVisibility: .visible) {
                if let item = actionTarget { actionButtons(for: item) }
            }
            .sheet(item: $signTarget) { SignView(app: $0) }
            .sheet(isPresented: $showCertImporter) { ImportCertificateView() }
            .fullScreenCover(item: $quickSignTarget) { target in
                if let cert = app.currentCertificate {
                    SignProgressView(app: target, certificate: cert, options: SignOptions(name: target.name, bundleID: target.bundleID, version: target.version))
                }
            }
            .sheet(isPresented: $showShare) {
                ShareSheet(items: shareItems)
            }
            .sheet(isPresented: $showIPAImporter) {
                DocumentPicker(allowsMultipleSelection: true) { urls in
                    for u in urls {
                        do {
                            _ = try app.importResource(url: u)
                        } catch {
                            errorAlertMessage = error.localizedDescription
                        }
                    }
                }
            }
            .alert(L.tr("common.notice"), isPresented: .init(
                get: { errorAlertMessage != nil },
                set: { if !$0 { errorAlertMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorAlertMessage = nil }
            } message: {
                Text(errorAlertMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private func actionButtons(for item: AppItem) -> some View {
        if item.state == .unsigned {
            Button(L.tr("apps.action.sign")) { signTarget = item }
            Button(L.tr("apps.action.signDefault")) {
                if app.currentCertificate != nil {
                    quickSignTarget = item
                } else {
                    signTarget = item
                }
            }
            Button(L.tr("apps.action.share")) { shareApp(item) }
            Button(L.tr("common.delete"), role: .destructive) { app.delete(item) }
        } else {
            Button(L.tr("apps.action.install")) { installApp(item) }
            Button(L.tr("apps.action.share")) { shareApp(item) }
            Button(L.tr("apps.action.resign")) { signTarget = item }
            Button(L.tr("common.delete"), role: .destructive) { app.delete(item) }
        }
    }

    private func installApp(_ item: AppItem) {
        Task {
            do {
                if let installURL = item.installURL, !installURL.isEmpty {
                    try await app.installService.openInstallURL(installURL)
                } else {
                    try await app.installService.install(
                        ipaPath: item.filePath,
                        bundleID: item.bundleID,
                        version: item.version,
                        title: item.name
                    )
                }
            } catch {
                errorAlertMessage = error.localizedDescription
            }
        }
    }

    private func shareApp(_ item: AppItem) {
        if !item.filePath.isEmpty && !item.filePath.hasPrefix("http") {
            let localURL = Paths.resolve(item.filePath)
            if FileManager.default.fileExists(atPath: localURL.path) {
                shareItems = [localURL]
                showShare = true
                return
            }
        }
        if let shareURLStr = item.shareURL ?? item.signedDownloadURL, let u = URL(string: shareURLStr) {
            shareItems = [u]
            showShare = true
        } else if let dl = item.downloadURL {
            shareItems = [dl]
            showShare = true
        }
    }
}

struct AppRow: View {
    let item: AppItem
    var onSign: (() -> Void)? = nil
    var onInstall: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            AppIconThumb(name: item.name, iconPath: item.iconPath, url: item.iconURL, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    Text("\(item.version) · \(item.bundleID)")
                    if item.size > 0 {
                        Text("· \(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))")
                    }
                }
                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                if item.state == .signed, let certName = item.certificateName {
                    Text(certName).font(.caption2).foregroundStyle(Color.moss).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if item.state == .signed {
                PillButton(title: L.tr("apps.action.install"), filled: true) {
                    onInstall?()
                }
            } else {
                PillButton(title: L.tr("apps.action.sign"), filled: true) {
                    onSign?()
                }
            }
        }
    }
}
