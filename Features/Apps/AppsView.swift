import SwiftUI

struct AppsView: View {
    @EnvironmentObject private var app: AppState
    @State private var segment: AppState2 = .unsigned
    @State private var query = ""
    @State private var actionTarget: AppItem?
    @State private var signTarget: AppItem?

    private var list: [AppItem] {
        app.apps.filter { $0.state == segment }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $segment) {
                    Text(L.tr("apps.unsigned", app.apps.filter { $0.state == .unsigned }.count)).tag(AppState2.unsigned)
                    Text(L.tr("apps.signed", app.apps.filter { $0.state == .signed }.count)).tag(AppState2.signed)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Spacing.screen).padding(.vertical, 8)

                if list.isEmpty {
                    EmptyStateView(title: L.tr("apps.empty.title"), message: L.tr("apps.empty.message"))
                    Spacer()
                } else {
                    List {
                        ForEach(list) { item in
                            Button { actionTarget = item } label: { AppRow(item: item) }
                                .buttonStyle(.plain)
                                .swipeActions {
                                    Button(role: .destructive) { app.delete(item) } label: {
                                        Label(L.tr("common.delete"), systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
            .navigationTitle(L.tr("tab.apps"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: L.tr("common.search"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { app.selectedTab = .files } label: { Image(systemName: "plus") }
                }
            }
            .confirmationDialog(actionTarget?.name ?? "", isPresented: .init(
                get: { actionTarget != nil }, set: { if !$0 { actionTarget = nil } }
            ), titleVisibility: .visible) {
                if let item = actionTarget { actionButtons(for: item) }
            }
            .sheet(item: $signTarget) { SignView(app: $0) }
        }
    }

    @ViewBuilder
    private func actionButtons(for item: AppItem) -> some View {
        if item.state == .unsigned {
            Button(L.tr("apps.action.sign")) { signTarget = item }
            Button(L.tr("apps.action.signDefault")) { signTarget = item }
            Button(L.tr("apps.action.share")) {}
            Button(L.tr("common.delete"), role: .destructive) { app.delete(item) }
        } else {
            Button(L.tr("apps.action.install")) {}
            Button(L.tr("apps.action.share")) {}
            Button(L.tr("apps.action.resign")) { signTarget = item }
            Button(L.tr("common.delete"), role: .destructive) { app.delete(item) }
        }
    }
}

struct AppRow: View {
    let item: AppItem

    var body: some View {
        HStack(spacing: 12) {
            AppIconThumb(name: item.name, data: iconData, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.subheadline.weight(.semibold))
                Text("\(item.version) · \(item.bundleID)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if item.state == .signed {
                PillButton(title: L.tr("apps.action.install"), filled: true) {}
            } else {
                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var iconData: Data? {
        guard let p = item.iconPath else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: p))
    }
}
