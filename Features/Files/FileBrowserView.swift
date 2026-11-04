import SwiftUI
import UIKit
import QuickLook
import ZIPFoundation

// MARK: - Modelo de item

struct FileEntry: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let isDirectory: Bool
    let size: Int64
    let modified: Date?
    let childCount: Int

    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }

    static let textExtensions: Set<String> = [
        "txt", "json", "xml", "md", "log", "strings", "js", "css", "html", "htm", "sh",
        "yml", "yaml", "csv", "ini", "conf", "cfg", "swift", "h", "m", "c", "cpp", "py", "entitlements"
    ]
    static let previewExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "webp", "pdf", "mp4", "mov", "m4a", "mp3", "wav", "rtf", "docx", "xlsx", "pptx"
    ]

    var isPlist: Bool { ext == "plist" || ext == "entitlements" }
    var isText: Bool { Self.textExtensions.contains(ext) && ext != "entitlements" }
    var isZip: Bool { ext == "zip" }
    var isCertificateFile: Bool { ext == "p12" || ext == "pfx" || ext == "mobileprovision" }
    var isTweak: Bool { ext == "dylib" || ext == "deb" || ext == "framework" || ext == "bundle" }

    var symbol: String {
        if isDirectory {
            switch ext {
            case "app": return "app.badge"
            case "framework", "bundle": return "shippingbox"
            default: return "folder.fill"
            }
        }
        switch ext {
        case "ipa": return "app.badge"
        case "p12", "pfx", "mobileprovision": return "checkmark.seal"
        case "deb", "dylib": return "puzzlepiece.extension"
        case "zip": return "doc.zipper"
        case "plist", "entitlements": return "list.bullet.rectangle"
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return "photo"
        case "pdf": return "doc.richtext"
        case "mp4", "mov": return "film"
        case "m4a", "mp3", "wav": return "waveform"
        default: return isText ? "doc.text" : "doc"
        }
    }

    static func load(_ url: URL) -> FileEntry {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        let isDir = values?.isDirectory ?? false
        let count = isDir ? ((try? FileManager.default.contentsOfDirectory(atPath: url.path))?.filter { !$0.hasPrefix(".") }.count ?? 0) : 0
        return FileEntry(
            url: url,
            isDirectory: isDir,
            size: Int64(values?.fileSize ?? 0),
            modified: values?.contentModificationDate,
            childCount: count
        )
    }
}

/// O que abrir em tela cheia a partir do gerenciador.
enum FileOpenTarget: Identifiable {
    case text(URL)
    case plist(URL)
    case hex(URL)
    case preview(URL)
    case certificate([URL])
    case info(FileEntry)

    var id: String {
        switch self {
        case .text(let u): return "text:" + u.path
        case .plist(let u): return "plist:" + u.path
        case .hex(let u): return "hex:" + u.path
        case .preview(let u): return "preview:" + u.path
        case .certificate(let us): return "cert:" + us.map { $0.path }.joined(separator: "|")
        case .info(let e): return "info:" + e.id
        }
    }
}

// MARK: - Navegador de pasta

struct FileBrowserView: View {
    @EnvironmentObject private var app: AppState
    let directory: URL
    var title: String? = nil

    @State private var entries: [FileEntry] = []
    @State private var query = ""
    @State private var selecting = false
    @State private var selection: Set<String> = []

    @State private var openTarget: FileOpenTarget?
    @State private var shareURLs: [URL] = []
    @State private var showShare = false
    @State private var moveURLs: [URL] = []
    @State private var showMove = false
    @State private var showImporter = false

    @State private var renameTarget: FileEntry?
    @State private var renameText = ""
    @State private var showNewFolder = false
    @State private var showNewText = false
    @State private var newName = ""
    @State private var deleteTargets: [URL] = []
    @State private var showDeleteConfirm = false
    @State private var toast: String?

    private var fm: FileManager { .default }

