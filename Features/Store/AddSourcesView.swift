import SwiftUI
import UIKit

struct AddSourcesView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var working = false
    @State private var results: [Result<Source, String>] = []

    private var urls: [URL] {
        text.split(whereSeparator: \.isNewline)
            .compactMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L.tr("addsource.urls")) {
                    TextEditor(text: $text)
                        .frame(minHeight: 90)
                        .font(.callout.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button {
                        if let s = UIPasteboard.general.string { text = text.isEmpty ? s : text + "\n" + s }
                    } label: { Label(L.tr("addsource.paste"), systemImage: "doc.on.clipboard") }
                } footer: {
                    Text(L.tr("addsource.hint"))
                }

                if !results.isEmpty {
                    Section(L.tr("addsource.found")) {
                        ForEach(results.indices, id: \.self) { i in
                            switch results[i] {
                            case .success(let s):
                                HStack {
                                    AppIconThumb(name: s.name, size: 32)
                                    VStack(alignment: .leading) {
                                        Text(s.name).font(.subheadline.weight(.semibold))
                                        Text(L.tr("addsource.appcount", s.appCount)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "checkmark").foregroundStyle(Color.moss)
                                }
                            case .failure(let msg):
                                Label(msg, systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(Color.brick)
                            }
                        }
                    }
                }
            }
            .navigationTitle(L.tr("addsource.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.tr("common.cancel")) { app.pendingSourceURL = nil; dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.tr("addsource.add", urls.count)) { Task { await add() } }
                        .disabled(urls.isEmpty || working)
                }
            }
            .onAppear {
                if let u = app.pendingSourceURL { text = u.absoluteString; app.pendingSourceURL = nil }
            }
        }
    }

    private func add() async {
        working = true
        results = []
        for url in urls {
            do {
                try await app.addSource(url: url)
                if let s = app.sources.last { results.append(.success(s)) }
            } catch {
                results.append(.failure("\(url.host ?? url.absoluteString): \(error.localizedDescription)"))
            }
        }
        working = false
        if results.allSatisfy({ if case .success = $0 { return true } else { return false } }) { dismiss() }
    }
}
