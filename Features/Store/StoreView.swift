import SwiftUI

struct StoreView: View {
    @EnvironmentObject private var app: AppState
    @State private var query = ""
    @State private var filter = 0
    @State private var showAddSheet = false
    @State private var directSignTarget: AppItem?

    private var sourceNames: [String] { [L.tr("store.filter.all")] + app.sources.map(\.name) }

    private var filtered: [SourceApp] {
        var list = app.sourceApps
        if filter > 0, filter - 1 < app.sources.count {
            let id = app.sources[filter - 1].id
            list = list.filter { $0.sourceID == id }
        }
        if !query.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                || $0.bundleID.localizedCaseInsensitiveContains(query)
                || ($0.developer?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            Group {
                if app.sourceApps.isEmpty {
                    VStack(spacing: 16) {
                        EmptyStateView(
                            title: L.tr("store.empty.title"),
                            message: L.tr("store.empty.message"),
                            systemImage: "square.grid.2x2"
                        )
                        PillButton(title: L.tr("addsource.title"), filled: true) {
                            showAddSheet = true
                        }
                    }
                } else {
                    List {
                        if sourceNames.count > 1 {
                            FilterChips(items: sourceNames, selection: $filter)
                                .listRowInsets(EdgeInsets(top: 4, leading: Spacing.screen, bottom: 4, trailing: Spacing.screen))
                                .listRowBackground(Color.clear)
                        }
                        Section(L.tr("store.section.recent")) {
                            ForEach(filtered) { item in
                                NavigationLink(value: item) {
                                    SourceAppRow(item: item) { signable in
                                        directSignTarget = signable
                                    }
                                }
                            }
                        }
                    }
                    .refreshable {
                        await app.refreshAllSources()
                    }
                }
            }
            .navigationTitle(L.tr("tab.store"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: L.tr("store.search", app.sourceApps.count))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { SourcesView() } label: { Text(L.tr("store.sources")) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAddSheet = true } label: { Image(systemName: "plus") }
                }
            }
            .navigationDestination(for: SourceApp.self) { AppDetailView(item: $0) }
            .sheet(isPresented: $showAddSheet) { AddSourcesView() }
            .sheet(item: $directSignTarget) { SignView(app: $0) }
            .onChange(of: app.pendingSourceURL) { if $0 != nil { showAddSheet = true } }
        }
    }
}

struct SourceAppRow: View {
    @EnvironmentObject private var app: AppState
    let item: SourceApp
    var onDirectSign: ((AppItem) -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            AppIconThumb(name: item.name, url: item.iconURL, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Menu {
                if let signable = item.asSignableAppItem() {
                    Button {
                        onDirectSign?(signable)
                    } label: {
                        Label(L.tr("apps.action.sign"), systemImage: "signature")
                    }
                }
                if let v = item.latest {
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
                        Label(L.tr("downloads.download"), systemImage: "arrow.down.circle")
                    }
                }
            } label: {
                Text(L.tr("store.get").uppercased())
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .foregroundStyle(Color.graphite)
                    .background(Color.fill, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let v = item.latest?.version { parts.append("v\(v)") }
        if let s = item.latest?.size, s > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: s, countStyle: .file))
        }
        if let n = item.sourceName { parts.append(n) }
        return parts.joined(separator: " · ")
    }
}
