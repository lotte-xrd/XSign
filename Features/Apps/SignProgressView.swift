import SwiftUI

struct SignProgressView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let app: AppItem
    let certificate: Certificate
    let options: SignOptions

    @State private var progress = SignProgress(steps: [], fraction: 0)

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            XGlyph().fill(Color.graphite).frame(width: 42, height: 42)
                .overlay(alignment: .bottom) {
                    SignatureLine(progress: progress.fraction)
                        .frame(width: 60).offset(y: 14)
                }

            Text(progress.finished ? L.tr("sign.done") : L.tr("sign.signing", app.name))
                .font(.headline)
            if progress.finished {
                Text(app.name).font(.caption).foregroundStyle(.secondary)
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
                    SecondaryButton(title: L.tr("apps.action.share")) {}
                }
                .padding(Spacing.screen)
            } else if progress.error != nil {
                VStack(spacing: 8) {
                    Text(progress.error ?? "").font(.caption).foregroundStyle(Color.brick)
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
        signed.name = options.name ?? app.name
        signed.bundleID = options.bundleID ?? app.bundleID
        signed.version = options.version ?? app.version
        appState.apps.append(signed)
        appState.persist()
        if appState.settings.installAfterSign { install() }
    }

    private func install() {
        Task {
            try? await appState.installService.install(
                ipaPath: progress.outputPath ?? app.filePath,
                bundleID: options.bundleID ?? app.bundleID,
                version: options.version ?? app.version,
                title: options.name ?? app.name)
            dismiss()
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
            Text(detail).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
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
