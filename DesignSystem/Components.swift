import SwiftUI

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

/// Pílula "Obter" / "Instalar" das listas.
struct PillButton: View {
    let title: String
    var filled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 12).padding(.vertical, 5)
        }
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

    var body: some View {
        HStack(spacing: 8) {
            XGlyph()
                .fill(warning ? Color.ochre : Color.graphite)
                .frame(width: 14, height: 14)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.hairline)
                    Capsule().fill(warning ? Color.ochre : Color.graphite)
                        .frame(width: max(2, geo.size.width * progress))
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

// MARK: - Ícone de app (placeholder a partir da inicial)

struct AppIconThumb: View {
    let name: String
    var data: Data? = nil
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let data, let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable()
            } else {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(Color.graphite)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.fill)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * Radius.icon, style: .continuous))
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
                    .foregroundStyle(on ? Color.onGraphite : Color.lead)
                    .background(on ? Color.graphite : Color.surface, in: Capsule())
                    .overlay(Capsule().stroke(Color.hairline, lineWidth: on ? 0 : 1))
                }
            }
        }
    }
}
