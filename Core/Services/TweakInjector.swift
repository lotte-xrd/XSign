import Foundation

/// Injeta tweaks (.dylib, .deb, .framework, .bundle) num `.app` extraído, no próprio
/// iPhone, antes de o IPA ser enviado para assinar. Dependências do Substrate são
/// redirecionadas para o ElleKit embutido como `CydiaSubstrate.framework`.
struct TweakInjector {
    typealias Logger = (String, SignLogLevel) -> Void

    static let substratePath = "@rpath/CydiaSubstrate.framework/CydiaSubstrate"
    static let frameworksRPath = "@executable_path/Frameworks"

    enum InjectError: LocalizedError {
        case noExecutable
        case nothingToInject

        var errorDescription: String? {
            switch self {
            case .noExecutable: return L.tr("tweak.error.noExecutable")
            case .nothingToInject: return L.tr("tweak.error.nothing")
            }
        }
    }

    struct Summary {
        var injected: [String] = []
        var copied: [String] = []
        var substrateAdded = false
    }

    let appDirectory: URL
    let log: Logger

    private var fm: FileManager { .default }

    // MARK: Plano do que copiar e injetar

    private struct Plan {
        var inject: [URL] = []            // dylibs carregadas pelo app
        var injectFrameworks: [URL] = []  // frameworks escolhidos como tweak
        var support: [URL] = []           // dylibs de apoio (só copiadas)
        var frameworks: [URL] = []        // frameworks de apoio (só copiados)
        var bundles: [URL] = []           // .bundle de recursos
        var substrateBinary: URL?         // libellekit / CydiaSubstrate vindo de um .deb

        mutating func add(_ url: URL, to keyPath: WritableKeyPath<Plan, [URL]>) {
            let name = url.lastPathComponent
            let all = inject + injectFrameworks + support + frameworks + bundles
            guard !all.contains(where: { $0.lastPathComponent == name }) else { return }
            self[keyPath: keyPath].append(url)
        }
    }

