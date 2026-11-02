import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SourcesView: View {
    @EnvironmentObject private var app: AppState
    @State private var showAdd = false
    @State private var showImporter = false
    @State private var shareURL: URL?

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
                    .onMove {
                        app.sources.move(fromOffsets: $0, toOffset: $1)
                        app.persist()
                    }
                } footer: {
                    Text(L.tr("sources.footer"))
                }
            }
        }
        .navigationTitle(L.tr("store.sources"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await app.refreshAllSources()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { Task { await app.refreshAllSources() } } label: {
                        Label(L.tr("sources.refreshAll"), systemImage: "arrow.clockwise")
                    }
                    Button { showImporter = true } label: {
                        Label(L.tr("sources.import"), systemImage: "tray.and.arrow.down")
                    }
                    Button { exportSources() } label: {
                        Label(L.tr("sources.export"), systemImage: "square.and.arrow.up")
                    }
                    Button { copyAllURLs() } label: {
                        Label(L.tr("sources.copyURLs"), systemImage: "link")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showAdd) { AddSourcesView() }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let shareURL { ShareSheet(items: [shareURL]) }
        }
        .sheet(isPresented: $showImporter) {
            DocumentPicker(allowsMultipleSelection: false) { urls in
                if let url = urls.first {
                    _ = try? app.importResource(url: url)
                }
            }
        }
    }

    private func copyAllURLs() {
        UIPasteboard.general.string = app.sources.map { $0.url.absoluteString }.joined(separator: "\n")
    }

    private func exportSources() {
        let text = app.sources.map { $0.url.absoluteString }.joined(separator: "\n")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("xsign-sources.txt")
        try? text.data(using: .utf8)?.write(to: temp)
        shareURL = temp
    }
}

struct SourceRow: View {
    let source: Source

    var body: some View {
        HStack(spacing: 12) {
            AppIconThumb(name: source.name, url: source.iconURL, size: 40)
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
