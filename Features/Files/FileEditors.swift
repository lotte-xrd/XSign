import SwiftUI
import UIKit

// MARK: - Editor de texto

struct TextFileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL

    @State private var text = ""
    @State private var original = ""
    @State private var loaded = false
    @State private var errorMessage: String?
    @State private var showDiscard = false
    @State private var encoding: String.Encoding = .utf8

    private static let maxSize = 3 * 1024 * 1024
    private var dirty: Bool { loaded && text != original }

    var body: some View {
        NavigationStack {
            Group {
                if let errorMessage {
                    EmptyStateView(title: L.tr("fm.cantOpen"), message: errorMessage, systemImage: "exclamationmark.triangle")
                } else if !loaded {
                    ProgressView()
                } else {
                    TextEditor(text: $text)
                        .font(.system(size: 13, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.surface.ignoresSafeArea())
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.tr("common.close")) {
                        if dirty { showDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.tr("common.save")) { save() }
                        .disabled(!dirty)
                }
            }
            .confirmationDialog(L.tr("fm.unsaved"), isPresented: $showDiscard, titleVisibility: .visible) {
                Button(L.tr("common.save")) {
                    save()
                    dismiss()
                }
                Button(L.tr("fm.discard"), role: .destructive) { dismiss() }
            }
        }
        .task { load() }
    }

    private func load() {
        guard !loaded else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= Self.maxSize else {
            errorMessage = L.tr("fm.tooLarge")
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = L.tr("fm.cantRead")
            return
        }
        if let s = String(data: data, encoding: .utf8) {
            encoding = .utf8
            text = s
        } else if let s = String(data: data, encoding: .isoLatin1) {
            encoding = .isoLatin1
            text = s
        } else {
            errorMessage = L.tr("fm.notText")
            return
        }
        original = text
        loaded = true
    }

    private func save() {
        guard let data = text.data(using: encoding) ?? text.data(using: .utf8) else { return }
        do {
            try data.write(to: url, options: .atomic)
            original = text
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Editor de .plist

struct PlistFileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL

    @State private var root: PlistNode?
    @State private var format: PropertyListSerialization.PropertyListFormat = .xml
    @State private var dirty = false
    @State private var errorMessage: String?
    @State private var saveError: String?
    @State private var showDiscard = false

    var body: some View {
        NavigationStack {
            Group {
                if let root {
                    PlistContainerView(node: root, editable: true, onEdit: { dirty = true }, title: url.lastPathComponent)
                } else if let errorMessage {
                    EmptyStateView(title: L.tr("fm.cantOpen"), message: errorMessage, systemImage: "exclamationmark.triangle")
                } else {
                    ProgressView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.tr("common.close")) {
                        if dirty { showDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.tr("common.save")) { save() }
                        .disabled(!dirty)
                }
            }
            .confirmationDialog(L.tr("fm.unsaved"), isPresented: $showDiscard, titleVisibility: .visible) {
                Button(L.tr("common.save")) {
                    if save() { dismiss() }
                }
                Button(L.tr("fm.discard"), role: .destructive) { dismiss() }
            }
            .alert(L.tr("common.notice"), isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
        .task { load() }
    }

    private func load() {
        guard root == nil else { return }
        do {
            let data = try Data(contentsOf: url)
            var detected = PropertyListSerialization.PropertyListFormat.xml
            let object = try PropertyListSerialization.propertyList(from: data, options: [], format: &detected)
            format = detected
            root = PlistNode(key: url.lastPathComponent, value: object)
        } catch {
            errorMessage = L.tr("fm.notPlist")
        }
    }

    @discardableResult
    private func save() -> Bool {
        guard let root else { return false }
        do {
            let outFormat: PropertyListSerialization.PropertyListFormat = (format == .binary) ? .binary : .xml
            let data = try PropertyListSerialization.data(fromPropertyList: root.toAny(), format: outFormat, options: 0)
            try data.write(to: url, options: .atomic)
            dirty = false
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }
}

// MARK: - Visualizador hexadecimal

final class HexFileSource: ObservableObject {
    static let bytesPerRow = 8
    static let rowsPerPage = 512
    static var pageBytes: Int { bytesPerRow * rowsPerPage }

    let url: URL
    let size: Int
    private let handle: FileHandle?
    @Published private(set) var page = 0
    @Published private(set) var pageData = Data()

    var pageCount: Int { max(1, (size + Self.pageBytes - 1) / Self.pageBytes) }
    var rowCount: Int { (pageData.count + Self.bytesPerRow - 1) / Self.bytesPerRow }
    var pageStart: Int { page * Self.pageBytes }

    init(url: URL) {
        self.url = url
        self.size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        self.handle = try? FileHandle(forReadingFrom: url)
        load(page: 0)
    }

    deinit {
        try? handle?.close()
    }

    func load(page newPage: Int) {
        let clamped = min(max(0, newPage), pageCount - 1)
        page = clamped
        guard let handle else { pageData = Data(); return }
        try? handle.seek(toOffset: UInt64(clamped * Self.pageBytes))
        pageData = (try? handle.read(upToCount: Self.pageBytes)) ?? Data()
    }

    func row(_ index: Int) -> (offset: String, hex: String, ascii: String) {
        let start = index * Self.bytesPerRow
        let end = min(start + Self.bytesPerRow, pageData.count)
        guard start < end else { return ("", "", "") }
        let bytes = pageData.subdata(in: start..<end)
        var hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        let padding = (Self.bytesPerRow - bytes.count) * 3
        if padding > 0 { hex += String(repeating: " ", count: padding) }
        let ascii = String(bytes.map { (32...126).contains($0) ? Character(UnicodeScalar($0)) : "." })
        return (String(format: "%08X", pageStart + start), hex, ascii)
    }

    /// Procura o padrão a partir de `offset` (arquivo inteiro, em blocos de 1 MB).
    func find(_ pattern: [UInt8], from offset: Int) -> Int? {
        guard !pattern.isEmpty, let reader = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? reader.close() }
        let chunk = 1024 * 1024
        var position = max(0, offset)
        while position < size {
            guard (try? reader.seek(toOffset: UInt64(position))) != nil,
                  let data = try? reader.read(upToCount: chunk + pattern.count - 1), !data.isEmpty else { return nil }
            if let range = data.range(of: Data(pattern)) {
                return position + (range.lowerBound - data.startIndex)
            }
            position += chunk
        }
        return nil
    }
}

struct HexViewerView: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    @StateObject private var source: HexFileSource

    @State private var query = ""
    @State private var searchAsText = false
    @State private var match: Int?
    @State private var notFound = false
    @State private var showGoTo = false
    @State private var goToText = ""

    init(url: URL) {
        self.url = url
        _source = StateObject(wrappedValue: HexFileSource(url: url))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(0..<source.rowCount, id: \.self) { index in
                        let row = source.row(index)
                        HStack(spacing: 10) {
                            Text(row.offset).foregroundStyle(.tertiary)
                            Text(row.hex)
                            Text(row.ascii).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 8))
                        .listRowBackground(isMatchRow(index) ? Color.ochre.opacity(0.25) : Color.surface)
                        .id(index)
                    }
                }
                .listStyle(.plain)
                .onChange(of: match) { newValue in
                    guard let newValue else { return }
                    let rowIndex = (newValue - source.pageStart) / HexFileSource.bytesPerRow
                    withAnimation(.xsignSmooth) { proxy.scrollTo(rowIndex, anchor: .center) }
                }
            }
            .searchable(text: $query, prompt: searchAsText ? L.tr("hex.searchText") : L.tr("hex.searchHex"))
            .onSubmit(of: .search) { search() }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.tr("common.close")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker(L.tr("hex.searchMode"), selection: $searchAsText) {
                            Text("Hex").tag(false)
                            Text(L.tr("hex.text")).tag(true)
                        }
                        Button {
                            goToText = ""
                            showGoTo = true
                        } label: {
                            Label(L.tr("hex.goTo"), systemImage: "arrow.right.to.line")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { source.load(page: source.page - 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(source.page == 0)
                    Spacer()
                    Text(L.tr("hex.page", source.page + 1, source.pageCount, ByteCountFormatter.string(fromByteCount: Int64(source.size), countStyle: .file)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { source.load(page: source.page + 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(source.page >= source.pageCount - 1)
                }
            }
            .alert(L.tr("hex.goTo"), isPresented: $showGoTo) {
                TextField("0x0000", text: $goToText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button(L.tr("common.cancel"), role: .cancel) {}
                Button("OK") { goTo(goToText) }
            }
            .alert(L.tr("hex.notFound"), isPresented: $notFound) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private func isMatchRow(_ index: Int) -> Bool {
        guard let match else { return false }
        let rowStart = source.pageStart + index * HexFileSource.bytesPerRow
        return match >= rowStart && match < rowStart + HexFileSource.bytesPerRow
    }

    private func pattern() -> [UInt8]? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if searchAsText { return Array(trimmed.utf8) }
        return PlistValueEditor.dataFromHex(trimmed.replacingOccurrences(of: "0x", with: "")).map { Array($0) }
    }

    private func search() {
        guard let bytes = pattern() else { return }
        let start = (match ?? -1) + 1
        if let found = source.find(bytes, from: start) ?? source.find(bytes, from: 0) {
            jump(to: found)
        } else {
            match = nil
            notFound = true
        }
    }

    private func goTo(_ raw: String) {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value: Int?
        if clean.hasPrefix("0x") {
            value = Int(clean.dropFirst(2), radix: 16)
        } else {
            value = Int(clean) ?? Int(clean, radix: 16)
        }
        guard let offset = value, offset >= 0, offset < max(1, source.size) else { return }
        jump(to: offset)
    }

    private func jump(to offset: Int) {
        let targetPage = offset / HexFileSource.pageBytes
        if targetPage != source.page { source.load(page: targetPage) }
        match = nil
        DispatchQueue.main.async { match = offset }
    }
}
