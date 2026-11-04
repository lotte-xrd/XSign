import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Botões

struct PrimaryButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .foregroundStyle(Color.onGraphite)
        .background(Color.graphite, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
    }
}

struct SecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .foregroundStyle(Color.graphite)
        .background(Color.fill, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
    }
}

/// Pílula "Obter" / "Assinar" / "Instalar" das listas.
struct PillButton: View {
    let title: String
    var filled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(filled ? Color.onGraphite : Color.graphite)
        .background(filled ? Color.graphite : Color.fill, in: Capsule())
    }
}

// MARK: - Status

struct StatusBadge: View {
    let status: CertStatus

    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(status.color)
            .background(status.color.opacity(0.15), in: Capsule())
    }
}

// MARK: - A linha da assinatura (único grafismo da marca dentro do app)

/// Barra de progresso ou de validade: o X seguido de uma linha que se completa.
struct SignatureLine: View {
    var progress: Double              // 0...1
    var warning: Bool = false
    var trailing: String? = nil       // ex.: "68%", "312 d"
    /// Desligue quando já existe um X grande por perto (ex.: tela de assinatura),
    /// para não aparecer um X pequeno em cima do grande.
    var showsGlyph: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            if showsGlyph {
                XGlyph()
                    .fill(warning ? Color.ochre : Color.graphite)
                    .frame(width: 14, height: 14)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.hairline)
                    Capsule().fill(warning ? Color.ochre : Color.graphite)
                        .frame(width: max(2, geo.size.width * min(1, max(0, progress))))
                        .animation(.spring(response: 0.55, dampingFraction: 0.9), value: progress)
                }
            }
            .frame(height: 3)
            if let trailing {
                Text(trailing)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// O X da marca: traço de descida grosso, de subida fino. Mesma geometria do ícone.
struct XGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 34 * w, y: rect.minY + y / 34 * h)
        }
        var path = Path()
        // descida (grosso)
        path.move(to: p(0, 0)); path.addLine(to: p(8.5, 0))
        path.addLine(to: p(34, 34)); path.addLine(to: p(25.5, 34)); path.closeSubpath()
        // subida (fino)
        path.move(to: p(0, 34)); path.addLine(to: p(4.25, 34))
        path.addLine(to: p(34, 0)); path.addLine(to: p(29.75, 0)); path.closeSubpath()
        return path
    }
}

// MARK: - Estado vazio

struct EmptyStateView: View {
    let title: String
    let message: String
    var systemImage: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage).font(.largeTitle).foregroundStyle(Color.ash)
            } else {
                XGlyph().fill(Color.ash).frame(width: 40, height: 40)
            }
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Cache de Ícones Remotos e Locais

final class IconCache {
    static let shared = IconCache()
    private let memory = NSCache<NSString, UIImage>()

    func image(for key: String) -> UIImage? {
        memory.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, for key: String) {
        memory.setObject(image, forKey: key as NSString)
    }
}

/// Ícone de app real: carrega de Data, de arquivo local extraído do .ipa ou de URL remota com cache.
struct AppIconThumb: View {
    let name: String
    var data: Data? = nil
    var iconPath: String? = nil
    var url: URL? = nil
    var size: CGFloat = 44

    @State private var remoteImage: UIImage?

    var body: some View {
        ZStack {
            if let ui = localUIImage ?? remoteImage {
                Image(uiImage: ui)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(Color.graphite)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.fill)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * Radius.icon, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * Radius.icon, style: .continuous)
                .stroke(Color.hairline.opacity(0.6), lineWidth: 0.5)
        )
        .task(id: url) {
            await loadRemoteIfNeeded()
        }
    }

    private var localUIImage: UIImage? {
        if let data, let img = UIImage(data: data) {
            return img
        }
        if let iconPath, !iconPath.isEmpty {
            let resolved = Paths.resolve(iconPath)
            if let cached = IconCache.shared.image(for: resolved.path) {
                return cached
            }
            if let d = try? Data(contentsOf: resolved), let img = UIImage(data: d) {
                IconCache.shared.store(img, for: resolved.path)
                return img
            }
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "xsign",
           let builtInIcon = UIImage(named: "XSignStoreIcon") {
            return builtInIcon
        }
        return nil
    }

    private func loadRemoteIfNeeded() async {
        guard localUIImage == nil, let url else { return }
        let key = url.absoluteString
        if let cached = IconCache.shared.image(for: key) {
            remoteImage = cached
            return
        }
        do {
            var req = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
            req.setValue("XSign/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: req)
            if let img = UIImage(data: data) {
                IconCache.shared.store(img, for: key)
                await MainActor.run { remoteImage = img }
            }
        } catch {
            // Mantém o fallback da inicial se a imagem falhar
        }
    }
}

// MARK: - Chips de filtro por fonte

struct FilterChips: View {
    let items: [String]
    @Binding var selection: Int

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items.indices, id: \.self) { i in
                    let on = i == selection
                    Button { selection = i } label: {
                        Text(items[i])
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(on ? Color.onGraphite : Color.lead)
                    .background(on ? Color.graphite : Color.surface, in: Capsule())
                    .overlay(Capsule().stroke(Color.hairline, lineWidth: on ? 0 : 1))
                }
            }
        }
    }
}

// MARK: - Share Sheet nativo do iOS

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Seletor de Arquivos Nativo (UIDocumentPickerViewController com asCopy: true)

struct DocumentPicker: UIViewControllerRepresentable {
    var allowsMultipleSelection: Bool = false
    let onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // [.item] habilita TODOS os arquivos no app Arquivos do iOS (.p12, .mobileprovision, .ipa, .zip, .dylib, .deb)
        // e asCopy: true faz o iOS copiar o arquivo direto para o sandbox temporário do app.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item, .data, .content], asCopy: true)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}

// MARK: - 1. Splash Animada de Abertura (Boot Screen)

struct SplashView: View {
    var progress: Double
    var statusText: String
    @State private var pulse = false

    var body: some View {
        ZStack {
            Color.stoneBG.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.fill.opacity(0.65))
                            .frame(width: 68, height: 68)
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(Color.hairline, lineWidth: 1)
                            )

                        XGlyph()
                            .fill(Color.graphite)
                            .frame(width: 32, height: 32)
                            .scaleEffect(pulse ? 0.93 : 1.0)
                            .opacity(pulse ? 0.78 : 1.0)
                    }

                    Text("XSign")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.graphite)

                    SignatureLine(progress: progress)
                        .frame(width: 132)
                        .animation(.easeInOut(duration: 0.35), value: progress)

                    Text(statusText)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }

                Spacer()

                Text("Exploiting iOS")
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.45))
                    .padding(.bottom, 24)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - 2. HUD Overlay de Carregamento (Importar .ipa, Certificados, Fontes)

struct LoadingHUDView: View {
    let title: String
    @State private var pulse = false
    @State private var slide = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            VStack(spacing: 11) {
                XGlyph()
                    .fill(Color.graphite)
                    .frame(width: 24, height: 24)
                    .scaleEffect(pulse ? 0.92 : 1.0)
                    .opacity(pulse ? 0.76 : 1.0)

                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.graphite)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.hairline)
                        Capsule()
                            .fill(Color.graphite)
                            .frame(width: geo.size.width * 0.45)
                            .offset(x: slide ? geo.size.width * 0.65 : -geo.size.width * 0.1)
                    }
                    .clipShape(Capsule())
                }
                .frame(width: 96, height: 3)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(minWidth: 164)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.hairline.opacity(0.8), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulse = true
            }
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                slide = true
            }
        }
    }
}
