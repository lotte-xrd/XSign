import SwiftUI

struct FilesView: View {
    @EnvironmentObject private var app: AppState
    @State private var showImport = false
    @State private var appsBytes: Int64 = 0
    @State private var downloadsBytes: Int64 = 0
    @State private var otherBytes: Int64 = 0
    @State private var tweaksCount: Int = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StorageBar(appsBytes: appsBytes, downloadsBytes: downloadsBytes, otherBytes: otherBytes)
                        .listRowInsets(EdgeInsets(top: 12, leading: Spacing.screen, bottom: 12, trailing: Spacing.screen))
                }
                Section {
                    NavigationLink {
                        FileBrowserView(directory: Paths.documents, title: L.tr("files.allFiles"))
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "externaldrive").foregroundStyle(Color.graphite).frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L.tr("files.allFiles")).font(.subheadline.weight(.semibold))
                                Text(L.tr("files.allFiles.subtitle")).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section(L.tr("files.folders")) {
                    NavigationLink {
                        FileBrowserView(directory: Paths.unsigned, title: L.tr("apps.unsigned.plain"))
                    } label: {
                        folderRow(L.tr("apps.unsigned.plain"), "folder", count: app.apps.filter { $0.state == .unsigned }.count)
                    }

                    NavigationLink {
                        FileBrowserView(directory: Paths.signed, title: L.tr("apps.signed.plain"))
                    } label: {
                        folderRow(L.tr("apps.signed.plain"), "checkmark.seal", count: app.apps.filter { $0.state == .signed }.count)
                    }

                    NavigationLink {
                        FileBrowserView(directory: Paths.downloads, title: L.tr("tab.downloads"))
                    } label: {
                        folderRow(L.tr("tab.downloads"), "arrow.down.circle", count: countFiles(in: Paths.downloads))
                    }

                    NavigationLink {
                        CertificatesView()
                    } label: {
                        folderRow(L.tr("files.certificates"), "key", count: app.certificates.count)
                    }

                    NavigationLink {
                        FileBrowserView(directory: Paths.tweaks, title: L.tr("files.tweaks"))
                    } label: {
                        folderRow(L.tr("files.tweaks"), "puzzlepiece.extension", count: tweaksCount)
                    }
                }
            }
            .navigationTitle(L.tr("tab.files"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showImport = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showImport, onDismiss: refreshMetrics) {
                ImportResourceView()
            }
            .onAppear(perform: refreshMetrics)
        }
    }

    private func refreshMetrics() {
        Paths.ensure()
        let unsignedSize = Paths.folderSize(Paths.unsigned)
        let signedSize = Paths.folderSize(Paths.signed)
        appsBytes = unsignedSize + signedSize
        downloadsBytes = Paths.folderSize(Paths.downloads)
        otherBytes = Paths.folderSize(Paths.certs) + Paths.folderSize(Paths.tweaks) + Paths.folderSize(Paths.icons)
        tweaksCount = countFiles(in: Paths.tweaks)
    }

    private func countFiles(in dir: URL) -> Int {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).count
    }

    private func folderRow(_ name: String, _ icon: String, count: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Color.lead).frame(width: 28)
            Text(name)
            Spacer()
            Text("\(count)").foregroundStyle(.secondary).font(.subheadline.monospacedDigit())
        }
    }
}

struct StorageBar: View {
    let appsBytes: Int64
    let downloadsBytes: Int64
    let otherBytes: Int64

    private var totalBytes: Int64 { max(0, appsBytes + downloadsBytes + otherBytes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
                    .font(.title3.weight(.bold))
                Text(L.tr("files.used")).font(.caption2).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let total = Double(max(1, totalBytes))
                let w = geo.size.width
                HStack(spacing: 2) {
                    if totalBytes == 0 {
                        Capsule().fill(Color.hairline).frame(maxWidth: .infinity)
                    } else {
                        if appsBytes > 0 {
                            Capsule().fill(Color.graphite)
                                .frame(width: max(8, w * (Double(appsBytes) / total)))
                        }
                        if downloadsBytes > 0 {
                            Capsule().fill(Color.lead)
                                .frame(width: max(8, w * (Double(downloadsBytes) / total)))
                        }
                        if otherBytes > 0 {
                            Capsule().fill(Color.ash)
                                .frame(width: max(8, w * (Double(otherBytes) / total)))
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(height: 5)
            HStack(spacing: 12) {
                legend(Color.graphite, "Apps (\(ByteCountFormatter.string(fromByteCount: appsBytes, countStyle: .file)))")
                legend(Color.lead, "\(L.tr("tab.downloads")) (\(ByteCountFormatter.string(fromByteCount: downloadsBytes, countStyle: .file)))")
                legend(Color.ash, "\(L.tr("files.other")) (\(ByteCountFormatter.string(fromByteCount: otherBytes, countStyle: .file)))")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 6, height: 6)
            Text(label).lineLimit(1)
        }
    }
}
