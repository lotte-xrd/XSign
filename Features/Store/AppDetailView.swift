import SwiftUI

struct AppDetailView: View {
    @EnvironmentObject private var app: AppState
    let item: SourceApp

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    AppIconThumb(name: item.name, size: 58)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.title3.weight(.bold))
                        Text([item.developer, item.sourceName].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let v = item.latest {
                        PillButton(title: L.tr("store.get"), filled: true) {
                            app.downloads.start(name: item.name, url: v.downloadURL)
                            app.selectedTab = .downloads
                        }
                    }
                }
            }
            .listRowBackground(Color.clear)

            if let latest = item.latest {
                statRow(latest)
                if let notes = latest.notes {
                    Section(L.tr("detail.whatsnew")) { Text(notes).font(.subheadline) }
                }
            }

            Section(L.tr("detail.info")) {
                LabeledContent(L.tr("detail.bundleid")) { Text(item.bundleID).font(.caption.monospaced()) }
                if let d = item.latest?.date {
                    LabeledContent(L.tr("detail.updated"), value: d.formatted(date: .abbreviated, time: .omitted))
                }
            }

            if item.versions.count > 1 {
                Section(L.tr("detail.versions")) {
                    ForEach(item.versions.dropFirst(), id: \.version) { v in
                        HStack {
                            Text("\(v.version) · \(ByteCountFormatter.string(fromByteCount: v.size ?? 0, countStyle: .file))")
                                .font(.subheadline)
                            Spacer()
                            Button { app.downloads.start(name: item.name, url: v.downloadURL) } label: {
                                Image(systemName: "arrow.down.circle")
                            }.buttonStyle(.plain).foregroundStyle(Color.graphite)
                        }
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func statRow(_ v: AppVersion) -> some View {
        Section {
            HStack {
                stat(L.tr("detail.version"), v.version)
                Divider()
                stat(L.tr("detail.size"), ByteCountFormatter.string(fromByteCount: v.size ?? 0, countStyle: .file))
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary).textCase(.uppercase)
            Text(value).font(.subheadline.weight(.semibold))
        }.frame(maxWidth: .infinity)
    }
}
