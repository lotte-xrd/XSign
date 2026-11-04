import Foundation
import Compression

/// Abre pacotes `.deb` (arquivo `ar` com `data.tar.*`) direto no iPhone, usando
/// só o framework Compression da Apple (xz e gzip) e um leitor de tar próprio.
enum DebExtractor {
    enum DebError: LocalizedError {
        case notDeb
        case noPayload
        case unsupportedCompression(String)
        case corrupted

        var errorDescription: String? {
            switch self {
            case .notDeb: return L.tr("deb.error.notDeb")
            case .noPayload: return L.tr("deb.error.noPayload")
            case .unsupportedCompression(let c): return L.tr("deb.error.compression", c)
            case .corrupted: return L.tr("deb.error.noPayload")
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
            var start = position + 60
            guard start + size <= data.count else { break }
            var memberSize = size
            // Formato BSD (ar do macOS): "#1/<n>" e o nome vem nos primeiros n bytes.
            if name.hasPrefix("#1/"), let nameLength = Int(name.dropFirst(3)), nameLength <= size {
                name = String(decoding: data.subdata(in: start..<(start + nameLength)), as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                start += nameLength
                memberSize -= nameLength
            }
            if name.hasPrefix("data.tar") {
                payload = data.subdata(in: start..<(start + memberSize))
                payloadName = name
                break
            }
            position = position + 60 + size + (size % 2)
        }

        guard let payload else { throw DebError.noPayload }

        let tarData: Data
        if payloadName.hasSuffix(".xz") || payloadName.hasSuffix(".lzma") {
            // O LZMA da Apple lê o contêiner .xz; .lzma "puro" (antigo) não é suportado.
            guard payload.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) else {
                throw DebError.unsupportedCompression("lzma")
            }
            tarData = try decompress(payload, using: .lzma)
        } else if payloadName.hasSuffix(".gz") {
            tarData = try gunzip(payload)
        } else if payloadName.hasSuffix(".zst") || payloadName.hasSuffix(".zstd") {
            throw DebError.unsupportedCompression("zstd")
        } else if payloadName.hasSuffix(".bz2") {
            throw DebError.unsupportedCompression("bzip2")
        } else {
            tarData = payload
        }

        try TarReader.extract(tarData, to: directory)
    }

    // MARK: - Descompressão (framework Compression)

    static func decompress(_ input: Data, using algorithm: Algorithm) throws -> Data {
        var output = Data()
        let filter = try OutputFilter(.decompress, using: algorithm) { chunk in
            if let chunk { output.append(chunk) }
        }
        let pageSize = 64 * 1024
        var index = 0
        while index < input.count {
            let end = Swift.min(index + pageSize, input.count)
            try filter.write(input.subdata(in: index..<end))
            index = end
        }
        try filter.finalize()
        return output
    }

