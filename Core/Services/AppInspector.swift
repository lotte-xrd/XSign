import Foundation
import ZIPFoundation

/// Tudo o que dá para saber de um .ipa sem instalá-lo.
struct AppReport {
    struct Item: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let size: Int64
    }

    struct Permission: Identifiable, Hashable {
        var id: String { key }
        let key: String
        let label: String
        let reason: String
    }

    var name = ""
    var bundleID = ""
    var version = ""
    var build = ""
    var minimumOS: String?
    var executable: String?
    var devices: [String] = []
    var urlSchemes: [String] = []
    var permissions: [Permission] = []
    var backgroundModes: [String] = []
    var fileSharing = false
    var frameworks: [Item] = []
    var plugins: [Item] = []
    var linkedLibraries: [String] = []
    var architectures: [String] = []
    var binaryMinOS: String?
    var encrypted = false
    var entitlements: [String: Any] = [:]
    var signedBy: CertificateService.ProfileInfo?
    var installedSize: Int64 = 0
    var archiveSize: Int64 = 0
    var infoPlist: [String: Any] = [:]

    /// Dependências que não são do sistema (tweaks injetados, frameworks do app).
    var embeddedLibraries: [String] {
        linkedLibraries.filter { $0.hasPrefix("@") }
    }
}

enum AppInspector {
    enum InspectError: LocalizedError {
        case invalidArchive
        case noApp

        var errorDescription: String? {
            switch self {
            case .invalidArchive: return L.tr("appinfo.error.archive")
            case .noApp: return L.tr("appinfo.error.noApp")
            }
        }
    }

