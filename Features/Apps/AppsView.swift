import SwiftUI
import UniformTypeIdentifiers

struct AppsView: View {
    @EnvironmentObject private var app: AppState
    @State private var segment: AppState2 = .unsigned
    @State private var query = ""
    @State private var actionTarget: AppItem?
    @State private var signTarget: AppItem?
    @State private var quickSignTarget: AppItem?
    @State private var infoTarget: AppItem?
    @State private var showIPAImporter = false
    @State private var showCertImporter = false
    @State private var shareItems: [Any] = []
    @State private var showShare = false
    @State private var errorAlertMessage: String?

    // Seleção para assinatura em lote
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var bulkJob: BulkSignJob?

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
                .disabled(selecting)

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
                            Button {
                                if selecting {
                                    toggleSelection(item)
                                } else {
                                    actionTarget = item
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    if selecting {
                                        Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.title3)
                                            .foregroundStyle(selected.contains(item.id) ? Color.graphite : Color.ash)
                                            .transition(.scale.combined(with: .opacity))
                                    }
                                    AppRow(
                                        item: item,
                                        showsAction: !selecting,
                                        onSign: { signTarget = item },
                                        onInstall: { installApp(item) }
                                    )
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .swipeActions {
                                if !selecting {
                                    Button(role: .destructive) { app.delete(item) } label: {
                                        Label(L.tr("common.delete"), systemImage: "trash")
                                    }
                                    Button { infoTarget = item } label: {
                                        Label(L.tr("appinfo.title"), systemImage: "info.circle")
                                    }
                                    .tint(Color.lead)
                                }
                            }
                        }
                    }
                    .animation(.xsignSmooth, value: selecting)
                }
            }
            .navigationTitle(L.tr("tab.apps"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: L.tr("common.search"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if segment == .unsigned && !list.isEmpty {
                        Button(selecting ? L.tr("common.done") : L.tr("bulk.select")) {
                            withAnimation(.xsignSmooth) {
                                selecting.toggle()
                                if !selecting { selected.removeAll() }
                            }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !selecting {
                        Button { showIPAImporter = true } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting {
                    selectionBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onChange(of: segment) { _ in
                selecting = false
                selected.removeAll()
            }
            .confirmationDialog(actionTarget?.name ?? "", isPresented: .init(
                get: { actionTarget != nil }, set: { if !$0 { actionTarget = nil } }
            ), titleVisibility: .visible) {
                if let item = actionTarget { actionButtons(for: item) }
            }
            .sheet(item: $signTarget) { SignView(app: $0) }
            .sheet(item: $infoTarget) { AppInfoView(item: $0) }
            .sheet(isPresented: $showCertImporter) { ImportCertificateView() }
            .fullScreenCover(item: $quickSignTarget) { target in
                if let cert = app.currentCertificate {
                    SignProgressView(app: target, certificate: cert, options: SignOptions(name: target.name, bundleID: target.bundleID, version: target.version))
                }
            }
            .fullScreenCover(item: $bulkJob) { job in
                BulkSignView(apps: job.apps)
            }
            .sheet(isPresented: $showShare) {
                ShareSheet(items: shareItems)
            }
            .sheet(isPresented: $showIPAImporter) {
                DocumentPicker(allowsMultipleSelection: true) { urls in
                    Task {
                        do {
                            _ = try await app.importResourcesWithHUD(urls: urls)
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

    // MARK: Barra de seleção (lote)

    private var selectionBar: some View {
        VStack(spacing: 8) {
            if app.currentCertificate == nil {
                Text(L.tr("sign.noCert"))
                    .font(.caption)
                    .foregroundStyle(Color.brick)
            }
            HStack(spacing: 10) {
                Button {
                    withAnimation(.xsignSmooth) {
                        if selected.count == list.count {
                            selected.removeAll()
                        } else {
                            selected = Set(list.map { $0.id })
                        }
                    }
                } label: {
                    Text(selected.count == list.count ? L.tr("bulk.selectNone") : L.tr("bulk.selectAll"))
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Color.fill, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.graphite)

                PrimaryButton(
                    title: L.tr("bulk.signCount", selected.count),
                    enabled: !selected.isEmpty && app.currentCertificate?.status.canSign == true
                ) {
                    let chosen = list.filter { selected.contains($0.id) }
                    withAnimation(.xsignSmooth) {
                        selecting = false
                        selected.removeAll()
                    }
                    bulkJob = BulkSignJob(apps: chosen)
                }
            }
        }
        .padding(Spacing.screen)
        .background(.bar)
    }

    private func toggleSelection(_ item: AppItem) {
        withAnimation(.xsignSmooth) {
            if selected.contains(item.id) {
                selected.remove(item.id)
            } else {
                selected.insert(item.id)
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
            Button(L.tr("appinfo.title")) { infoTarget = item }
            Button(L.tr("apps.action.share")) { shareApp(item) }
            Button(L.tr("common.delete"), role: .destructive) { app.delete(item) }
        } else {
            Button(L.tr("apps.action.install")) { installApp(item) }
            Button(L.tr("appinfo.title")) { infoTarget = item }
            Button(L.tr("apps.action.share")) { shareApp(item) }
            Button(L.tr("apps.action.resign")) {
                var target = app.signingInput(for: item)
                if app.isOfficialPlaceholder(item) { target.version = app.latestXSignVersion }
                signTarget = target
            }
            Button(L.tr("common.delete"), role: .destructive) { app.delete(item) }
        }
    }

    private func installApp(_ item: AppItem) {
        // O XSign que vem pronto na lista ainda não tem arquivo assinado:
        // assina a versão do link "latest" com o certificado e oferece instalar.
        if app.isOfficialPlaceholder(item) {
            var latest = item
            latest.version = app.latestXSignVersion
            if app.currentCertificate != nil {
                quickSignTarget = latest
            } else {
                signTarget = latest
            }
            return
        }
        Task {
            do {
                // Renova sozinho o link do servidor quando ele já venceu.
                try await app.installSigned(item)
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
    var showsAction: Bool = true
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
            if showsAction {
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
}