    private var filtered: [FileEntry] {
        query.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if entries.isEmpty {
                EmptyStateView(title: L.tr("fm.empty.title"), message: L.tr("fm.empty.message"), systemImage: "folder")
                    .listRowBackground(Color.clear)
            }
            ForEach(filtered) { entry in
                row(entry)
            }
        }
        .navigationTitle(title ?? directory.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: L.tr("common.search"))
        .refreshable { reload() }
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) {
            if selecting { selectionBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, selecting ? 90 : 24)
                    .transition(.motionBlur)
            }
        }
        .onAppear(perform: reload)
        .sheet(item: $openTarget, onDismiss: reload) { target in
            openView(for: target)
        }
        .sheet(isPresented: $showShare) { ShareSheet(items: shareURLs) }
        .sheet(isPresented: $showMove, onDismiss: reload) {
            FolderPickerView(root: Paths.documents, excluding: moveURLs) { destination in
                move(moveURLs, to: destination)
            }
        }
        .sheet(isPresented: $showImporter) {
            DocumentPicker(allowsMultipleSelection: true) { urls in importFiles(urls) }
        }
        .alert(L.tr("fm.rename"), isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField(L.tr("fm.name"), text: $renameText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button(L.tr("common.cancel"), role: .cancel) { renameTarget = nil }
            Button(L.tr("common.save")) {
                if let target = renameTarget { rename(target, to: renameText) }
                renameTarget = nil
            }
        }
        .alert(L.tr("fm.newFolder"), isPresented: $showNewFolder) {
            TextField(L.tr("fm.name"), text: $newName)
            Button(L.tr("common.cancel"), role: .cancel) {}
            Button(L.tr("fm.create")) { createFolder(newName) }
        }
        .alert(L.tr("fm.newText"), isPresented: $showNewText) {
            TextField(L.tr("fm.name"), text: $newName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button(L.tr("common.cancel"), role: .cancel) {}
            Button(L.tr("fm.create")) { createTextFile(newName) }
        }
        .confirmationDialog(L.tr("fm.deleteConfirm", deleteTargets.count), isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button(L.tr("common.delete"), role: .destructive) { delete(deleteTargets) }
        }
    }

    // MARK: Linha

    @ViewBuilder
    private func row(_ entry: FileEntry) -> some View {
        let content = HStack(spacing: 12) {
            if selecting {
                Image(systemName: selection.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selection.contains(entry.id) ? Color.graphite : Color.ash)
            }
            Image(systemName: entry.symbol)
                .font(.title3)
                .foregroundStyle(entry.isDirectory ? Color.graphite : Color.lead)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(subtitle(entry))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())

        Group {
            if selecting {
                Button { toggle(entry) } label: { content }
                    .buttonStyle(.plain)
            } else if entry.isDirectory && entry.ext != "app" {
                NavigationLink {
                    FileBrowserView(directory: entry.url)
                } label: { content }
            } else {
                Button { open(entry) } label: { content }
                    .buttonStyle(.plain)
            }
        }
        .contextMenu { contextMenu(for: entry) }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleteTargets = [entry.url]
                showDeleteConfirm = true
            } label: { Label(L.tr("common.delete"), systemImage: "trash") }
            Button {
                shareURLs = [entry.url]
                showShare = true
            } label: { Label(L.tr("fm.share"), systemImage: "square.and.arrow.up") }
            .tint(Color.lead)
        }
    }

    private func subtitle(_ entry: FileEntry) -> String {
        var parts: [String] = []
        if entry.isDirectory {
            parts.append(L.tr("fm.items", entry.childCount))
        } else {
            parts.append(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
        }
        if let date = entry.modified {
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func contextMenu(for entry: FileEntry) -> some View {
        if !entry.isDirectory {
            Menu {
                Button { openTarget = .text(entry.url) } label: { Label(L.tr("fm.open.text"), systemImage: "doc.text") }
                Button { openTarget = .plist(entry.url) } label: { Label(L.tr("fm.open.plist"), systemImage: "list.bullet.rectangle") }
                Button { openTarget = .hex(entry.url) } label: { Label(L.tr("fm.open.hex"), systemImage: "number") }
                Button { openTarget = .preview(entry.url) } label: { Label(L.tr("fm.open.preview"), systemImage: "eye") }
            } label: {
                Label(L.tr("fm.openAs"), systemImage: "arrow.up.forward.app")
            }
        }

        if entry.ext == "ipa" {
            Button { importIPA(entry.url) } label: { Label(L.tr("fm.importToApps"), systemImage: "square.stack.3d.up") }
        }
        if entry.isCertificateFile || entry.isZip {
            Button { openTarget = .certificate([entry.url]) } label: { Label(L.tr("fm.importCert"), systemImage: "checkmark.seal") }
        }
        if entry.isTweak && entry.url.deletingLastPathComponent().standardizedFileURL != Paths.tweaks.standardizedFileURL {
            Button { addToTweaks(entry.url) } label: { Label(L.tr("fm.addToTweaks"), systemImage: "puzzlepiece.extension") }
        }
        if entry.isZip || entry.ext == "ipa" {
            Button { extract(entry) } label: { Label(L.tr("fm.extract"), systemImage: "arrow.up.bin") }
        }
        if entry.ext == "deb" {
            Button { extractDeb(entry) } label: { Label(L.tr("fm.extract"), systemImage: "arrow.up.bin") }
        }

        Divider()

        Button {
            renameText = entry.name
            renameTarget = entry
        } label: { Label(L.tr("fm.rename"), systemImage: "pencil") }
        Button { duplicate(entry.url) } label: { Label(L.tr("fm.duplicate"), systemImage: "plus.square.on.square") }
        Button {
            moveURLs = [entry.url]
            showMove = true
        } label: { Label(L.tr("fm.move"), systemImage: "folder") }
        Button { compress([entry.url]) } label: { Label(L.tr("fm.compress"), systemImage: "doc.zipper") }
        Button {
            shareURLs = [entry.url]
            showShare = true
        } label: { Label(L.tr("fm.share"), systemImage: "square.and.arrow.up") }
        Button {
            UIPasteboard.general.string = entry.url.path
            flash(L.tr("fm.pathCopied"))
        } label: { Label(L.tr("fm.copyPath"), systemImage: "link") }

        Divider()

        Button(role: .destructive) {
            deleteTargets = [entry.url]
            showDeleteConfirm = true
        } label: { Label(L.tr("common.delete"), systemImage: "trash") }
    }

    // MARK: Barra de ferramentas

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if selecting {
                Button(L.tr("common.done")) {
                    withAnimation(.xsignSmooth) {
                        selecting = false
                        selection.removeAll()
                    }
                }
            } else {
                Menu {
                    Button { showImporter = true } label: { Label(L.tr("fm.import"), systemImage: "square.and.arrow.down") }
                    Button {
                        newName = ""
                        showNewFolder = true
                    } label: { Label(L.tr("fm.newFolder"), systemImage: "folder.badge.plus") }
                    Button {
                        newName = "novo.txt"
                        showNewText = true
                    } label: { Label(L.tr("fm.newText"), systemImage: "doc.badge.plus") }
                    Divider()
                    Button {
                        withAnimation(.xsignSmooth) { selecting = true }
                    } label: { Label(L.tr("bulk.select"), systemImage: "checkmark.circle") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private var selectionBar: some View {
        let urls = entries.filter { selection.contains($0.id) }.map { $0.url }
        return HStack(spacing: 0) {
            barButton("square.and.arrow.up", L.tr("fm.share"), enabled: !urls.isEmpty) {
                shareURLs = urls
                showShare = true
            }
            barButton("folder", L.tr("fm.move"), enabled: !urls.isEmpty) {
                moveURLs = urls
                showMove = true
            }
            barButton("doc.zipper", L.tr("fm.compress"), enabled: !urls.isEmpty) {
                compress(urls)
            }
            barButton("trash", L.tr("common.delete"), enabled: !urls.isEmpty, destructive: true) {
                deleteTargets = urls
                showDeleteConfirm = true
            }
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func barButton(_ icon: String, _ title: String, enabled: Bool, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.body)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(destructive ? Color.brick : Color.graphite)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    // MARK: Abrir

    @ViewBuilder
    private func openView(for target: FileOpenTarget) -> some View {
        switch target {
        case .text(let url):
            TextFileEditorView(url: url)
        case .plist(let url):
            PlistFileEditorView(url: url)
        case .hex(let url):
            HexViewerView(url: url)
        case .preview(let url):
            NavigationStack {
                QuickLookPreview(url: url)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle(url.lastPathComponent)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L.tr("common.close")) { openTarget = nil }
                        }
                    }
            }
        case .certificate(let urls):
            NavigationStack {
                CertificateFilesImportView(source: .files, prefilled: urls, onDone: { openTarget = nil })
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L.tr("common.cancel")) { openTarget = nil }
                        }
                    }
            }
            .environmentObject(app)
        case .info(let entry):
            NavigationStack {
                List {
                    LabeledContent(L.tr("fm.name"), value: entry.name)
                    LabeledContent(L.tr("detail.size"), value: ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                    if let d = entry.modified {
                        LabeledContent(L.tr("fm.modified"), value: d.formatted(date: .abbreviated, time: .standard))
                    }
                    Text(entry.url.path).font(.caption.monospaced()).textSelection(.enabled)
                }
                .navigationTitle(entry.name)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private func open(_ entry: FileEntry) {
        if entry.ext == "app" {
            openTarget = .info(entry)
        } else if entry.isPlist {
            openTarget = .plist(entry.url)
        } else if entry.isText {
            openTarget = .text(entry.url)
        } else if FileEntry.previewExtensions.contains(entry.ext) {
            openTarget = .preview(entry.url)
        } else if entry.isCertificateFile {
            openTarget = .certificate([entry.url])
        } else {
            openTarget = .hex(entry.url)
        }
    }

    // MARK: Operações

    private func reload() {
        let urls = (try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let loaded = urls.map(FileEntry.load).sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        withAnimation(.xsignSmooth) {
            entries = loaded
            selection = selection.filter { id in loaded.contains { $0.id == id } }
        }
    }

    private func toggle(_ entry: FileEntry) {
        withAnimation(.xsignSmooth) {
            if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
        }
    }

    private func flash(_ message: String) {
        withAnimation(.xsignSmooth) { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.xsignSmooth) { if toast == message { toast = nil } }
        }
    }

    private func fail(_ error: Error) {
        flash(error.localizedDescription)
    }

    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        var i = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    private func rename(_ entry: FileEntry, to raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !name.isEmpty, name != entry.name else { return }
        let dest = entry.url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            guard !fm.fileExists(atPath: dest.path) else { flash(L.tr("fm.exists")); return }
            try fm.moveItem(at: entry.url, to: dest)
            reload()
        } catch { fail(error) }
    }

    private func duplicate(_ url: URL) {
        do {
            try fm.copyItem(at: url, to: Self.uniqueURL(url))
            reload()
        } catch { fail(error) }
    }

    private func move(_ urls: [URL], to destination: URL) {
        var moved = 0
        for url in urls {
            let target = Self.uniqueURL(destination.appendingPathComponent(url.lastPathComponent))
            if (try? fm.moveItem(at: url, to: target)) != nil { moved += 1 }
        }
        selecting = false
        selection.removeAll()
        reload()
        flash(L.tr("fm.moved", moved))
    }

    private func delete(_ urls: [URL]) {
        for url in urls { try? fm.removeItem(at: url) }
        selection.removeAll()
        reload()
    }

    private func createFolder(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try fm.createDirectory(at: Self.uniqueURL(directory.appendingPathComponent(name)), withIntermediateDirectories: true)
            reload()
        } catch { fail(error) }
    }

    private func createTextFile(_ raw: String) {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if !name.contains(".") { name += ".txt" }
        let url = Self.uniqueURL(directory.appendingPathComponent(name))
        if fm.createFile(atPath: url.path, contents: Data()) {
            reload()
            openTarget = .text(url)
        }
    }

    private func importFiles(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try? fm.copyItem(at: url, to: Self.uniqueURL(directory.appendingPathComponent(url.lastPathComponent)))
        }
        reload()
    }

    private func importIPA(_ url: URL) {
        do {
            let item = try app.importIPA(from: url, origin: L.tr("tab.files"), downloadURL: nil)
            flash(L.tr("fm.importedApp", item.name))
        } catch { fail(error) }
    }

    private func addToTweaks(_ url: URL) {
        Paths.ensure()
        let dest = Paths.tweaks.appendingPathComponent(url.lastPathComponent)
        try? fm.removeItem(at: dest)
        do {
            try fm.copyItem(at: url, to: dest)
            flash(L.tr("fm.addedTweak", url.lastPathComponent))
        } catch { fail(error) }
    }

    private func runHeavy(_ title: String, _ work: @escaping () throws -> Void) {
        app.activeHUDTitle = title
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Error? in
                do { try work(); return nil } catch { return error }
            }.value
            app.activeHUDTitle = nil
            reload()
            if let result { fail(result) }
        }
    }

    private func compress(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let dir = directory
        let single: URL? = urls.count == 1 ? urls[0] : nil
        let destName = single.map { $0.deletingPathExtension().lastPathComponent } ?? L.tr("fm.archiveName")
        let dest = Self.uniqueURL(dir.appendingPathComponent("\(destName).zip"))
        runHeavy(L.tr("fm.compressing")) {
            let fm = FileManager.default
            if let single {
                try fm.zipItem(at: single, to: dest, shouldKeepParent: true, compressionMethod: .deflate)
            } else {
                let staging = fm.temporaryDirectory.appendingPathComponent("xsign-zip-\(UUID().uuidString)", isDirectory: true)
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: staging) }
                for url in urls {
                    try fm.copyItem(at: url, to: staging.appendingPathComponent(url.lastPathComponent))
                }
                try fm.zipItem(at: staging, to: dest, shouldKeepParent: false, compressionMethod: .deflate)
            }
        }
        selecting = false
        selection.removeAll()
    }

    private func extract(_ entry: FileEntry) {
        let dest = Self.uniqueURL(directory.appendingPathComponent(entry.url.deletingPathExtension().lastPathComponent, isDirectory: true))
        let source = entry.url
        runHeavy(L.tr("fm.extracting")) {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            try FileManager.default.unzipItem(at: source, to: dest)
        }
    }

    private func extractDeb(_ entry: FileEntry) {
        let dest = Self.uniqueURL(directory.appendingPathComponent(entry.url.deletingPathExtension().lastPathComponent, isDirectory: true))
        let source = entry.url
        runHeavy(L.tr("fm.extracting")) {
            try DebExtractor.extract(debURL: source, to: dest)
        }
    }
}