    static func inspect(ipaURL: URL) throws -> AppReport {
        guard let archive = Archive(url: ipaURL, accessMode: .read) else { throw InspectError.invalidArchive }
        var report = AppReport()
        report.archiveSize = (try? FileManager.default.attributesOfItem(atPath: ipaURL.path)[.size] as? Int64) ?? 0

        // Pasta Payload/<App>.app/
        var prefix = ""
        for entry in archive {
            let parts = entry.path.split(separator: "/")
            if parts.count >= 2, parts[0].lowercased() == "payload", parts[1].lowercased().hasSuffix(".app") {
                prefix = "\(parts[0])/\(parts[1])/"
                break
            }
        }
        guard !prefix.isEmpty else { throw InspectError.noApp }

        // Tamanhos, frameworks e extensões
        var frameworkSizes: [String: Int64] = [:]
        var pluginSizes: [String: Int64] = [:]
        for entry in archive where entry.path.hasPrefix(prefix) {
            let size = Int64(entry.uncompressedSize)
            report.installedSize += size
            let rel = String(entry.path.dropFirst(prefix.count))
            let parts = rel.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { continue }
            if parts[0] == "Frameworks" {
                frameworkSizes[parts[1], default: 0] += size
            } else if parts[0] == "PlugIns" || parts[0] == "Extensions" {
                if parts[1].hasSuffix(".appex") { pluginSizes[parts[1], default: 0] += size }
            } else if parts[0] == "Watch" {
                pluginSizes[parts[1], default: 0] += size
            }
        }
        report.frameworks = frameworkSizes.map { AppReport.Item(name: $0.key, size: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        report.plugins = pluginSizes.map { AppReport.Item(name: $0.key, size: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // Info.plist
        if let entry = archive[prefix + "Info.plist"] {
            var data = Data()
            _ = try archive.extract(entry, consumer: { data.append($0) })
            if let dict = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                report.infoPlist = dict
                fill(&report, from: dict)
            }
        }

        // Perfil embutido (apps já assinados)
        if let entry = archive[prefix + "embedded.mobileprovision"] {
            var data = Data()
            _ = try? archive.extract(entry, consumer: { data.append($0) })
            report.signedBy = try? CertificateService().readProfile(data: data)
        }

        // Binário principal: arquiteturas, iOS mínimo, criptografia, dylibs e entitlements
        if let exe = report.executable, let entry = archive[prefix + exe] {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("xsign-inspect-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temp) }
            _ = try archive.extract(entry, to: temp)
            if let macho = try? MachOFile(url: temp) {
                report.architectures = macho.architectures
                report.binaryMinOS = macho.minimumOS
                report.encrypted = macho.isEncrypted
                report.linkedLibraries = macho.loadedDylibs
                report.entitlements = macho.entitlements() ?? [:]
            }
        }

        return report
    }

    private static func fill(_ report: inout AppReport, from dict: [String: Any]) {
        report.name = (dict["CFBundleDisplayName"] as? String) ?? (dict["CFBundleName"] as? String) ?? ""
        report.bundleID = dict["CFBundleIdentifier"] as? String ?? ""
        report.version = dict["CFBundleShortVersionString"] as? String ?? ""
        report.build = dict["CFBundleVersion"] as? String ?? ""
        report.minimumOS = dict["MinimumOSVersion"] as? String
        report.executable = dict["CFBundleExecutable"] as? String
        report.fileSharing = (dict["UIFileSharingEnabled"] as? Bool) ?? false
        report.backgroundModes = dict["UIBackgroundModes"] as? [String] ?? []

        let families = (dict["UIDeviceFamily"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue ?? Int("\($0)") } ?? [1]
        report.devices = families.compactMap { (f: Int) -> String? in
            switch f {
            case 1: return "iPhone"
            case 2: return "iPad"
            case 3: return "Apple TV"
            case 4: return "Apple Watch"
            case 6: return "Mac Catalyst"
            case 7: return "Vision"
            default: return nil
            }
        }

        if let types = dict["CFBundleURLTypes"] as? [[String: Any]] {
            report.urlSchemes = types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        }

        report.permissions = dict.keys
            .filter { $0.hasSuffix("UsageDescription") }
            .sorted()
            .map { key in
                AppReport.Permission(key: key, label: permissionLabel(key), reason: (dict[key] as? String) ?? "")
            }
    }

    static func permissionLabel(_ key: String) -> String {
        let map: [String: String] = [
            "NSCameraUsageDescription": "privacy.camera",
            "NSMicrophoneUsageDescription": "privacy.microphone",
            "NSPhotoLibraryUsageDescription": "privacy.photos",
            "NSPhotoLibraryAddUsageDescription": "privacy.photosAdd",
            "NSLocationWhenInUseUsageDescription": "privacy.location",
            "NSLocationAlwaysAndWhenInUseUsageDescription": "privacy.locationAlways",
            "NSLocationAlwaysUsageDescription": "privacy.locationAlways",
            "NSLocationUsageDescription": "privacy.location",
            "NSContactsUsageDescription": "privacy.contacts",
            "NSCalendarsUsageDescription": "privacy.calendars",
            "NSCalendarsFullAccessUsageDescription": "privacy.calendars",
            "NSRemindersUsageDescription": "privacy.reminders",
            "NSRemindersFullAccessUsageDescription": "privacy.reminders",
            "NSBluetoothAlwaysUsageDescription": "privacy.bluetooth",
            "NSBluetoothPeripheralUsageDescription": "privacy.bluetooth",
            "NSFaceIDUsageDescription": "privacy.faceID",
            "NSMotionUsageDescription": "privacy.motion",
            "NSLocalNetworkUsageDescription": "privacy.localNetwork",
            "NSUserTrackingUsageDescription": "privacy.tracking",
            "NSAppleMusicUsageDescription": "privacy.media",
            "NSSpeechRecognitionUsageDescription": "privacy.speech",
            "NSHealthShareUsageDescription": "privacy.health",
            "NSHealthUpdateUsageDescription": "privacy.health",
            "NSHomeKitUsageDescription": "privacy.home",
            "NSSiriUsageDescription": "privacy.siri",
            "NFCReaderUsageDescription": "privacy.nfc"
        ]
        if let k = map[key] { return L.tr(k) }
        return key.replacingOccurrences(of: "UsageDescription", with: "").replacingOccurrences(of: "NS", with: "")
    }
}
