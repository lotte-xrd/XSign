import SwiftUI
import UIKit
import SafariServices

// MARK: - Folha da compra (planos → confirmar → pagamento)

struct CertShopSheet: View {
    @EnvironmentObject private var shop: CertShopController
    @State private var showConfirm = false

    var body: some View {
        NavigationStack {
            CertPlansView(onContinue: { showConfirm = true })
                .navigationDestination(isPresented: $showConfirm) { CertConfirmView() }
        }
        .tint(.graphite)
        .sheet(isPresented: Binding(
            get: { shop.checkoutURL != nil },
            set: { if !$0 { shop.checkoutClosed() } }
        )) {
            if let url = shop.checkoutURL {
                SafariView(url: url) { shop.checkoutClosed() }
                    .ignoresSafeArea()
            }
        }
    }
}

// MARK: - Escolher o plano

struct CertPlansView: View {
    @EnvironmentObject private var shop: CertShopController
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(L.tr("shop.plans.intro"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                ForEach(CertPlan.all) { plan in
                    PlanCard(plan: plan, selected: plan.id == shop.selectedPlanID) {
                        withAnimation(.xsignSmooth) { shop.selectedPlanID = plan.id }
                    }
                }

                Text(L.tr("shop.plans.footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .background(Color.stoneBG.ignoresSafeArea())
        .navigationTitle(L.tr("shop.plans.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L.tr("common.cancel")) { shop.shopPresented = false }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                PrimaryButton(title: L.tr("shop.plans.continue", shop.selectedPlan.price)) { onContinue() }
                Text(L.tr("shop.plans.feeNote"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(.bar)
        }
    }
}

private struct PlanCard: View {
    let plan: CertPlan
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.graphite : Color.ash)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(plan.title).font(.headline)
                        if plan.popular {
                            Text(L.tr("shop.plan.popular"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.moss)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Color.moss.opacity(0.14), in: Capsule())
                        }
                        Spacer(minLength: 6)
                        Text(plan.price).font(.headline.monospacedDigit())
                    }
                    Text(plan.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ChipFlow(spacing: 5) {
                        ForEach(plan.chips, id: \.self) { PlanChip(chip: $0) }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.group, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.group, style: .continuous)
                    .strokeBorder(selected ? Color.graphite : Color.hairline, lineWidth: selected ? 1.5 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PlanChip: View {
    let chip: CertPlan.Chip

    var body: some View {
        Text(chip.text)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(chip.warning ? Color.ochre : Color.lead)
            .background(chip.warning ? Color.ochre.opacity(0.13) : Color.fill, in: Capsule())
    }
}

/// Fileira de etiquetas que quebra a linha quando não cabe.
struct ChipFlow: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                widest = max(widest, x - spacing)
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        widest = max(widest, x - spacing, 0)
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Confirmar a compra

struct CertConfirmView: View {
    @EnvironmentObject private var shop: CertShopController
    @FocusState private var udidFocused: Bool
    @FocusState private var emailFocused: Bool
    /// A pessoa escolheu digitar ou colar o UDID.
    @State private var manualEntry = false
    @State private var copied = false

    private var plan: CertPlan { shop.selectedPlan }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 18)

                sectionHeader(L.tr("shop.confirm.device"))
                deviceCard
                if !shop.udidInput.isEmpty, shop.normalizedUDID == nil {
                    Text(L.tr("shop.udid.invalid"))
                        .font(.caption)
                        .foregroundStyle(Color.brick)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                }

                sectionHeader(L.tr("shop.email.title"))
                    .padding(.top, 20)
                emailCard
                Text(emailHint ?? L.tr("shop.email.note"))
                    .font(.caption)
                    .foregroundStyle(emailHint == nil ? Color.secondary : Color.brick)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)

                sectionHeader(L.tr("shop.confirm.plan"))
                    .padding(.top, 20)
                planCard

                Text(L.tr("shop.confirm.footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                if shop.openCheckoutForSelection != nil {
                    openOrderNote
                }
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.stoneBG.ignoresSafeArea())
        .navigationTitle(L.tr("shop.confirm.title"))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .onAppear {
            shop.prepareUDID()
            manualEntry = shop.normalizedUDID == nil && !shop.needsUDIDDiscovery
        }
        .onChange(of: shop.udidSource) { source in
            if source != .manual, source != .none, shop.normalizedUDID != nil {
                withAnimation(.xsignSmooth) { manualEntry = false }
            }
        }
        .onChange(of: shop.discoveringUDID) { discovering in
            if discovering {
                udidFocused = false
                withAnimation(.xsignSmooth) { manualEntry = false }
            }
        }
    }

    // MARK: Partes

    private var header: some View {
        VStack(spacing: 6) {
            XGlyph()
                .fill(Color.graphite)
                .frame(width: 26, height: 26)
                .frame(width: 56, height: 56)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.hairline, lineWidth: 0.5)
                )
                .padding(.bottom, 6)
            Text(plan.title).font(.title3.weight(.semibold))
            Text(L.tr("shop.confirm.subtitle"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
    }

    private var sourceBadge: String? {
        guard shop.normalizedUDID != nil else { return nil }
        switch shop.udidSource {
        case .embedded, .saved, .profile: return L.tr("shop.udid.detected")
        case .certificate: return L.tr("shop.udid.fromCertificate")
        case .manual, .none: return nil
        }
    }

    private var deviceCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "iphone")
                    .font(.title3)
                    .foregroundStyle(Color.graphite)
                    .frame(width: 24)
                Text(DeviceUDID.deviceLabel).font(.callout)
                Spacer()
                if let badge = sourceBadge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.moss)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.moss.opacity(0.14), in: Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().padding(.leading, 14)

            udidRow
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.group, style: .continuous))
    }

