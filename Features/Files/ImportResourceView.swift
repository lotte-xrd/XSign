import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Porta de entrada única (equivale ao "Import Resource" do ESign). O tipo do
/// arquivo decide o destino automaticamente.
struct ImportResourceView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var showLinkPrompt = false
    @State private var linkInput = ""
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    sourceRow(L.tr("import.fromFiles"), "folder") { showPicker = true }
                    sourceRow(L.tr("import.fromLink"), "link") { showLinkPrompt = true }
                    sourceRow(L.tr("import.fromClipboard"), "doc.on.clipboard") { importFromClipboard() }
                }

                if let statusMessage {
                    Section {
                        Label(statusMessage, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.moss)
                            .font(.subheadline)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.brick)
                            .font(.subheadline)
                    }
                }

                Section(L.tr("import.routing")) {
                    routeRow("IPA", L.tr("import.route.ipa"), "Apps")
                    routeRow("ZIP", L.tr("import.route.zip"), "Certificates")
                    routeRow("P12", L.tr("import.route.p12"), "Certificates")
                    routeRow("PROV", L.tr("import.route.prov"), "Certificates")
                    routeRow("DEB", L.tr("import.route.deb"), "Tweaks")
                    routeRow("JSON", L.tr("import.route.json"), "Sources")
                }
            }
            .navigationTitle(L.tr("import.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L.tr("common.cancel")) { dismiss() } }
            }
            .sheet(isPresented: $showPicker) {
                DocumentPicker(allowsMultipleSelection: true) { urls in
                    errorMessage = nil
                    var lastMsg: String?
                    for u in urls {
                        do {
                            lastMsg = try app.importResource(url: u)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    if errorMessage == nil {
                        statusMessage = lastMsg
                        dismiss()
                    }
                }
            }
            .alert(L.tr("import.fromLink"), isPresented: $showLinkPrompt) {
                TextField("https://…", text: $linkInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(L.tr("common.cancel"), role: .cancel) { linkInput = "" }
                Button(L.tr("importcert.import")) {
                    handleURLString(linkInput)
                    linkInput = ""
                }
            }
        }
    }

    static let types: [UTType] = [.item, .data, .content]

    private func importFromClipboard() {
        guard let str = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !str.isEmpty else {
            errorMessage = "A área de transferência está vazia."
            return
        }
        handleURLString(str)
    }

    private func handleURLString(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme == "http" || url.scheme == "https" else {
            errorMessage = "URL inválida."
            return
        }
        errorMessage = nil
        if url.pathExtension.lowercased() == "ipa" {
            app.downloads.start(name: url.deletingPathExtension().lastPathComponent, url: url)
            app.selectedTab = .downloads
            dismiss()
        } else {
            Task {
                do {
                    try await app.addSource(url: url)
                    app.selectedTab = .store
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func sourceRow(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 24).foregroundStyle(Color.graphite)
                Text(title).foregroundStyle(Color.graphite)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.ash)
            }
        }
    }

    private func routeRow(_ ext: String, _ desc: String, _ dest: String) -> some View {
        HStack(spacing: 12) {
            Text(ext).font(.system(size: 8, weight: .semibold).monospaced())
                .frame(width: 30, height: 30).background(Color.fill, in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(.secondary)
            Text(desc).font(.subheadline)
            Spacer()
            Text(dest).font(.caption).foregroundStyle(.secondary)
        }
    }
}
