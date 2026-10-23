import SwiftUI

struct StoreView: View {
    @EnvironmentObject private var app: AppState
    @State private var query = ""
    @State private var filter = 0
    @State private var showAddSheet = false

    private var sourceNames: [String] { [L.tr("store.filter.all")] + app.sources.map(\.name) }

    private var filtered: [SourceApp] {
        var list = app.sourceApps
        if filter > 0, filter - 1 < app.sources.count {
            let id = app.sources[filter - 1].id
            list = list.filter { $0.sourceID == id }
        }
        if !query.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(query)
                || $0.bundleID.localizedCaseInsensitiveContains(query) }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            Group {
                if app.sourceApps.isEmpty {
                    EmptyStateView(title: L.tr("store.empty.title"),
                                   message: L.tr("store.empty.message"),
                                   systemImage: "square.grid.2x2")
                } else {
                    List {
                        if sourceNames.count > 1 {
                            FilterChips(items: sourceNames, selection: $filter)
                                .listRowInsets(EdgeInsets(top: 4, leading: Spacing.screen, bottom: 4, trailing: Spacing.screen))
                                .listRowBackground(Color.clear)
                        }
                        Section(L.tr("store.section.recent")) {
                            ForEach(filtered) { item in
                                NavigationLink(value: item) { SourceAppRow(item: item) }
                            }
                        }
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
            .onChange(of: app.pendingSourceURL) { if $0 != nil { showAddSheet = true } }
        }
    }
}

struct SourceAppRow: View {
    @EnvironmentObject private var app: AppState
    let item: SourceApp

    private var installed: Bool { app.apps.contains { $0.bundleID == item.bundleID } }

    var body: some View {
        HStack(spacing: 12) {
            AppIconThumb(name: item.name, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if installed {
                Text(L.tr("store.installed")).font(.caption2).foregroundStyle(.secondary)
            } else {
                Button {
                    if let v = item.latest { app.downloads.start(name: item.name, url: v.downloadURL) }
                } label: { Image(systemName: "arrow.down.circle").font(.title3) }
                .buttonStyle(.plain).foregroundStyle(Color.graphite)
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let v = item.latest?.version { parts.append(v) }
        if let s = item.latest?.size { parts.append(ByteCountFormatter.string(fromByteCount: s, countStyle: .file)) }
        if let n = item.sourceName { parts.append(n) }
        return parts.joined(separator: " · ")
    }
}
