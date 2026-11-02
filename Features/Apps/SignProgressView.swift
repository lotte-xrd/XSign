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

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            XGlyph().fill(Color.graphite).frame(width: 42, height: 42)
                .overlay(alignment: .bottom) {
                    SignatureLine(progress: progress.fraction)
                        .frame(width: 60).offset(y: 14)
                }

            Text(progress.finished ? L.tr("sign.done") : L.tr("sign.signing", options.name ?? app.name))
                .font(.headline)
                .padding(.top, 8)
            if progress.finished {
                Text(progress.finalBundleID ?? options.bundleID ?? app.bundleID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                Text(L.tr("sign.dontClose")).font(.caption).foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(progress.steps) { step in
                    StepRow(step: step)
                    if step.id != progress.steps.last?.id { Divider() }
                }
            }
            .padding(.horizontal, 12)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.group, style: .continuous))
            .padding(.horizontal, Spacing.screen)

            Spacer()

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
                    .padding(.top, 4)
                }
                .padding(Spacing.screen)
            } else if progress.error != nil {
                VStack(spacing: 8) {
                    Text(progress.error ?? "")
                        .font(.caption)
                        .foregroundStyle(Color.brick)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    SecondaryButton(title: L.tr("sign.copyLog")) {
                        UIPasteboard.general.string = progress.error
                    }
                    Button(L.tr("common.close")) { dismiss() }
                }
                .padding(Spacing.screen)
            } else {
                Button(L.tr("common.cancel")) { dismiss() }
                    .padding(.bottom, Spacing.screen)
            }
        }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: shareItems)
        }
        .task { await run() }
    }

    private func run() async {
        for await update in appState.signingService.sign(app: app, certificate: certificate, options: options) {
            progress = update
        }
        if progress.finished { registerSigned() }
    }

    private func registerSigned() {
        var signed = app
        signed.id = UUID()
        signed.state = .signed
        signed.certificateID = certificate.id
        signed.certificateName = certificate.nickname
        signed.signedAt = Date()
        signed.filePath = progress.outputPath ?? app.filePath
        signed.installURL = progress.installURL
        signed.signedDownloadURL = progress.downloadURL
        signed.shareURL = progress.shareURL
        signed.name = progress.finalName ?? options.name ?? app.name
        signed.bundleID = progress.finalBundleID ?? options.bundleID ?? app.bundleID
        signed.version = progress.finalVersion ?? options.version ?? app.version
        if let fSize = progress.fileSize, fSize > 0 {
            signed.size = fSize
        }

        appState.apps.insert(signed, at: 0)
        if appState.settings.deleteOriginalAfterSign, app.state == .unsigned {
            appState.delete(app)
        } else {
            appState.persist()
        }

        if appState.settings.installAfterSign {
            install()
        }
    }

    private func install() {
        Task {
            if let installURL = progress.installURL {
                try? await appState.installService.openInstallURL(installURL)
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
            Text(step.kind.label).font(.callout)
            Spacer()
            Text(detail).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 7)
        .opacity(isPending ? 0.5 : 1)
    }

    private var isPending: Bool { if case .waiting = step.state { return true }; return false }

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
