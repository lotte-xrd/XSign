import SwiftUI
import UIKit

// MARK: - Transição com motion blur suave

/// Entra desfocado, levemente esticado na vertical e de baixo para cima, e
/// assenta nítido. Dá a sensação de "motion blur" sem pesar na animação.
struct MotionBlurModifier: ViewModifier {
    /// 0 = fora da tela (desfocado), 1 = assentado (nítido).
    var amount: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: (1 - amount) * 7)
            .opacity(amount)
            .scaleEffect(x: 1, y: 1 + (1 - amount) * 0.45, anchor: .bottom)
            .offset(y: (1 - amount) * 12)
    }
}

extension AnyTransition {
    static var motionBlur: AnyTransition {
        .modifier(
            active: MotionBlurModifier(amount: 0),
            identity: MotionBlurModifier(amount: 1)
        )
    }
}

extension Animation {
    /// Curva única usada pelo log e pelos passos da assinatura.
    static var xsignSmooth: Animation { .spring(response: 0.55, dampingFraction: 0.88) }
}

// MARK: - Painel de log da assinatura

struct SignLogPanel: View {
    let lines: [SignLogLine]
    var title: String = L.tr("signlog.title")
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(1.1)
                    .foregroundStyle(.secondary)
                Text("\(lines.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText())
                Spacer()
                Button {
                    UIPasteboard.general.string = SignLogLine.plainText(lines)
                    withAnimation(.xsignSmooth) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        withAnimation(.xsignSmooth) { copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(copied ? Color.moss : Color.graphite)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .disabled(lines.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Rectangle().fill(Color.hairline).frame(height: 0.5)

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(lines) { line in
                            SignLogRow(line: line)
                                .id(line.id)
                                .transition(.motionBlur)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: lines.count) { _ in
                    guard let last = lines.last else { return }
                    withAnimation(.xsignSmooth) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onAppear {
                    if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 14)
                    Color.black
                }
            )
        }
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.group, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.group, style: .continuous)
                .stroke(Color.hairline.opacity(0.7), lineWidth: 0.5)
        )
    }
}

struct SignLogRow: View {
    let line: SignLogLine

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Text(Self.timeFormatter.string(from: line.date))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.top, 1)
            Circle()
                .fill(dotColor)
                .frame(width: 5, height: 5)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                if let tag = line.tag, !tag.isEmpty {
                    Text(tag)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.graphite)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.fill, in: Capsule())
                }
                Text(line.text)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(textColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }

    private var dotColor: Color {
        switch line.level {
        case .info:    return .lead
        case .detail:  return .ash
        case .success: return .moss
        case .warning: return .ochre
        case .error:   return .brick
        }
    }

    private var textColor: Color {
        switch line.level {
        case .error:   return .brick
        case .warning: return .ochre
        case .success: return .graphite
        case .detail:  return .lead
        case .info:    return .graphite
        }
    }
}

extension SignLogLine {
    /// Log em texto puro para copiar/compartilhar.
    static func plainText(_ lines: [SignLogLine]) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return lines.map { line in
            let tag = line.tag.map { "[\($0)] " } ?? ""
            let level: String
            switch line.level {
            case .info: level = "INFO"
            case .detail: level = "    "
            case .success: level = " OK "
            case .warning: level = "WARN"
            case .error: level = "ERRO"
            }
            return "\(f.string(from: line.date)) \(level) \(tag)\(line.text)"
        }
        .joined(separator: "\n")
    }
}
