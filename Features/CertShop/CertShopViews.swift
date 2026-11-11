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
    @State private var editingUDID = false
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
            editingUDID = shop.normalizedUDID == nil
        }
        .onChange(of: shop.udidSource) { source in
            if source != .manual, source != .none, shop.normalizedUDID != nil {
                withAnimation(.xsignSmooth) { editingUDID = false }
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
            Text(plan.randomValidity ? L.tr("shop.confirm.subtitleRandom") : L.tr("shop.confirm.subtitle"))
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
        case .embedded: return L.tr("shop.udid.detected")
        case .certificate: return L.tr("shop.udid.fromCertificate")
        case .profile: return L.tr("shop.udid.fromProfile")
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

            if editingUDID {
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
                        shop.startUDIDDiscovery()
                    } label: {
                        Label(L.tr("shop.udid.discover"), systemImage: "safari")
                    }
                    Spacer()
                    Button(L.tr("shop.udid.paste")) {
                        if let text = UIPasteboard.general.string { shop.userEditedUDID(text) }
                    }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.graphite)
                .padding(.top, 2)

                if shop.discoveringUDID {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text(L.tr("shop.udid.waiting"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
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
                    withAnimation(.xsignSmooth) { editingUDID = true }
                    udidFocused = true
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.graphite)
                .padding(.top, 2)
            }
        }
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

            PrimaryButton(title: buttonTitle, enabled: shop.normalizedUDID != nil && !shop.isCreating) {
                udidFocused = false
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

    private var buttonTitle: String {
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

struct CertShopBanner: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var shop: CertShopController

    var body: some View {
        if let state = shop.bannerState(certificates: app.certificates, current: app.currentCertificate) {
            Button { shop.openShop() } label: {
                HStack(spacing: 12) {
                    XGlyph()
                        .fill(Color.onGraphite)
                        .frame(width: 20, height: 20)
                        .frame(width: 44, height: 44)
                        .background(Color.graphite, in: RoundedRectangle(cornerRadius: 44 * Radius.icon, style: .continuous))
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
        case .offer: return L.tr("shop.banner.offer.subtitle", CertPlan.cheapest.price)
        case .awaitingPayment: return L.tr("shop.banner.awaiting.subtitle", number)
        case .working: return L.tr("shop.banner.working.subtitle", number)
        case .failed: return shop.importError ?? shop.order?.error ?? L.tr("shop.error.generic")
        }
    }

    private func pill(_ state: CertShopController.BannerState) -> String {
        switch state {
        case .offer: return L.tr("shop.banner.offer.pill")
        case .awaitingPayment: return L.tr("shop.banner.awaiting.pill")
        case .working, .failed: return L.tr("shop.banner.view")
        }
    }
}
