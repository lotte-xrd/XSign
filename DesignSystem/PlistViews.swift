import SwiftUI
import UIKit

// MARK: - Lista de um dicionário/array (somente leitura ou editável)

struct PlistContainerView: View {
    @ObservedObject var node: PlistNode
    var editable: Bool
    var onEdit: (() -> Void)?
    var title: String? = nil

    @State private var query = ""
    @State private var editing: PlistNode?
    @State private var adding: PlistNode?

    private var filtered: [PlistNode] {
        query.isEmpty ? node.children : node.children.filter { $0.matches(query) }
    }

    var body: some View {
        List {
            if node.children.isEmpty {
                Text(L.tr("plist.empty"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(filtered) { child in
                PlistRow(
                    node: child,
                    parentIsArray: node.kind == .array,
                    editable: editable,
                    onEdit: onEdit,
                    onTapLeaf: { editing = child }
                )
            }
            .onDelete(perform: deleteAction)
        }
        .searchable(text: $query, prompt: L.tr("common.search"))
        .navigationTitle(title ?? (node.key.isEmpty ? "Root" : node.key))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if editable {
                    Button {
                        adding = PlistNode(key: nextKeyName(), kind: .string)
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(item: $editing) { target in
            PlistValueEditor(node: target, parentIsArray: node.kind == .array, isNew: false) { _ in
                onEdit?()
            }
        }
        .sheet(item: $adding) { fresh in
            PlistValueEditor(node: fresh, parentIsArray: node.kind == .array, isNew: true) { created in
                node.children.append(created)
                node.renumberIfArray()
                onEdit?()
            }
        }
    }

    private var deleteAction: ((IndexSet) -> Void)? {
        guard editable else { return nil }
        return { offsets in delete(offsets) }
    }

    private func delete(_ offsets: IndexSet) {
        let targets = Set(offsets.map { filtered[$0].id })
        node.children.removeAll { targets.contains($0.id) }
        node.renumberIfArray()
        onEdit?()
    }

    private func nextKeyName() -> String {
        if node.kind == .array { return "\(node.children.count)" }
        var i = 1
        var candidate = "NewKey"
        while node.children.contains(where: { $0.key == candidate }) {
            i += 1
            candidate = "NewKey\(i)"
        }
        return candidate
    }
}

// MARK: - Linha

struct PlistRow: View {
    @ObservedObject var node: PlistNode
    let parentIsArray: Bool
    let editable: Bool
    let onEdit: (() -> Void)?
    let onTapLeaf: () -> Void

    var body: some View {
        if node.kind.isContainer {
            NavigationLink {
                PlistContainerView(node: node, editable: editable, onEdit: onEdit)
            } label: {
                label
            }
        } else if editable {
            Button(action: onTapLeaf) { label }
                .foregroundStyle(Color.graphite)
        } else {
            label
        }
    }

    private var keyTitle: String {
        parentIsArray ? "Item \(node.key)" : node.key
    }

    private var label: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(keyTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(3)
                Text(node.kind.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if node.kind == .boolean {
                Image(systemName: node.boolean ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(node.boolean ? Color.moss : Color.ash)
            } else {
                Text(node.summary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .multilineTextAlignment(.trailing)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                UIPasteboard.general.string = node.key
            } label: {
                Label(L.tr("plist.copyKey"), systemImage: "key")
            }
            Button {
                UIPasteboard.general.string = node.kind.isContainer ? node.xmlString() : node.summary
            } label: {
                Label(L.tr("plist.copyValue"), systemImage: "doc.on.doc")
            }
        }
    }
}

// MARK: - Editor de um valor

struct PlistValueEditor: View {
    @Environment(\.dismiss) private var dismiss
    let node: PlistNode
    let parentIsArray: Bool
    let isNew: Bool
    let onCommit: (PlistNode) -> Void

    @State private var key: String
    @State private var kind: PlistNode.Kind
    @State private var text: String
    @State private var bool: Bool
    @State private var date: Date
    @State private var error: String?

    init(node: PlistNode, parentIsArray: Bool, isNew: Bool, onCommit: @escaping (PlistNode) -> Void) {
        self.node = node
        self.parentIsArray = parentIsArray
        self.isNew = isNew
        self.onCommit = onCommit
        _key = State(initialValue: node.key)
        _kind = State(initialValue: node.kind)
        _bool = State(initialValue: node.boolean)
        _date = State(initialValue: node.date)
        let initialText: String
        switch node.kind {
        case .string: initialText = node.string
        case .integer: initialText = "\(node.integer)"
        case .real: initialText = "\(node.real)"
        case .data: initialText = node.data.map { String(format: "%02x", $0) }.joined()
        default: initialText = ""
        }
        _text = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !parentIsArray {
                    Section(L.tr("plist.key")) {
                        TextField(L.tr("plist.key"), text: $key)
                            .font(.callout.monospaced())
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }
                Section(L.tr("plist.type")) {
                    Picker(L.tr("plist.type"), selection: $kind) {
                        ForEach(PlistNode.Kind.allCases) { k in
                            Text(k.label).tag(k)
                        }
                    }
                }
                Section(L.tr("plist.value")) {
                    switch kind {
                    case .string:
                        TextField(L.tr("plist.value"), text: $text, axis: .vertical)
                            .font(.callout.monospaced())
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    case .integer, .real:
                        TextField("0", text: $text)
                            .keyboardType(kind == .integer ? .numbersAndPunctuation : .decimalPad)
                            .font(.callout.monospaced())
                    case .boolean:
                        Toggle(bool ? "true" : "false", isOn: $bool)
                    case .date:
                        DatePicker(L.tr("plist.value"), selection: $date)
                    case .data:
                        TextField("hex", text: $text, axis: .vertical)
                            .font(.callout.monospaced())
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    case .dictionary, .array:
                        Text(L.tr("plist.containerHint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.brick)
                    }
                }
            }
            .navigationTitle(isNew ? L.tr("plist.newItem") : L.tr("plist.editItem"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.tr("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.tr("common.save")) { save() }
                        .disabled(!parentIsArray && key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        error = nil
        switch kind {
        case .integer:
            guard let v = Int(text.trimmingCharacters(in: .whitespaces)) else {
                error = L.tr("plist.error.number"); return
            }
            node.integer = v
        case .real:
            guard let v = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) else {
                error = L.tr("plist.error.number"); return
            }
            node.real = v
        case .data:
            guard let d = Self.dataFromHex(text) else {
                error = L.tr("plist.error.hex"); return
            }
            node.data = d
        case .string:
            node.string = text
        case .boolean:
            node.boolean = bool
        case .date:
            node.date = date
        case .dictionary, .array:
            break
        }
        if !parentIsArray { node.key = key.trimmingCharacters(in: .whitespaces) }
        node.setKind(kind)
        onCommit(node)
        dismiss()
    }

    static func dataFromHex(_ raw: String) -> Data? {
        let clean = raw.filter { !$0.isWhitespace && $0 != "<" && $0 != ">" }
        guard clean.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let b = UInt8(clean[index..<next], radix: 16) else { return nil }
            bytes.append(b)
            index = next
        }
        return Data(bytes)
    }
}

// MARK: - Entitlements (somente leitura)

struct EntitlementsView: View {
    let title: String
    @StateObject private var root: PlistNode
    @State private var copied = false

    init(title: String, dictionary: [String: Any]) {
        self.title = title
        _root = StateObject(wrappedValue: PlistNode(key: title, value: dictionary))
    }

    var body: some View {
        PlistContainerView(node: root, editable: false, onEdit: nil, title: title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = root.xmlString()
                        withAnimation(.xsignSmooth) { copied = true }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(root.children.isEmpty)
                }
            }
    }
}