// MARK: - Escolher pasta de destino

struct FolderPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let root: URL
    let excluding: [URL]
    let onPick: (URL) -> Void

    var body: some View {
        NavigationStack {
            FolderPickerLevel(directory: root, excluding: excluding) { url in
                onPick(url)
                dismiss()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.tr("common.cancel")) { dismiss() }
                }
            }
        }
    }
}

private struct FolderPickerLevel: View {
    let directory: URL
    let excluding: [URL]
    let onPick: (URL) -> Void
    @State private var folders: [URL] = []

    var body: some View {
        List {
            ForEach(folders, id: \.path) { folder in
                NavigationLink {
                    FolderPickerLevel(directory: folder, excluding: excluding, onPick: onPick)
                } label: {
                    Label(folder.lastPathComponent, systemImage: "folder.fill")
                        .foregroundStyle(Color.graphite)
                }
            }
            if folders.isEmpty {
                Text(L.tr("fm.noSubfolders")).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(directory.standardizedFileURL == Paths.documents.standardizedFileURL ? "XSign" : directory.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            PrimaryButton(title: L.tr("fm.moveHere")) { onPick(directory) }
                .padding(Spacing.screen)
                .background(.bar)
        }
        .onAppear {
            let excluded = Set(excluding.map { $0.standardizedFileURL.path })
            folders = ((try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .filter { !excluded.contains($0.standardizedFileURL.path) }
            .filter { !["app", "framework", "bundle"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
    }
}

// MARK: - Quick Look

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewItem(at index: Int) -> QLPreviewItem { url as NSURL }
    }
}
