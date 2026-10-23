import SwiftUI
import UniformTypeIdentifiers

/// Porta de entrada única (equivale ao "Import Resource" do ESign). O tipo do
/// arquivo decide o destino, sem o usuário escolher a pasta.
struct ImportResourceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    sourceRow(L.tr("import.fromFiles"), "folder") { showPicker = true }
                    sourceRow(L.tr("import.fromLink"), "link") {}
                    sourceRow(L.tr("import.fromClipboard"), "doc.on.clipboard") {}
                }
                Section(L.tr("import.routing")) {
                    routeRow("IPA", L.tr("import.route.ipa"), "Apps")
                    routeRow("P12", L.tr("import.route.p12"), "Certificates")
                    routeRow("PROV", L.tr("import.route.prov"), "Certificates")
                    routeRow("ZIP", L.tr("import.route.zip"), "—")
                    routeRow("DEB", L.tr("import.route.deb"), "Tweaks")
                    routeRow("JSON", L.tr("import.route.json"), "Sources")
                }
            }
            .navigationTitle(L.tr("import.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L.tr("common.cancel")) { dismiss() } }
            }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: Self.types, allowsMultipleSelection: true) { _ in
                // ImportRouter.route(urls) decide o destino pelo tipo. dismiss() ao fim.
                dismiss()
            }
        }
    }

    static let types: [UTType] = [
        UTType(filenameExtension: "ipa") ?? .data,
        UTType(filenameExtension: "p12") ?? .data,
        UTType(filenameExtension: "mobileprovision") ?? .data,
        .zip, UTType(filenameExtension: "deb") ?? .data, .json, .text
    ]

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
