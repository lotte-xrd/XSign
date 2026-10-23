import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var app: AppState
    @State private var linkText = ""
    @State private var showLink = false

    var body: some View {
        NavigationStack {
            Group {
                if app.downloads.tasks.isEmpty {
                    EmptyStateView(title: L.tr("downloads.empty.title"),
                                   message: L.tr("downloads.empty.message"),
                                   systemImage: "arrow.down.circle")
                } else {
                    List {
                        if !app.downloads.running.isEmpty {
                            Section(L.tr("downloads.inprogress")) {
                                ForEach(app.downloads.running) { ActiveDownloadRow(task: $0) }
                            }
                        }
                        if !app.downloads.finished.isEmpty {
                            Section(L.tr("downloads.done")) {
                                ForEach(app.downloads.finished) { FinishedDownloadRow(task: $0) }
                            }
                        }
                    }
                }
            }
            .navigationTitle(L.tr("tab.downloads"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showLink = true } label: { Label(L.tr("downloads.fromLink"), systemImage: "link") }
                        Toggle(L.tr("downloads.autoImport"), isOn: $app.settings.autoImportDownloads)
                        Toggle(L.tr("downloads.deleteAfter"), isOn: $app.settings.deleteAfterImport)
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .alert(L.tr("downloads.fromLink"), isPresented: $showLink) {
                TextField("https://…", text: $linkText).textInputAutocapitalization(.never)
                Button(L.tr("common.cancel"), role: .cancel) {}
                Button(L.tr("downloads.download")) {
                    if let u = URL(string: linkText) { app.downloads.start(name: u.lastPathComponent, url: u) }
                    linkText = ""
                }
            }
        }
    }
}

struct ActiveDownloadRow: View {
    @EnvironmentObject private var app: AppState
    let task: DownloadTask

    var body: some View {
        HStack(spacing: 12) {
            AppIconThumb(name: task.name, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(task.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                ProgressView(value: task.fraction).tint(Color.graphite)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Button {
                task.state == .paused ? app.downloads.resume(task.id) : app.downloads.pause(task.id)
            } label: {
                Image(systemName: task.state == .paused ? "arrow.clockwise" : "pause").font(.caption)
            }
            .buttonStyle(.bordered).tint(Color.graphite)
        }
    }

    private var subtitle: String {
        if task.state == .queued { return L.tr("downloads.queued") }
        let w = ByteCountFormatter.string(fromByteCount: task.bytesWritten, countStyle: .file)
        let t = ByteCountFormatter.string(fromByteCount: task.totalBytes, countStyle: .file)
        return "\(w) / \(t)"
    }
}

struct FinishedDownloadRow: View {
    @EnvironmentObject private var app: AppState
    let task: DownloadTask

    var body: some View {
        HStack(spacing: 12) {
            AppIconThumb(name: task.name, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                if task.state == .failed {
                    Text(L.tr("downloads.failed")).font(.caption).foregroundStyle(Color.brick)
                } else {
                    Text(L.tr("downloads.imported")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if task.state == .failed {
                Button { app.downloads.retry(task.id) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(Color.graphite)
            } else {
                Image(systemName: "checkmark").foregroundStyle(Color.moss)
            }
        }
    }
}
