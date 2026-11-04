import Foundation
import SWCompression

/// Abre pacotes `.deb` (arquivo `ar` com `data.tar.*`) direto no iPhone.
enum DebExtractor {
    enum DebError: LocalizedError {
        case notDeb
        case noPayload
        case unsupportedCompression(String)

        var errorDescription: String? {
            switch self {
            case .notDeb: return L.tr("deb.error.notDeb")
            case .noPayload: return L.tr("deb.error.noPayload")
            case .unsupportedCompression(let c): return L.tr("deb.error.compression", c)
            }
        }
    }

    /// Extrai o conteúdo (`data.tar.*`) do `.deb` para `directory`.
    static func extract(debURL: URL, to directory: URL) throws {
        let data = try Data(contentsOf: debURL, options: .mappedIfSafe)
        guard data.count > 8, String(decoding: data.prefix(8), as: UTF8.self) == "!<arch>\n" else {
            throw DebError.notDeb
        }

        var position = 8
        var payload: Data?
        var payloadName = ""
        while position + 60 <= data.count {
            let header = data.subdata(in: position..<(position + 60))
            var name = String(decoding: header.prefix(16), as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            if name.hasSuffix("/") { name.removeLast() }
            let sizeText = String(decoding: header.subdata(in: 48..<58), as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            guard let size = Int(sizeText), size >= 0 else { break }
            let start = position + 60
            guard start + size <= data.count else { break }
            if name.hasPrefix("data.tar") {
                payload = data.subdata(in: start..<(start + size))
                payloadName = name
                break
            }
            position = start + size + (size % 2)
        }

        guard let payload else { throw DebError.noPayload }

        let tarData: Data
        if payloadName.hasSuffix(".gz") {
            tarData = try GzipArchive.unarchive(archive: payload)
        } else if payloadName.hasSuffix(".xz") {
            tarData = try XZArchive.unarchive(archive: payload)
        } else if payloadName.hasSuffix(".lzma") {
            tarData = try LZMA.decompress(data: payload)
        } else if payloadName.hasSuffix(".bz2") {
            tarData = try BZip2.decompress(data: payload)
        } else if payloadName.hasSuffix(".zst") || payloadName.hasSuffix(".zstd") {
            throw DebError.unsupportedCompression("zstd")
        } else {
            tarData = payload
        }

        try extractTar(tarData, to: directory)
    }

    private static func extractTar(_ tarData: Data, to directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let entries = try TarContainer.open(container: tarData)
        var links: [(URL, String)] = []

        for entry in entries {
            guard let relative = sanitize(entry.info.name) else { continue }
            let destination = directory.appendingPathComponent(relative)
            switch entry.info.type {
            case .directory:
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            case .regular, .contiguous:
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: destination)
                try (entry.data ?? Data()).write(to: destination)
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            case .symbolicLink:
                links.append((destination, entry.info.linkName))
            default:
                continue
            }
        }

        // Só links relativos: os absolutos (/var/jb/...) apontariam para fora da pasta.
        for (destination, target) in links where !target.isEmpty && !target.hasPrefix("/") {
            try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try? fm.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
        }
    }

    /// Remove "./" e "/" do início e recusa caminhos com "..".
    private static func sanitize(_ raw: String) -> String? {
        let parts = raw.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        return parts.joined(separator: "/")
    }
}
