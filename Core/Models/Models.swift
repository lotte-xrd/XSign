import SwiftUI

// MARK: - Fonte (repositório)

enum SourceFormat: String, Codable { case altstore, scarlet, legacy }

struct Source: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var url: URL
    var name: String
    var iconURL: URL?
    var format: SourceFormat = .altstore
    var lastFetched: Date?
    var lastError: String?
    var order: Int = 0
    var appCount: Int = 0
}

/// Um app listado por uma fonte. Vem do cache, não é persistido no store.
struct SourceApp: Identifiable, Codable, Hashable {
    var id: String { bundleID + "@" + (sourceID?.uuidString ?? "") }
    var name: String
    var bundleID: String
    var developer: String?
    var iconURL: URL?
    var sourceID: UUID?
    var sourceName: String?
    var versions: [AppVersion]

    var latest: AppVersion? { versions.first }
}

struct AppVersion: Codable, Hashable {
    var version: String
    var downloadURL: URL
    var size: Int64?
    var date: Date?
    var notes: String?
    var sha256: String?
}

// MARK: - Download

enum DownloadState: String, Codable { case queued, running, paused, finished, failed }

struct DownloadTask: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var url: URL
    var name: String
    var bytesWritten: Int64 = 0
    var totalBytes: Int64 = 0
    var state: DownloadState = .queued
    var error: String?

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(bytesWritten) / Double(totalBytes))
    }
}

// MARK: - App no dispositivo

enum AppState2: String, Codable { case unsigned, signed }

struct AppItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var bundleID: String
    var version: String
    var iconPath: String?
    var filePath: String
    var size: Int64
    var state: AppState2 = .unsigned
    var certificateID: UUID?
    var certificateName: String?
    var signedAt: Date?
    var origin: String?
}

// MARK: - Certificado

enum CertStatus: String, Codable {
    case valid, expiring, expired, revoked, unknown

    var label: String {
        switch self {
        case .valid:    return L.tr("cert.status.valid")
        case .expiring: return L.tr("cert.status.expiring")
        case .expired:  return L.tr("cert.status.expired")
        case .revoked:  return L.tr("cert.status.revoked")
        case .unknown:  return L.tr("cert.status.unknown")
        }
    }

    var color: Color {
        switch self {
        case .valid:    return .moss
        case .expiring: return .ochre
        case .expired, .revoked: return .brick
        case .unknown:  return .lead
        }
    }

    var canSign: Bool { self == .valid || self == .expiring || self == .unknown }
}

struct Certificate: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var nickname: String
    var teamID: String
    var teamName: String?
    var type: String            // "Apple Development", "iPhone Distribution"…
    var appID: String?
    var issuedAt: Date?
    var expiresAt: Date?
    var devices: [String] = []
    var entitlementsCount: Int = 0
    var p12Path: String
    var profilePath: String
    var keychainKey: String
    var status: CertStatus = .unknown
    var checkedAt: Date?
    var inUse: Bool = false

    /// Validade combinada (a menor entre certificado e perfil é gravada em expiresAt).
    var daysLeft: Int? {
        guard let expiresAt else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day
    }

    /// Fração de validade restante para a SignatureLine (assume ~365 dias de janela).
    var validityFraction: Double {
        guard let days = daysLeft else { return 0 }
        return max(0, min(1, Double(days) / 365.0))
    }
}

// MARK: - Opções e trabalho de assinatura

struct Injection: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var path: String
}

struct SignOptions: Codable, Hashable {
    var name: String?
    var bundleID: String?
    var version: String?
    var iconData: Data?
    var injections: [Injection] = []
    var removeExtensions: Bool = true
    var removeDeviceRestriction: Bool = true
    var fileSharing: Bool = false
    var minOS: String?
    var entitlements: [String: String]?
}

enum SignStepKind: String, Codable, CaseIterable {
    case extract, modify, inject, sign, pack, install

    var label: String {
        switch self {
        case .extract: return L.tr("sign.step.extract")
        case .modify:  return L.tr("sign.step.modify")
        case .inject:  return L.tr("sign.step.inject")
        case .sign:    return L.tr("sign.step.sign")
        case .pack:    return L.tr("sign.step.pack")
        case .install: return L.tr("sign.step.install")
        }
    }
}

enum StepState: Equatable { case waiting, running(detail: String?), done(seconds: Double?), failed(String) }

struct SignStep: Identifiable, Equatable {
    var id = UUID()
    var kind: SignStepKind
    var state: StepState = .waiting
}

/// Progresso emitido pelo SigningService.
struct SignProgress: Equatable {
    var steps: [SignStep]
    var fraction: Double
    var finished: Bool = false
    var outputPath: String?
    var error: String?
}
