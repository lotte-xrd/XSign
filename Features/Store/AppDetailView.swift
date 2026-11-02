import SwiftUI

struct AppDetailView: View {
    @EnvironmentObject private var app: AppState
    let item: SourceApp
    @State private var signTarget: AppItem?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        AppIconThumb(name: item.name, url: item.iconURL, size: 62)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).font(.title3.weight(.bold))
                            Text([item.developer, item.sourceName].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    if let v = item.latest {
                        HStack(spacing: 10) {
                            PrimaryButton(title: L.tr("apps.action.sign")) {
                                signTarget = item.asSignableAppItem()
                            }
                            SecondaryButton(title: L.tr("downloads.download"), systemImage: "arrow.down.circle") {
                                app.downloads.start(
                                    name: item.name,
                                    url: v.downloadURL,
                                    iconURL: item.iconURL,
                                    bundleID: item.bundleID,
                                    version: v.version,
                                    sourceName: item.sourceName
                                )
                                app.selectedTab = .downloads
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: Spacing.screen, bottom: 4, trailing: Spacing.screen))

            if let latest = item.latest {
                statRow(latest)
                if let notes = latest.notes, !notes.isEmpty {
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
                            VStack(alignment: .leading, spacing: 2) {
                                Text("v\(v.version)").font(.subheadline.weight(.medium))
                                if let s = v.size, s > 0 {
                                    Text(ByteCountFormatter.string(fromByteCount: s, countStyle: .file))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button {
                                signTarget = AppItem(
                                    name: item.name,
                                    bundleID: item.bundleID,
                                    version: v.version,
                                    iconPath: nil,
                                    iconURL: item.iconURL,
                                    filePath: "",
                                    downloadURL: v.downloadURL,
                                    size: v.size ?? 0,
                                    state: .unsigned,
                                    origin: item.sourceName
                                )
                            } label: {
                                Image(systemName: "signature")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.graphite)
                            .padding(.trailing, 8)

                            Button {
                                app.downloads.start(
                                    name: item.name,
                                    url: v.downloadURL,
                                    iconURL: item.iconURL,
                                    bundleID: item.bundleID,
                                    version: v.version,
                                    sourceName: item.sourceName
                                )
                                app.selectedTab = .downloads
                            } label: {
                                Image(systemName: "arrow.down.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.graphite)
                        }
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $signTarget) { SignView(app: $0) }
    }

    private func statRow(_ v: AppVersion) -> some View {
        Section {
            HStack {
                stat(L.tr("detail.version"), v.version)
                Divider()
                stat(L.tr("detail.size"), (v.size ?? 0) > 0 ? ByteCountFormatter.string(fromByteCount: v.size ?? 0, countStyle: .file) : "—")
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