    /// gzip = cabeçalho + DEFLATE cru + trailer de 8 bytes.
    static func gunzip(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { throw DebError.corrupted }
        let flags = bytes[3]
        var p = 10
        if flags & 0x04 != 0 {          // FEXTRA
            guard p + 2 <= bytes.count else { throw DebError.corrupted }
            p += 2 + Int(bytes[p]) + Int(bytes[p + 1]) << 8
        }
        if flags & 0x08 != 0 {          // FNAME
            while p < bytes.count && bytes[p] != 0 { p += 1 }
            p += 1
        }
        if flags & 0x10 != 0 {          // FCOMMENT
            while p < bytes.count && bytes[p] != 0 { p += 1 }
            p += 1
        }
        if flags & 0x02 != 0 { p += 2 } // FHCRC
        guard p < bytes.count - 8 else { throw DebError.corrupted }
        return try decompress(data.subdata(in: p..<(data.count - 8)), using: .zlib)
    }
}

// MARK: - Leitor de tar (ustar, GNU long names e pax)

enum TarReader {
    static func extract(_ tar: Data, to directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let bytes = [UInt8](tar)

        var offset = 0
        var longName: String?
        var longLink: String?
        var paxPath: String?
        var paxLink: String?
        var symlinks: [(URL, String)] = []
        var hardlinks: [(URL, String)] = []

        while offset + 512 <= bytes.count {
            let header = Array(bytes[offset..<(offset + 512)])
            if header.allSatisfy({ $0 == 0 }) { break }

            let name = cString(header, 0, 100)
            let size = octal(header, 124, 12)
            let type = header[156]
            let link = cString(header, 157, 100)
            let isUstar = String(decoding: header[257..<262], as: UTF8.self) == "ustar"
            let prefix = isUstar ? cString(header, 345, 155) : ""

            let dataStart = offset + 512
            let dataEnd = Swift.min(dataStart + size, bytes.count)
            let next = dataStart + ((size + 511) / 512) * 512
            defer { offset = next }

            switch type {
            case UInt8(ascii: "L"):
                longName = cString(Array(bytes[dataStart..<dataEnd]), 0, size)
                continue
            case UInt8(ascii: "K"):
                longLink = cString(Array(bytes[dataStart..<dataEnd]), 0, size)
                continue
            case UInt8(ascii: "x"):
                let records = parsePax(Array(bytes[dataStart..<dataEnd]))
                paxPath = records["path"]
                paxLink = records["linkpath"]
                continue
            case UInt8(ascii: "g"):
                continue
            default:
                break
            }

            let fullName = longName ?? paxPath ?? (prefix.isEmpty ? name : prefix + "/" + name)
            let target = longLink ?? paxLink ?? link
            longName = nil
            longLink = nil
            paxPath = nil
            paxLink = nil

            guard let relative = sanitize(fullName) else { continue }
            let destination = directory.appendingPathComponent(relative)

            switch type {
            case UInt8(ascii: "5"):
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            case UInt8(ascii: "0"), 0, UInt8(ascii: "7"):
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: destination)
                try Data(bytes[dataStart..<dataEnd]).write(to: destination)
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            case UInt8(ascii: "2"):
                symlinks.append((destination, target))
            case UInt8(ascii: "1"):
                hardlinks.append((destination, target))
            default:
                continue
            }
        }

        // Hard links: copia o arquivo original (o caminho é relativo à raiz do tar).
        for (destination, target) in hardlinks {
            guard let rel = sanitize(target) else { continue }
            let source = directory.appendingPathComponent(rel)
            try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try? fm.copyItem(at: source, to: destination)
        }

        // Só links simbólicos relativos: os absolutos (/var/jb/...) apontariam para fora.
        for (destination, target) in symlinks where !target.isEmpty && !target.hasPrefix("/") {
            try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try? fm.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
        }
    }

    private static func cString(_ bytes: [UInt8], _ start: Int, _ length: Int) -> String {
        let end = Swift.min(start + length, bytes.count)
        guard start < end else { return "" }
        var slice = bytes[start..<end]
        if let zero = slice.firstIndex(of: 0) { slice = slice[start..<zero] }
        return String(decoding: slice, as: UTF8.self)
    }

    /// Tamanho em octal (ou base-256 quando o primeiro byte tem o bit alto).
    private static func octal(_ bytes: [UInt8], _ start: Int, _ length: Int) -> Int {
        let field = bytes[start..<(start + length)]
        if let first = field.first, first & 0x80 != 0 {
            var value = 0
            for (i, b) in field.enumerated() {
                value = (value << 8) | Int(i == 0 ? b & 0x7f : b)
            }
            return value
        }
        let text = String(decoding: field.filter { $0 != 0 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        return Int(text, radix: 8) ?? 0
    }

    /// Registros pax: "<tamanho> <chave>=<valor>\n".
    private static func parsePax(_ bytes: [UInt8]) -> [String: String] {
        var result: [String: String] = [:]
        let text = String(decoding: bytes, as: UTF8.self)
        for line in text.split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            let record = line[line.index(after: space)...]
            guard let eq = record.firstIndex(of: "=") else { continue }
            result[String(record[..<eq])] = String(record[record.index(after: eq)...])
        }
        return result
    }

    /// Remove "./" e "/" do início e recusa caminhos com "..".
    static func sanitize(_ raw: String) -> String? {
        let parts = raw.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        return parts.joined(separator: "/")
    }
}
