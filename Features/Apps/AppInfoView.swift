import SwiftUI

/// "Ver informações" de um app: Info.plist, permissões, entitlements do binário,
/// frameworks, extensões e bibliotecas vinculadas (inclusive tweaks injetados).
struct AppInfoView: View {
    @Environment(\.dismiss) private var dismiss
    let item: AppItem

    @State private var report: AppReport?
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var downloadedTemp: URL?

    private var localIPA: URL? {
        guard !item.filePath.isEmpty, !item.filePath.hasPrefix("http") else { return nil }
        let url = Paths.resolve(item.filePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var remoteIPA: URL? {
        item.signedDownloadURL.flatMap { URL(string: $0) } ?? item.downloadURL
    }

    var body: some View {
        NavigationStack {
            List {
                header

                if let report {
                    sections(for: report)
                } else if loading {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(L.tr("appinfo.analyzing")).foregroundStyle(.secondary)
                        }
                    }
                } else if localIPA == nil {
                    Section {
                        Text(L.tr("appinfo.remoteOnly"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if remoteIPA != nil {
                            Button {
                                Task { await downloadAndInspect() }
                            } label: {
                                Label(L.tr("appinfo.downloadAnalyze"), systemImage: "arrow.down.circle")
                            }
                            .foregroundStyle(Color.graphite)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.brick)
                    }
                }
            }
            .animation(.xsignSmooth, value: report == nil)
            .navigationTitle(L.tr("appinfo.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.tr("common.close")) { dismiss() }
                }
            }
            .task {
                if report == nil, let localIPA { await inspect(localIPA) }
            }
            .onDisappear {
                if let downloadedTemp { try? FileManager.default.removeItem(at: downloadedTemp) }
            }
        }
    }

    // MARK: Cabeçalho

    private var header: some View {
        Section {
            HStack(spacing: 14) {
                AppIconThumb(name: item.name, iconPath: item.iconPath, url: item.iconURL, size: 58)
                VStack(alignment: .leading, spacing: 3) {
                    Text(report?.name.isEmpty == false ? report!.name : item.name)
                        .font(.title3.weight(.bold))
                        .lineLimit(2)
                    Text(report?.bundleID.isEmpty == false ? report!.bundleID : item.bundleID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(item.state == .signed ? L.tr("apps.signed.plain") : L.tr("apps.unsigned.plain"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(item.state == .signed ? Color.moss : Color.lead)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Seções

    @ViewBuilder
    private func sections(for r: AppReport) -> some View {
        Section(L.tr("appinfo.general")) {
            LabeledContent(L.tr("detail.version"), value: r.build.isEmpty || r.build == r.version ? r.version : "\(r.version) (\(r.build))")
            if let min = r.minimumOS ?? r.binaryMinOS {
                LabeledContent(L.tr("appinfo.minOS"), value: "iOS \(min)")
            }
            if !r.devices.isEmpty {
                LabeledContent(L.tr("appinfo.devices"), value: r.devices.joined(separator: ", "))
            }
            if !r.architectures.isEmpty {
                LabeledContent(L.tr("appinfo.archs")) {
                    Text(r.architectures.joined(separator: ", ")).font(.caption.monospaced())
                }
            }
            LabeledContent(L.tr("appinfo.installedSize"), value: ByteCountFormatter.string(fromByteCount: r.installedSize, countStyle: .file))
            LabeledContent(L.tr("appinfo.ipaSize"), value: ByteCountFormatter.string(fromByteCount: r.archiveSize, countStyle: .file))
            LabeledContent(L.tr("sign.fileSharing"), value: r.fileSharing ? L.tr("common.yes") : L.tr("common.no"))
            if r.encrypted {
                Label(L.tr("appinfo.encrypted"), systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(Color.ochre)
            }
        }

        if let p = r.signedBy {
            Section(L.tr("appinfo.signature")) {
                if let team = p.teamName { LabeledContent(L.tr("cert.team"), value: team) }
                LabeledContent(L.tr("cert.teamID")) { Text(p.teamID).font(.caption.monospaced()) }
                LabeledContent(L.tr("cert.type"), value: p.type)
                if let exp = p.expiresAt {
                    LabeledContent(L.tr("cert.expires"), value: exp.formatted(date: .abbreviated, time: .omitted))
                }
            }
        }

        Section(L.tr("appinfo.permissions")) {
            if r.permissions.isEmpty {
                Text(L.tr("appinfo.noPermissions")).font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(r.permissions) { perm in
                VStack(alignment: .leading, spacing: 3) {
                    Text(perm.label).font(.subheadline.weight(.medium))
                    if !perm.reason.isEmpty {
                        Text(perm.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 1)
            }
        }

        Section(L.tr("appinfo.contents")) {
            NavigationLink {
                EntitlementsView(title: L.tr("cert.entitlements"), dictionary: r.entitlements)
            } label: {
                LabeledContent(L.tr("cert.entitlements"), value: "\(r.entitlements.count)")
            }
            NavigationLink {
                ItemListView(title: L.tr("appinfo.frameworks"), items: r.frameworks)
            } label: {
                LabeledContent(L.tr("appinfo.frameworks"), value: "\(r.frameworks.count)")
            }
            NavigationLink {
                ItemListView(title: L.tr("appinfo.plugins"), items: r.plugins)
            } label: {
                LabeledContent(L.tr("appinfo.plugins"), value: "\(r.plugins.count)")
            }
            NavigationLink {
                LibrariesView(libraries: r.linkedLibraries)
            } label: {
                LabeledContent(L.tr("appinfo.libraries"), value: "\(r.linkedLibraries.count)")
            }
            NavigationLink {
                EntitlementsView(title: "Info.plist", dictionary: r.infoPlist)
            } label: {
                LabeledContent("Info.plist", value: "\(r.infoPlist.count)")
            }
        }

        if !r.embeddedLibraries.isEmpty {
            Section {
                ForEach(r.embeddedLibraries, id: \.self) { lib in
                    Text(lib).font(.caption.monospaced()).lineLimit(2)
                }
            } header: {
                Text(L.tr("appinfo.embeddedLibs"))
            } footer: {
                Text(L.tr("appinfo.embeddedLibs.footer"))
            }
        }

        if !r.urlSchemes.isEmpty {
            Section(L.tr("appinfo.urlSchemes")) {
                ForEach(r.urlSchemes, id: \.self) { scheme in
                    Text("\(scheme)://").font(.caption.monospaced())
                }
            }
        }

        if !r.backgroundModes.isEmpty {
            Section(L.tr("appinfo.background")) {
                ForEach(r.backgroundModes, id: \.self) { mode in
                    Text(mode).font(.caption.monospaced())
                }
            }
        }
    }

    // MARK: Carregamento

    private func inspect(_ url: URL) async {
        loading = true
        errorMessage = nil
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try AppInspector.inspect(ipaURL: url)
            }.value
            withAnimation(.xsignSmooth) {
                report = result
                loading = false
            }
        } catch {
            loading = false
            errorMessage = error.localizedDescription
        }
    }

    private func downloadAndInspect() async {
        guard let remote = remoteIPA else { return }
        loading = true
        errorMessage = nil
        do {
            var req = URLRequest(url: remote, timeoutInterval: 600)
            req.setValue("XSign/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
            let (temp, response) = try await URLSession.shared.download(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("xsign-info-\(UUID().uuidString).ipa")
            try FileManager.default.moveItem(at: temp, to: dest)
            downloadedTemp = dest
            await inspect(dest)
        } catch {
            loading = false
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Listas auxiliares

private struct ItemListView: View {
    let title: String
    let items: [AppReport.Item]

    var body: some View {
        List {
            if items.isEmpty {
                Text(L.tr("plist.empty")).foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                HStack {
                    Image(systemName: item.name.hasSuffix(".appex") ? "puzzlepiece.extension" : "shippingbox")
                        .foregroundStyle(Color.lead)
                        .frame(width: 24)
                    Text(item.name).font(.subheadline).lineLimit(2)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LibrariesView: View {
    let libraries: [String]
    @State private var query = ""

    private var filtered: [String] {
        query.isEmpty ? libraries : libraries.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            ForEach(filtered, id: \.self) { lib in
                HStack(spacing: 8) {
                    Circle()
                        .fill(lib.hasPrefix("@") ? Color.graphite : Color.ash)
                        .frame(width: 6, height: 6)
                    Text(lib)
                        .font(.caption.monospaced())
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        }
        .searchable(text: $query, prompt: L.tr("common.search"))
        .navigationTitle(L.tr("appinfo.libraries"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
