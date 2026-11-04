import SwiftUI

/// Um lote de apps escolhidos na aba Apps.
struct BulkSignJob: Identifiable {
    let id = UUID()
    let apps: [AppItem]
}

/// Assina vários apps em fila, com o mesmo certificado e as opções padrão de cada um.
struct BulkSignView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let apps: [AppItem]

    private enum ItemState: Equatable {
        case waiting
        case running(Double)
        case done(AppItem)
        case failed(String)
    }

    @State private var states: [UUID: ItemState] = [:]
    @State private var log: [SignLogLine] = []
    @State private var currentIndex = 0
    @State private var finished = false
    @State private var cancelled = false
    @State private var runner: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                header
                    .padding(.top, 8)

                List {
                    ForEach(apps) { item in
                        row(for: item)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 160)

                SignLogPanel(lines: log)
                    .frame(minHeight: 130, maxHeight: 220)
                    .padding(.horizontal, Spacing.screen)

                footer
                    .padding(.horizontal, Spacing.screen)
                    .padding(.bottom, 12)
            }
            .background(Color.stoneBG.ignoresSafeArea())
            .navigationTitle(L.tr("bulk.title"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(!finished)
        }
        .onAppear {
            guard runner == nil else { return }
            runner = Task { await runAll() }
        }
        .onDisappear { runner?.cancel() }
    }

    // MARK: Cabeçalho

    private var header: some View {
        VStack(spacing: 8) {
            XGlyph()
                .fill(finished ? (failedCount > 0 ? Color.ochre : Color.moss) : Color.graphite)
                .frame(width: 30, height: 30)
                .animation(.xsignSmooth, value: finished)
            SignatureLine(progress: overallFraction, showsGlyph: false)
                .frame(width: 140)
            Text(headline)
                .font(.headline)
                .contentTransition(.numericText())
                .animation(.xsignSmooth, value: headline)
            if let cert = appState.currentCertificate {
                Text(cert.nickname)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var doneCount: Int {
        states.values.filter { if case .done = $0 { return true }; return false }.count
    }

    private var failedCount: Int {
        states.values.filter { if case .failed = $0 { return true }; return false }.count
    }

    private var overallFraction: Double {
        guard !apps.isEmpty else { return 0 }
        var total = 0.0
        for item in apps {
            switch states[item.id] ?? .waiting {
            case .done, .failed: total += 1
            case .running(let f): total += f
            case .waiting: break
            }
        }
        return total / Double(apps.count)
    }

    private var headline: String {
        if finished {
            return failedCount == 0
                ? L.tr("bulk.doneAll", doneCount)
                : L.tr("bulk.doneSome", doneCount, failedCount)
        }
        return L.tr("bulk.progress", min(currentIndex + 1, apps.count), apps.count)
    }

    // MARK: Linhas

    @ViewBuilder
    private func row(for item: AppItem) -> some View {
        let state = states[item.id] ?? .waiting
        HStack(spacing: 12) {
            AppIconThumb(name: item.name, iconPath: item.iconPath, url: item.iconURL, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                switch state {
                case .waiting:
                    Text(L.tr("bulk.waiting")).font(.caption).foregroundStyle(.secondary)
                case .running(let f):
                    ProgressView(value: f).tint(Color.graphite)
                case .done(let signed):
                    Text(signed.bundleID).font(.caption.monospaced()).foregroundStyle(Color.moss).lineLimit(1)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(Color.brick).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            switch state {
            case .done(let signed):
                PillButton(title: L.tr("apps.action.install"), filled: true) { install(signed) }
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(Color.brick)
            case .running:
                ProgressView().controlSize(.small)
            case .waiting:
                Circle().stroke(Color.hairline, lineWidth: 1.5).frame(width: 16, height: 16)
            }
        }
        .padding(.vertical, 2)
        .animation(.xsignSmooth, value: state)
        .listRowBackground(Color.surface)
    }

    // MARK: Rodapé

    @ViewBuilder
    private var footer: some View {
        if finished {
            PrimaryButton(title: L.tr("common.close")) { dismiss() }
                .transition(.motionBlur)
        } else {
            SecondaryButton(title: L.tr("bulk.stop"), systemImage: "stop.fill") {
                cancelled = true
                runner?.cancel()
            }
            .disabled(cancelled)
            .opacity(cancelled ? 0.5 : 1)
        }
    }

    // MARK: Fila

    private func runAll() async {
        guard let cert = appState.currentCertificate else {
            appendLog(SignLogLine(level: .error, text: L.tr("sign.noCert")))
            withAnimation(.xsignSmooth) { finished = true }
            return
        }

        appendLog(SignLogLine(level: .info, text: L.tr("bulk.log.start", apps.count, cert.nickname)))

        for (index, item) in apps.enumerated() {
            if Task.isCancelled || cancelled { break }
            withAnimation(.xsignSmooth) {
                currentIndex = index
                states[item.id] = .running(0.02)
            }

            let options = SignOptions(name: item.name, bundleID: item.bundleID, version: item.version)
            var last = SignProgress(steps: [], fraction: 0)
            var seen = 0
            for await update in appState.signingService.sign(app: item, certificate: cert, options: options) {
                last = update
                if update.log.count > seen {
                    let fresh = update.log[seen...].map { line -> SignLogLine in
                        var tagged = line
                        tagged.tag = item.name
                        return tagged
                    }
                    seen = update.log.count
                    appendLog(contentsOf: fresh)
                }
                withAnimation(.xsignSmooth) {
                    states[item.id] = .running(update.fraction)
                }
            }

            if last.finished {
                let signed = appState.registerSigned(original: item, certificate: cert, options: options, progress: last)
                withAnimation(.xsignSmooth) { states[item.id] = .done(signed) }
            } else {
                let message = last.error ?? L.tr("bulk.cancelled")
                withAnimation(.xsignSmooth) { states[item.id] = .failed(message) }
            }
        }

        // O que ficou para trás depois de parar
        for item in apps where (states[item.id] ?? .waiting) == .waiting {
            states[item.id] = .failed(L.tr("bulk.cancelled"))
        }
        appendLog(SignLogLine(level: failedCount == 0 ? .success : .warning,
                              text: L.tr("bulk.log.end", doneCount, failedCount)))
        withAnimation(.xsignSmooth) { finished = true }
    }

    private func appendLog(_ line: SignLogLine) {
        appendLog(contentsOf: [line])
    }

    private func appendLog(contentsOf lines: [SignLogLine]) {
        withAnimation(.xsignSmooth) {
            log.append(contentsOf: lines)
            if log.count > 600 { log.removeFirst(log.count - 600) }
        }
    }

    private func install(_ item: AppItem) {
        guard let url = item.installURL else { return }
        Task { try? await appState.openInstall(url, bundleID: item.bundleID) }
    }
}