    func inject(_ files: [URL]) throws -> Summary {
        let info = (NSDictionary(contentsOf: appDirectory.appendingPathComponent("Info.plist")) as? [String: Any]) ?? [:]
        guard let executableName = info["CFBundleExecutable"] as? String,
              fm.fileExists(atPath: appDirectory.appendingPathComponent(executableName).path) else {
            throw InjectError.noExecutable
        }
        let executableURL = appDirectory.appendingPathComponent(executableName)
        let frameworksDir = appDirectory.appendingPathComponent("Frameworks", isDirectory: true)
        try fm.createDirectory(at: frameworksDir, withIntermediateDirectories: true)

        let scratch = fm.temporaryDirectory.appendingPathComponent("xsign-tweaks-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        // 1. Montar o plano
        var plan = Plan()
        for file in files {
            let ext = file.pathExtension.lowercased()
            guard fm.fileExists(atPath: file.path) else {
                log(L.tr("tweak.log.missing", file.lastPathComponent), .warning)
                continue
            }
            switch ext {
            case "dylib":
                plan.add(file, to: \.inject)
                log(L.tr("tweak.log.dylib", file.lastPathComponent), .info)
            case "deb":
                log(L.tr("tweak.log.openingDeb", file.lastPathComponent), .info)
                let dest = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try DebExtractor.extract(debURL: file, to: dest)
                collect(from: dest, into: &plan)
            case "framework":
                plan.add(file, to: \.injectFrameworks)
                log(L.tr("tweak.log.framework", file.lastPathComponent), .info)
            case "bundle":
                plan.add(file, to: \.bundles)
            default:
                log(L.tr("tweak.log.unsupported", file.lastPathComponent), .warning)
            }
        }

        guard !plan.inject.isEmpty || !plan.injectFrameworks.isEmpty else {
            throw InjectError.nothingToInject
        }

        // 2. Copiar tudo para dentro do app
        var summary = Summary()
        var rpathMap: [String: String] = [:]   // nome do arquivo/framework -> novo caminho @rpath
        var machOs: [URL] = []

        for fw in plan.frameworks + plan.injectFrameworks {
            let dest = frameworksDir.appendingPathComponent(fw.lastPathComponent, isDirectory: true)
            try replaceCopy(from: fw, to: dest)
            let exe = frameworkExecutable(dest)
            rpathMap[fw.lastPathComponent] = "@rpath/\(fw.lastPathComponent)/\(exe)"
            machOs.append(dest.appendingPathComponent(exe))
            summary.copied.append(fw.lastPathComponent)
        }
        for lib in plan.support + plan.inject {
            let dest = frameworksDir.appendingPathComponent(lib.lastPathComponent)
            try replaceCopy(from: lib, to: dest)
            rpathMap[lib.lastPathComponent] = "@rpath/\(lib.lastPathComponent)"
            machOs.append(dest)
        }
        for bundle in plan.bundles {
            let dest = appDirectory.appendingPathComponent(bundle.lastPathComponent, isDirectory: true)
            try replaceCopy(from: bundle, to: dest)
            summary.copied.append(bundle.lastPathComponent)
            log(L.tr("tweak.log.bundle", bundle.lastPathComponent), .detail)
        }
        if !plan.support.isEmpty {
            log(L.tr("tweak.log.support", plan.support.map { $0.lastPathComponent }.joined(separator: ", ")), .detail)
        }

        // 3. Corrigir dependências de cada binário copiado
        var needsSubstrate = false
        for binary in machOs where MachOFile.isMachO(binary) {
            let macho = try MachOFile(url: binary)
            for dep in macho.loadedDylibs {
                if Self.isSubstrate(dep) {
                    needsSubstrate = true
                    if dep != Self.substratePath {
                        try macho.changeDylibPath(from: dep, to: Self.substratePath)
                        log(L.tr("tweak.log.relink", binary.lastPathComponent, "CydiaSubstrate"), .detail)
                    }
                } else if let target = Self.mappedPath(for: dep, in: rpathMap), target != dep {
                    try macho.changeDylibPath(from: dep, to: target)
                    log(L.tr("tweak.log.relink", binary.lastPathComponent, (target as NSString).lastPathComponent), .detail)
                }
            }
            if binary.pathExtension.lowercased() == "dylib", macho.installName != nil {
                try macho.setInstallName("@rpath/\(binary.lastPathComponent)")
            }
            try macho.save()
        }

        // 4. Injetar no executável principal
        let main = try MachOFile(url: executableURL)
        if main.isEncrypted {
            log(L.tr("tweak.log.encrypted"), .warning)
        }
        if try main.addRpath(Self.frameworksRPath) {
            log(L.tr("tweak.log.rpath"), .detail)
        }
        for lib in plan.inject {
            let path = "@rpath/\(lib.lastPathComponent)"
            if try main.addDylib(path) {
                summary.injected.append(lib.lastPathComponent)
                log(L.tr("tweak.log.injected", lib.lastPathComponent), .success)
            } else {
                log(L.tr("tweak.log.already", lib.lastPathComponent), .detail)
            }
        }
        for fw in plan.injectFrameworks {
            let path = rpathMap[fw.lastPathComponent] ?? "@rpath/\(fw.lastPathComponent)/\(fw.deletingPathExtension().lastPathComponent)"
            if try main.addDylib(path) {
                summary.injected.append(fw.lastPathComponent)
                log(L.tr("tweak.log.injected", fw.lastPathComponent), .success)
            } else {
                log(L.tr("tweak.log.already", fw.lastPathComponent), .detail)
            }
        }
        try main.save()

        // 5. Substrate -> ElleKit
        let substrateDest = frameworksDir.appendingPathComponent("CydiaSubstrate.framework", isDirectory: true)
        if needsSubstrate {
            if fm.fileExists(atPath: substrateDest.appendingPathComponent("CydiaSubstrate").path) {
                log(L.tr("tweak.log.substrateExists"), .detail)
            } else if let source = plan.substrateBinary ?? findElleKit(scratch: scratch) {
                try installSubstrate(from: source, into: substrateDest)
                summary.substrateAdded = true
                log(L.tr("tweak.log.ellekit"), .success)
            } else {
                log(L.tr("tweak.log.noSubstrate"), .warning)
            }
        }

        return summary
    }

    // MARK: - Coleta dentro de um .deb extraído

    private func collect(from root: URL, into plan: inout Plan) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        var found = 0
        while let url = walker.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            let name = url.lastPathComponent
            let lower = name.lowercased()
            let parent = url.deletingLastPathComponent().lastPathComponent
            let path = url.path

            if values?.isDirectory == true {
                if lower.hasSuffix(".framework") {
                    walker.skipDescendants()
                    if lower == "cydiasubstrate.framework" {
                        let bin = url.appendingPathComponent("CydiaSubstrate")
                        if plan.substrateBinary == nil, fm.fileExists(atPath: bin.path) { plan.substrateBinary = bin }
                    } else {
                        plan.add(url, to: \.frameworks)
                    }
                } else if lower.hasSuffix(".bundle") {
                    walker.skipDescendants()
                    if !path.contains("PreferenceBundles") { plan.add(url, to: \.bundles) }
                } else if lower == "preferencebundles" || lower == "preferenceloader" {
                    walker.skipDescendants()
                }
                continue
            }

            guard values?.isRegularFile == true else { continue }
            if lower == "libellekit.dylib" || lower == "libsubstrate.dylib" || lower == "libsubstitute.dylib" {
                if plan.substrateBinary == nil { plan.substrateBinary = url }
                continue
            }
            guard lower.hasSuffix(".dylib") else { continue }
            if parent == "DynamicLibraries" || parent == "TweakInject" {
                plan.add(url, to: \.inject)
                log(L.tr("tweak.log.fromDeb", name), .detail)
                found += 1
            } else {
                plan.add(url, to: \.support)
            }
        }
        if found == 0 {
            log(L.tr("tweak.log.debEmpty"), .warning)
        }
    }

    // MARK: - ElleKit

    /// Procura o ElleKit: primeiro o que vem dentro do XSign, depois a pasta Tweaks.
    private func findElleKit(scratch: URL) -> URL? {
        var debs: [URL] = []
        if let bundled = Bundle.main.url(forResource: "ellekit", withExtension: "deb") {
            debs.append(bundled)
        }
        let tweaks = (try? fm.contentsOfDirectory(at: Paths.tweaks, includingPropertiesForKeys: nil)) ?? []
        for item in tweaks {
            let lower = item.lastPathComponent.lowercased()
            if lower == "cydiasubstrate.framework" {
                let bin = item.appendingPathComponent("CydiaSubstrate")
                if fm.fileExists(atPath: bin.path) { return bin }
            }
            if lower.hasSuffix(".dylib") && lower.contains("ellekit") { return item }
            if lower.hasSuffix(".deb") && lower.contains("ellekit") { debs.append(item) }
        }
        for deb in debs {
            let dest = scratch.appendingPathComponent("ellekit-\(UUID().uuidString)", isDirectory: true)
            guard (try? DebExtractor.extract(debURL: deb, to: dest)) != nil else { continue }
            if let lib = firstFile(named: "libellekit.dylib", in: dest) { return lib }
            if let lib = firstFile(named: "CydiaSubstrate", in: dest) { return lib }
        }
        return nil
    }

    private func installSubstrate(from source: URL, into frameworkDir: URL) throws {
        try? fm.removeItem(at: frameworkDir)
        try fm.createDirectory(at: frameworkDir, withIntermediateDirectories: true)
        let binary = frameworkDir.appendingPathComponent("CydiaSubstrate")
        try fm.copyItem(at: source.resolvingSymlinksInPath(), to: binary)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let macho = try MachOFile(url: binary)
        try macho.setInstallName(Self.substratePath)
        try macho.save()

        let plist: [String: Any] = [
            "CFBundleExecutable": "CydiaSubstrate",
            "CFBundleIdentifier": "com.xsign.ellekit.substrate",
            "CFBundleName": "CydiaSubstrate",
            "CFBundlePackageType": "FMWK",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundleInfoDictionaryVersion": "6.0",
            "MinimumOSVersion": "12.0"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: frameworkDir.appendingPathComponent("Info.plist"))
    }

    // MARK: - Utilitários

    private func firstFile(named name: String, in root: URL) -> URL? {
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return nil }
        while let url = walker.nextObject() as? URL {
            if url.lastPathComponent == name,
               (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                return url
            }
        }
        return nil
    }

    private func replaceCopy(from source: URL, to destination: URL) throws {
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source.resolvingSymlinksInPath(), to: destination)
    }

    private func frameworkExecutable(_ framework: URL) -> String {
        let info = NSDictionary(contentsOf: framework.appendingPathComponent("Info.plist")) as? [String: Any]
        return (info?["CFBundleExecutable"] as? String) ?? framework.deletingPathExtension().lastPathComponent
    }

    static func isSubstrate(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.contains("cydiasubstrate")
            || lower.hasSuffix("/libsubstrate.dylib")
            || lower.contains("libsubstitute")
            || lower.contains("libellekit")
            || lower.hasSuffix("/libhooker.dylib")
    }

    /// Dependência que aponta para algo que copiamos para Frameworks.
    static func mappedPath(for dependency: String, in map: [String: String]) -> String? {
        if let range = dependency.range(of: ".framework/") {
            let prefix = dependency[..<range.lowerBound]
            let frameworkName = (String(prefix) as NSString).lastPathComponent + ".framework"
            return map[frameworkName]
        }
        return map[(dependency as NSString).lastPathComponent]
    }
}