    @ViewBuilder
    private var udidRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("UDID")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if manualEntry {
                manualUDIDField
            } else if shop.normalizedUDID != nil {
                udidValue
            } else if shop.discoveringUDID {
                udidWaiting
            } else {
                udidAutomatic
            }
        }
    }

    /// Sem UDID ainda: explica que o Comprar confirma o UDID sozinho.
    private var udidAutomatic: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(Color.moss)
                    .padding(.top, 1)
                Text(L.tr("shop.udid.autoNote"))
                    .font(.footnote)
                    .foregroundStyle(Color.lead)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(L.tr("shop.udid.typeInstead")) {
                withAnimation(.xsignSmooth) { manualEntry = true }
                udidFocused = true
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.graphite)
        }
    }

    /// Perfil aberto no Safari: mostra o que falta e espera o UDID voltar.
    private var udidWaiting: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L.tr("shop.udid.waiting"))
                    .font(.footnote.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 6) {
                stepLine(1, L.tr("shop.udid.step1"))
                stepLine(2, L.tr("shop.udid.step2"))
                stepLine(3, shop.discovery?.buyPlanID != nil ? L.tr("shop.udid.step3Buy") : L.tr("shop.udid.step3"))
            }
            HStack {
                Button(L.tr("shop.udid.reopen")) { shop.openUDIDProfile() }
                    .foregroundStyle(Color.graphite)
                Spacer()
                Button(L.tr("common.cancel")) {
                    withAnimation(.xsignSmooth) { shop.cancelUDIDDiscovery() }
                }
                .foregroundStyle(Color.lead)
            }
            .font(.footnote.weight(.semibold))
            .padding(.top, 2)
        }
    }

    private func stepLine(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(Color.lead)
                .frame(width: 18, height: 18)
                .background(Color.fill, in: Circle())
            Text(text)
                .font(.footnote)
                .foregroundStyle(Color.lead)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var manualUDIDField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(
                L.tr("shop.udid.placeholder"),
                text: Binding(get: { shop.udidInput }, set: { shop.userEditedUDID($0) })
            )
            .font(.system(.footnote, design: .monospaced))
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .focused($udidFocused)
            .submitLabel(.done)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Color.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack(spacing: 8) {
                Button {
                    udidFocused = false
                    shop.userEditedUDID("")
                    shop.startUDIDDiscovery()
                } label: {
                    Label(L.tr("shop.udid.discover"), systemImage: "wand.and.stars")
                }
                Spacer()
                Button(L.tr("shop.udid.paste")) {
                    if let text = UIPasteboard.general.string { shop.userEditedUDID(text) }
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.graphite)
            .padding(.top, 2)
        }
    }

    private var udidValue: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(shop.normalizedUDID ?? shop.udidInput)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .textSelection(.enabled)
                Spacer()
                Button {
                    UIPasteboard.general.string = shop.normalizedUDID
                    withAnimation(.xsignSmooth) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        withAnimation(.xsignSmooth) { copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(Color.lead)
                }
                .buttonStyle(.plain)
            }
            if shop.udidSource == .certificate, let name = shop.udidSourceName {
                Text(L.tr("shop.udid.fromCertificateNote", name))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(L.tr("shop.udid.change")) {
                withAnimation(.xsignSmooth) { manualEntry = true }
                udidFocused = true
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.graphite)
            .padding(.top, 2)
        }
    }

    private var emailCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "envelope")
                .font(.body)
                .foregroundStyle(Color.graphite)
                .frame(width: 24)
            TextField(L.tr("shop.email.placeholder"), text: $shop.emailInput)
                .font(.callout)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($emailFocused)
            if shop.normalizedEmail != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.moss)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.group, style: .continuous))
    }

    /// Aviso de e-mail inválido (só depois de sair do campo).
    private var emailHint: String? {
        guard !emailFocused, shop.normalizedEmail == nil,
              !shop.emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return L.tr("shop.email.invalid")
    }

    private var planCard: some View {
        VStack(spacing: 0) {
            infoRow(L.tr("shop.confirm.plan"), plan.title)
            Divider().padding(.leading, 14)
            infoRow(L.tr("shop.confirm.validity"), plan.validityText)
            Divider().padding(.leading, 14)
            infoRow(L.tr("shop.confirm.warranty"), plan.warrantyText)
            Divider().padding(.leading, 14)
            infoRow(L.tr("shop.confirm.validFor"), L.tr("shop.confirm.thisUDID"))
        }
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.group, style: .continuous))
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var openOrderNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock")
                .foregroundStyle(Color.ochre)
            VStack(alignment: .leading, spacing: 4) {
                Text(L.tr("shop.confirm.openOrder", shop.order?.number ?? "—"))
                    .font(.footnote.weight(.semibold))
                Text(L.tr("shop.confirm.openOrderNote"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L.tr("shop.confirm.discard")) { shop.discardOpenOrder() }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.brick)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.ochre.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.group, style: .continuous))
        .padding(.top, 14)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let error = shop.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Color.brick)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(L.tr("shop.confirm.oneTime")).foregroundStyle(.secondary)
                Spacer()
                Text(plan.price).font(.headline.monospacedDigit())
            }
            .font(.subheadline)

            PrimaryButton(title: buttonTitle, enabled: canBuy) {
                udidFocused = false
                emailFocused = false
                Task { await shop.buy() }
            }

            Label(L.tr("shop.confirm.secure"), systemImage: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Spacing.screen)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }

    /// Sem UDID nenhum, Comprar também vale: confirma o UDID pelo perfil e segue.
    private var canBuy: Bool {
        !shop.isCreating && !shop.discoveringUDID && (shop.normalizedUDID != nil || shop.needsUDIDDiscovery)
    }

    private var buttonTitle: String {
        if shop.discoveringUDID { return L.tr("shop.udid.waiting") }
        if shop.isCreating { return L.tr("shop.confirm.opening") }
        return shop.openCheckoutForSelection != nil ? L.tr("shop.confirm.continuePayment") : L.tr("shop.confirm.buy")
    }
}

