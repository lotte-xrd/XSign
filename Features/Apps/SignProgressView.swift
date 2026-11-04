import SwiftUI
import UIKit

struct SignProgressView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let app: AppItem
    let certificate: Certificate
    let options: SignOptions
    var onCompleteDismissParent: (() -> Void)? = nil

    @State private var progress = SignProgress(steps: [], fraction: 0)
    @State private var showShare = false
    @State private var shareItems: [Any] = []
    @State private var breathe = false

    var body: some View {
        VStack(spacing: 14) {
            header
                .padding(.top, 28)

            VStack(spacing: 0) {
                ForEach(progress.steps) { step in
                    StepRow(step: step)
                    if step.id != progress.steps.last?.id { Divider() }
                }
            }
            .padding(.horizontal, 12)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.group, style: .continuous))
            .padding(.horizontal, Spacing.screen)

            SignLogPanel(lines: progress.log)
                .frame(minHeight: 140, maxHeight: .infinity)
                .padding(.horizontal, Spacing.screen)

            footer
                .padding(.horizontal, Spacing.screen)
                .padding(.bottom, 12)
        }
        .background(Color.stoneBG.ignoresSafeArea())
        .sheet(isPresented: $showShare) {
            ShareSheet(items: shareItems)
        }
        .task { await run() }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { breathe = true }
        }
    }

    // MARK: Cabeçalho (um único X — sem o X pequeno da linha por cima)

    private var header: some View {
        VStack(spacing: 10) {
            XGlyph()
                .fill(glyphColor)
                .frame(width: 40, height: 40)
                .scaleEffect(progress.finished ? 1.08 : (breathe && isRunning ? 0.94 : 1))
                .animation(.xsignSmooth, value: progress.finished)

            SignatureLine(progress: progress.fraction, warning: progress.error != nil, showsGlyph: false)
                .frame(width: 120)
                .padding(.top, 4)

            Text(titleText)
                .font(.headline)
                .contentTransition(.opacity)
                .padding(.top, 6)

            Group {
                if progress.finished {
                    Text(progress.finalBundleID ?? options.bundleID ?? app.bundleID)
                        .font(.caption.monospaced())
                } else if progress.error != nil {
                    Text(L.tr("sign.failed"))
                        .font(.caption)
                } else {
                    Text(L.tr("sign.dontClose"))
                        .font(.caption)
                }
            }
            .foregroundStyle(.secondary)
            .transition(.motionBlur)
        }
        .animation(.xsignSmooth, value: progress.finished)
        .animation(.xsignSmooth, value: progress.error)
    }

    private var isRunning: Bool { !progress.finished && progress.error == nil }

    private var glyphColor: Color {
        if progress.error != nil { return .brick }
        if progress.finished { return .moss }
        return .graphite
    }

    private var titleText: String {
        if progress.finished { return L.tr("sign.done") }
        if progress.error != nil { return L.tr("sign.failedTitle") }
        return L.tr("sign.signing", options.name ?? app.name)
    }

    // MARK: Rodapé

    @ViewBuilder
    private var footer: some View {
        if progress.finished {
            VStack(spacing: 8) {
                PrimaryButton(title: L.tr("apps.action.install")) { install() }
                SecondaryButton(title: L.tr("apps.action.share")) {
                    if let uStr = progress.shareURL ?? progress.downloadURL, let u = URL(string: uStr) {
                        shareItems = [u]
                        showShare = true
                    }
                }
                Button(L.tr("common.close")) {
                    dismiss()
                    onCompleteDismissParent?()
                }
                .padding(.top, 2)
            }
            .transition(.motionBlur)
        } else if progress.error != nil {
            VStack(spacing: 8) {
                SecondaryButton(title: L.tr("sign.shareLog"), systemImage: "square.and.arrow.up") {
                    shareItems = [SignLogLine.plainText(progress.log)]
                    showShare = true
                }
                Button(L.tr("common.close")) { dismiss() }
                    .padding(.top, 2)
            }
            .transition(.motionBlur)
        } else {
            Button(L.tr("common.cancel")) { dismiss() }
                .padding(.vertical, 6)
        }
    }

    // MARK: Fluxo

    private func run() async {
        for await update in appState.signingService.sign(app: app, certificate: certificate, options: options) {
            withAnimation(.xsignSmooth) {
                progress = update
            }
        }
        if progress.finished {
            appState.registerSigned(original: app, certificate: certificate, options: options, progress: progress)
            if appState.settings.installAfterSign {
                install()
            }
        }
    }

    private func install() {
        Task {
            if let installURL = progress.installURL {
                try? await appState.openInstall(
                    installURL,
                    bundleID: progress.finalBundleID ?? options.bundleID ?? app.bundleID
                )
            } else {
                try? await appState.installService.install(
                    ipaPath: progress.outputPath ?? app.filePath,
                    bundleID: progress.finalBundleID ?? options.bundleID ?? app.bundleID,
                    version: progress.finalVersion ?? options.version ?? app.version,
                    title: progress.finalName ?? options.name ?? app.name
                )
            }
        }
    }
}

struct StepRow: View {
    let step: SignStep

    var body: some View {
        HStack(spacing: 9) {
            icon
                .transition(.scale.combined(with: .opacity))
                .id(iconKey)
            Text(step.kind.label).font(.callout)
            Spacer()
            Text(detail)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .padding(.vertical, 7)
        .opacity(isPending ? 0.5 : 1)
        .animation(.xsignSmooth, value: iconKey)
    }

    private var isPending: Bool { if case .waiting = step.state { return true }; return false }

    private var iconKey: String {
        switch step.state {
        case .waiting: return "waiting"
        case .running: return "running"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    @ViewBuilder private var icon: some View {
        switch step.state {
        case .done:
            Image(systemName: "checkmark").font(.caption2.weight(.bold))
                .foregroundStyle(Color.onGraphite).frame(width: 16, height: 16)
                .background(Color.graphite, in: Circle())
        case .running:
            ProgressView().controlSize(.mini).frame(width: 16, height: 16)
        case .failed:
            Image(systemName: "xmark").font(.caption2.weight(.bold))
                .foregroundStyle(Color.onGraphite).frame(width: 16, height: 16)
                .background(Color.brick, in: Circle())
        case .waiting:
            Circle().stroke(Color.hairline, lineWidth: 1.5).frame(width: 15, height: 15)
        }
    }

    private var detail: String {
        switch step.state {
        case .running(let d): return d ?? ""
        case .done(let s): return s.map { String(format: "%.1f s", $0) } ?? ""
        default: return ""
        }
    }
}
