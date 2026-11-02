import SwiftUI
import UIKit

/// Resultado de adicionar cada fonte.
private enum AddResult {
    case success(Source)
    case failure(String)
}

struct AddSourcesView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var working = false
    @State private var results: [AddResult] = []

    private var urls: [URL] {
        text.components(separatedBy: .newlines)
            .flatMap { $0.components(separatedBy: .whitespaces) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
            .compactMap { URL(string: $0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 90)
                        .font(.callout.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button {
                        if let s = UIPasteboard.general.string {
                            text = text.isEmpty ? s : text + "\n" + s
                        }
                    } label: { Label(L.tr("addsource.paste"), systemImage: "doc.on.clipboard") }
                } header: {
                    Text(L.tr("addsource.urls"))
                } footer: {
                    Text(L.tr("addsource.hint"))
                }

                if !results.isEmpty {
                    Section(L.tr("addsource.found")) {
                        ForEach(results.indices, id: \.self) { i in
                            switch results[i] {
                            case .success(let s):
                                HStack {
                                    AppIconThumb(name: s.name, url: s.iconURL, size: 32)
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
                    Button {
                        Task { await add() }
                    } label: {
                        if working {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(L.tr("addsource.add", urls.count))
                        }
                    }
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
                if let s = app.sources.first(where: { $0.url.absoluteString.lowercased() == url.absoluteString.lowercased() }) ?? app.sources.last {
                    results.append(.success(s))
                }
            } catch {
                results.append(.failure("\(url.host ?? url.absoluteString): \(error.localizedDescription)"))
            }
        }
        working = false
        if !results.isEmpty && results.allSatisfy({ if case .success = $0 { return true } else { return false } }) {
            dismiss()
        }
    }
}