// MARK: - Janela do Safari para o pagamento

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    var onFinish: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.barCollapsingEnabled = true
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .done
        controller.preferredControlTintColor = UIColor(named: "Graphite")
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { onFinish() }
    }
}

// MARK: - Cartão da tela Apps

/// Ícone de certificado (.p12 / .mobileprovision): documento com selo.
struct CertificateIcon: View {
    var size: CGFloat = 52

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * Radius.icon, style: .continuous)
                .fill(Color.white)
            Image(systemName: "doc.text.fill")
                .font(.system(size: size * 0.46, weight: .regular))
                .foregroundStyle(CertShopPalette.deep)
                .offset(x: -size * 0.07, y: -size * 0.04)
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: size * 0.32, weight: .semibold))
                .foregroundStyle(CertShopPalette.gold)
                .background(Circle().fill(Color.white).padding(-size * 0.03))
                .offset(x: size * 0.17, y: size * 0.18)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Cores fixas do cartão de compra: iguais no tema claro e no escuro, para
/// ele chamar a atenção nos dois.
enum CertShopPalette {
    static let light = Color(red: 0.36, green: 0.58, blue: 0.43)
    static let mid = Color(red: 0.24, green: 0.43, blue: 0.31)
    static let deep = Color(red: 0.15, green: 0.30, blue: 0.21)
    static let gold = Color(red: 0.86, green: 0.66, blue: 0.20)
}

