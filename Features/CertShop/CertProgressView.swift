import SwiftUI
import UIKit

/// Tela cheia depois do pagamento: gera o certificado na Aixiang (pelo
/// servidor), baixa e importa, e mostra o certificado já em uso.
struct CertProgressView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var shop: CertShopController
    @State private var breathe = false
    @State private var showShare = false

    private enum Phase { case working, done, failed }

    private var phase: Phase {
        if shop.isImported { return .done }
        if shop.importError != nil || shop.order?.isFailed == true || shop.order?.isExpired == true { return .failed }
        return .working
    }

    private var status: String { shop.order?.status ?? "" }

    var body: some View {
        VStack(spacing: 14) {
            header
                .padding(.top, 28)

            VStack(spacing: 0) {
                ShopStepRow(title: L.tr("shop.step.payment"), state: paymentState, detail: shop.order?.paymentSummary)
                Divider()
                ShopStepRow(title: L.tr("shop.step.generate"), state: generateState, detail: nil)
                Divider()
                ShopStepRow(title: L.tr("shop.step.import"), state: importState, detail: nil)
            }
            .padding(.horizontal, 12)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.group, style: .continuous))
            .padding(.horizontal, Spacing.screen)

            if phase == .done {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.tr("shop.progress.inUse").uppercased())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                    certificateCard
                }
                .padding(.horizontal, Spacing.screen)
                .transition(.motionBlur)
                Spacer(minLength: 0)
            } else {
                SignLogPanel(lines: shop.log)
                    .frame(minHeight: 140, maxHeight: .infinity)
                    .padding(.horizontal, Spacing.screen)
            }

            if phase == .working {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "bell.fill")
                        .foregroundStyle(Color.graphite)
                    Text(L.tr("shop.progress.notice"))
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.group, style: .continuous))
                .padding(.horizontal, Spacing.screen)
            }

            footer
                .padding(.horizontal, Spacing.screen)
                .padding(.bottom, 12)
        }
        .background(Color.stoneBG.ignoresSafeArea())
        .animation(.xsignSmooth, value: phase)
        .sheet(isPresented: $showShare) {
            ShareSheet(items: [SignLogLine.plainText(shop.log)])
        }
        .onAppear {
            shop.startPolling()
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { breathe = true }
        }
    }

    // MARK: Cabeçalho

    private var header: some View {
        VStack(spacing: 10) {
            XGlyph()
                .fill(glyphColor)
                .frame(width: 40, height: 40)
                .scaleEffect(phase == .done ? 1.08 : (breathe && phase == .working ? 0.94 : 1))
                .animation(.xsignSmooth, value: phase)

            SignatureLine(progress: fraction, warning: phase == .failed, showsGlyph: false)
                .frame(width: 120)
                .padding(.top, 4)

            Text(titleText)
                .font(.headline)
                .contentTransition(.opacity)
                .padding(.top, 6)

            Text(subtitleText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .transition(.motionBlur)
        }
    }

    private var glyphColor: Color {
        switch phase {
        case .done: return .moss
        case .failed: return .brick
        case .working: return .graphite
        }
    }

    private var fraction: Double {
        if shop.isImported { return 1 }
        switch status {
        case "paid": return 0.3
        case "issuing": return 0.5
        case "pending": return 0.62
        case "ready": return 0.85
        default: return shop.order?.isPaid == true ? 0.3 : 0.1
        }
    }

    private var titleText: String {
        switch phase {
        case .done: return L.tr("shop.progress.done.title")
        case .failed:
            return shop.order?.isExpired == true ? L.tr("shop.progress.expired.title") : L.tr("shop.progress.failed.title")
        case .working: return L.tr("shop.progress.working.title")
        }
    }

    private var subtitleText: String {
        switch phase {
        case .done: return L.tr("shop.progress.done.subtitle")
        case .failed:
            if shop.order?.isExpired == true { return L.tr("shop.progress.expired.subtitle") }
            return L.tr("shop.progress.failed.paid")
        case .working: return L.tr("shop.progress.working.subtitle", shop.order?.number ?? "—")
        }
    }

    // MARK: Etapas (as mesmas que o servidor informa)

    private var paymentState: StepState {
        if shop.order?.isPaid == true { return .done(seconds: nil) }
        if shop.order?.isExpired == true { return .failed(L.tr("shop.log.expired")) }
        return .running(detail: nil)
    }

    private var generateState: StepState {
        if shop.isImported || status == "ready" { return .done(seconds: generationSeconds) }
        switch status {
        case "failed": return .failed(shop.order?.error ?? "")
        case "pending": return .running(detail: L.tr("shop.step.queue"))
        case "paid", "issuing": return .running(detail: nil)
        default: return .waiting
        }
    }

    private var importState: StepState {
        if shop.isImported { return .done(seconds: shop.pending?.importSeconds) }
        if let error = shop.importError { return .failed(error) }
        if status == "ready" { return .running(detail: nil) }
        return .waiting
    }

    private var generationSeconds: Double? {
        guard let paid = shop.pending?.paidSeenAt, let ready = shop.pending?.readySeenAt else { return nil }
        return max(0, ready.timeIntervalSince(paid))
    }

    // MARK: Certificado em uso

    @ViewBuilder
    private var certificateCard: some View {
        if let cert = shop.importedCertificate {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(cert.nickname)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    StatusBadge(status: cert.status)
                }
                Text("\(cert.type) · \(cert.teamID)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                SignatureLine(
                    progress: cert.validityFraction,
                    warning: cert.status == .expiring,
                    trailing: cert.daysLeft.map { L.tr("shop.cert.days", $0) }
                )
                if let expires = cert.expiresAt {
                    Text(L.tr("shop.cert.expires", Self.dateText(expires)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let warranty = warrantyText {
                    Label(warranty, systemImage: "checkmark.shield")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.moss)
                }
            }
            .padding(14)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.group, style: .continuous))
        }
    }

    private var warrantyText: String? {
        guard let days = shop.pendingPlan?.warrantyDays,
              let start = shop.order?.paidDate ?? shop.pending?.paidSeenAt,
              let end = Calendar.current.date(byAdding: .day, value: days, to: start) else { return nil }
        return L.tr("shop.cert.warranty", days, Self.dateText(end))
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    // MARK: Rodapé

    @ViewBuilder
    private var footer: some View {
        switch phase {
        case .done:
            VStack(spacing: 8) {
                PrimaryButton(title: L.tr("shop.progress.signApp")) {
                    shop.closeProgress()
                    app.selectedTab = .apps
                }
                SecondaryButton(title: L.tr("shop.progress.viewCert")) {
                    shop.closeProgress()
                    app.selectedTab = .settings
                }
                Button(L.tr("common.close")) { shop.closeProgress() }
                    .padding(.top, 2)
            }
            .transition(.motionBlur)
        case .failed:
            VStack(spacing: 8) {
                if shop.order?.isPaid == true {
                    PrimaryButton(title: L.tr("shop.progress.retry"), enabled: !shop.isRetrying) {
                        Task { await shop.retry() }
                    }
                }
                SecondaryButton(title: L.tr("shop.progress.shareLog"), systemImage: "square.and.arrow.up") {
                    showShare = true
                }
                Button(L.tr("common.close")) { shop.closeProgress() }
                    .padding(.top, 2)
            }
            .transition(.motionBlur)
        case .working:
            Button(L.tr("shop.progress.background")) { shop.hideProgress() }
                .padding(.vertical, 6)
        }
    }
}

