import SwiftUI

struct FilesView: View {
    @EnvironmentObject private var app: AppState
    @State private var showImport = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StorageBar()
                        .listRowInsets(EdgeInsets(top: 12, leading: Spacing.screen, bottom: 12, trailing: Spacing.screen))
                }
                Section(L.tr("files.folders")) {
                    folder(L.tr("apps.unsigned.plain"), "folder", count: app.apps.filter { $0.state == .unsigned }.count)
                    folder(L.tr("apps.signed.plain"), "folder", count: app.apps.filter { $0.state == .signed }.count)
                    folder(L.tr("files.certificates"), "folder", count: app.certificates.count)
                    folder(L.tr("files.tweaks"), "folder", count: 0)
                }
            }
            .navigationTitle(L.tr("tab.files"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showImport = true } label: { Label(L.tr("files.import"), systemImage: "tray.and.arrow.down") }
                        Button {} label: { Label(L.tr("files.newFolder"), systemImage: "folder.badge.plus") }
                        Button {} label: { Label(L.tr("files.sort"), systemImage: "arrow.up.arrow.down") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showImport) { ImportResourceView() }
        }
    }

    private func folder(_ name: String, _ icon: String, count: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Color.lead).frame(width: 28)
            Text(name)
            Spacer()
            Text("\(count)").foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.ash)
        }
    }
}

struct StorageBar: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("1,8 GB").font(.title3.weight(.bold))
                Text(L.tr("files.used")).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 2) {
                Capsule().fill(Color.graphite).frame(maxWidth: .infinity)
                Capsule().fill(Color.lead).frame(width: 70)
                Capsule().fill(Color.ash).frame(width: 36)
            }
            .frame(height: 5)
            HStack(spacing: 12) {
                legend(Color.graphite, "Apps")
                legend(Color.lead, L.tr("tab.downloads"))
                legend(Color.ash, L.tr("files.other"))
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 6, height: 6)
            Text(label)
        }
    }
}