struct CertShopBanner: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var shop: CertShopController

    var body: some View {
        if let state = shop.bannerState(certificates: app.certificates, current: app.currentCertificate) {
            if state == .offer {
                CertShopOfferCard { shop.openShop() }
            } else {
                statusCard(state)
            }
        }
    }

    /// Pedido em andamento: cartão compacto.
    private func statusCard(_ state: CertShopController.BannerState) -> some View {
        Button { shop.openShop() } label: {
            HStack(spacing: 12) {
                CertificateIcon(size: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: 44 * Radius.icon, style: .continuous)
                            .strokeBorder(Color.hairline, lineWidth: 0.5)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(state))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.graphite)
                    Text(subtitle(state))
                        .font(.caption)
                        .foregroundStyle(state == .failed ? Color.brick : Color.lead)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                PillButton(title: pill(state), filled: true) { shop.openShop() }
            }
            .padding(12)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.group, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func title(_ state: CertShopController.BannerState) -> String {
        switch state {
        case .offer: return L.tr("shop.banner.offer.title")
        case .awaitingPayment: return L.tr("shop.banner.awaiting.title")
        case .working: return L.tr("shop.banner.working.title")
        case .failed: return L.tr("shop.banner.failed.title")
        }
    }

    private func subtitle(_ state: CertShopController.BannerState) -> String {
        let number = shop.order?.number ?? "—"
        switch state {
        case .offer: return L.tr("shop.banner.offer.tagline")
        case .awaitingPayment: return L.tr("shop.banner.awaiting.subtitle", number)
        case .working: return L.tr("shop.banner.working.subtitle", number)
        case .failed: return shop.importError ?? shop.order?.error ?? L.tr("shop.error.generic")
        }
    }

    private func pill(_ state: CertShopController.BannerState) -> String {
        switch state {
        case .awaitingPayment: return L.tr("shop.banner.awaiting.pill")
        case .offer, .working, .failed: return L.tr("shop.banner.view")
        }
    }
}

/// Oferta de certificado: cartão verde, ícone de certificado, vantagens e um
/// botão grande. Um brilho passa por ele de tempos em tempos.
struct CertShopOfferCard: View {
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shine = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    CertificateIcon(size: 52)
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L.tr("shop.banner.offer.title"))
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text(L.tr("shop.banner.offer.tagline"))
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                // Quebra a linha em telas estreitas (iPhone SE).
                ChipFlow(spacing: 6) {
                    feature("bolt.fill", L.tr("shop.banner.offer.feature1"))
                    feature("creditcard.fill", L.tr("shop.banner.offer.feature2"))
                    feature("arrow.down.circle.fill", L.tr("shop.banner.offer.feature3"))
                }

                HStack(spacing: 6) {
                    Text(L.tr("shop.banner.offer.cta", CertPlan.cheapest.price))
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.footnote.weight(.bold))
                }
                .foregroundStyle(CertShopPalette.deep)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(14)
            .background(
                LinearGradient(
                    colors: [CertShopPalette.light, CertShopPalette.mid, CertShopPalette.deep],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .overlay(shineOverlay)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: CertShopPalette.deep.opacity(0.28), radius: 10, y: 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .task {
            // Um brilho a cada 4 s enquanto o cartão está na tela.
            guard !reduceMotion else { return }
            try? await Task.sleep(nanoseconds: 800_000_000)
            while !Task.isCancelled {
                shine = false
                try? await Task.sleep(nanoseconds: 50_000_000)
                withAnimation(.easeInOut(duration: 1.3)) { shine = true }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    private func feature(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(CertShopPalette.gold)
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.16), in: Capsule())
    }

    /// Faixa de brilho que atravessa o cartão.
    private var shineOverlay: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [.clear, .white.opacity(0.22), .clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: geo.size.width * 0.32, height: geo.size.height * 1.6)
            .rotationEffect(.degrees(20))
            .offset(x: shine ? geo.size.width * 1.15 : -geo.size.width * 0.5, y: -geo.size.height * 0.3)
        }
        .allowsHitTesting(false)
    }
}