/// Linha de etapa com título livre (a `StepRow` da assinatura usa `SignStepKind`).
private struct ShopStepRow: View {
    let title: String
    let state: StepState
    let detail: String?

    var body: some View {
        HStack(spacing: 9) {
            icon
                .frame(width: 16, height: 16)
                .transition(.scale.combined(with: .opacity))
                .id(iconKey)
            Text(title).font(.callout)
            Spacer()
            Text(detailText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 8)
        .opacity(iconKey == "waiting" ? 0.5 : 1)
        .animation(.xsignSmooth, value: iconKey)
    }

    private var iconKey: String {
        switch state {
        case .waiting: return "waiting"
        case .running: return "running"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark").font(.caption2.weight(.bold))
                .foregroundStyle(Color.onGraphite).frame(width: 16, height: 16)
                .background(Color.graphite, in: Circle())
        case .running:
            ProgressView().controlSize(.mini)
        case .failed:
            Image(systemName: "xmark").font(.caption2.weight(.bold))
                .foregroundStyle(Color.onGraphite).frame(width: 16, height: 16)
                .background(Color.brick, in: Circle())
        case .waiting:
            Circle().stroke(Color.hairline, lineWidth: 1.5).frame(width: 15, height: 15)
        }
    }

    private var detailText: String {
        if let detail { return detail }
        switch state {
        case .running(let text): return text ?? ""
        case .done(let seconds):
            guard let seconds else { return "" }
            if seconds < 60 { return String(format: "%.1f s", seconds) }
            let total = Int(seconds.rounded())
            return "\(total / 60) min \(total % 60) s"
        default: return ""
        }
    }
}
