import SwiftUI

struct LanguageView: View {
    @EnvironmentObject private var language: LocalizationManager
    @State private var followSystem: Bool

    init() { _followSystem = State(initialValue: LocalizationManager.shared.code == "system") }

    private var shipping: [Language] { LocalizationManager.all.filter(\.shipping) }
    private var upcoming: [Language] { LocalizationManager.all.filter { !$0.shipping } }

    var body: some View {
        List {
            Section {
                Toggle(L.tr("language.followSystem"), isOn: $followSystem)
                    .onChange(of: followSystem) { on in if on { language.code = "system" } }
            }

            Section(L.tr("language.available")) {
                ForEach(shipping) { lang in row(lang, enabled: true) }
            }

            Section {
                ForEach(upcoming) { lang in row(lang, enabled: false) }
            } header: {
                Text(L.tr("language.upcoming"))
            } footer: {
                Text(L.tr("language.helpTranslate"))
            }
        }
        .navigationTitle(L.tr("settings.language"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ lang: Language, enabled: Bool) -> some View {
        Button {
            guard enabled else { return }
            followSystem = false
            language.code = lang.code
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(lang.endonym).foregroundStyle(enabled ? Color.graphite : Color.ash)
                    Text(L.tr("language.name.\(lang.code)")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !enabled { Text(L.tr("language.soon")).font(.caption2).foregroundStyle(Color.ash) }
                else if language.code == lang.code && !followSystem {
                    Image(systemName: "checkmark").foregroundStyle(Color.graphite)
                }
            }
        }
        .disabled(!enabled)
    }
}
