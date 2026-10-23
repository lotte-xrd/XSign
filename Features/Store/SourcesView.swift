import SwiftUI
import UIKit

struct SourcesView: View {
    @EnvironmentObject private var app: AppState
    @State private var showAdd = false

    var body: some View {
        List {
            if app.sources.isEmpty {
                EmptyStateView(title: L.tr("sources.empty.title"),
                               message: L.tr("sources.empty.message"),
                               systemImage: "server.rack")
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(app.sources) { source in
                        SourceRow(source: source)
                    }
                    .onDelete { idx in idx.map { app.sources[$0] }.forEach(app.removeSource) }
                    .onMove { app.sources.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    Text(L.tr("sources.footer"))
                }
            }
        }
        .navigationTitle(L.tr("store.sources"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { Task { await refreshAll() } } label: { Label(L.tr("sources.refreshAll"), systemImage: "arrow.clockwise") }
                    Button {} label: { Label(L.tr("sources.import"), systemImage: "tray.and.arrow.down") }
                    Button {} label: { Label(L.tr("sources.export"), systemImage: "square.and.arrow.up") }
                    Button { copyAllURLs() } label: { Label(L.tr("sources.copyURLs"), systemImage: "link") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showAdd) { AddSourcesView() }
    }

    private func refreshAll() async {
        for source in app.sources {
            try? await app.addSource(url: source.url)
        }
    }

    private func copyAllURLs() {
        UIPasteboard.general.string = app.sources.map { $0.url.absoluteString }.joined(separator: "\n")
    }
}

struct SourceRow: View {
    let source: Source

    var body: some View {
        HStack(spacing: 12) {
            AppIconThumb(name: source.name, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name).font(.subheadline.weight(.semibold))
                if let err = source.lastError {
                    Text(err).font(.caption).foregroundStyle(Color.brick).lineLimit(1)
                } else {
                    Text(source.url.absoluteString).font(.caption.monospaced())
                        .foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text("\(source.appCount)").font(.caption.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color.fill, in: Capsule()).foregroundStyle(.secondary)
        }
    }
}
