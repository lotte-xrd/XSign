import Foundation

// MARK: - Constantes do formato Mach-O

enum MachOConst {
    static let mhMagic: UInt32 = 0xfeedface
    static let mhMagic64: UInt32 = 0xfeedfacf
    static let fatMagic: UInt32 = 0xcafebabe
    static let fatMagic64: UInt32 = 0xcafebabf

    static let lcReqDyld: UInt32 = 0x8000_0000
    static let lcSegment: UInt32 = 0x1
    static let lcSegment64: UInt32 = 0x19
    static let lcLoadDylib: UInt32 = 0xc
    static let lcIdDylib: UInt32 = 0xd
    static let lcLoadWeakDylib: UInt32 = 0x18 | 0x8000_0000
    static let lcReexportDylib: UInt32 = 0x1f | 0x8000_0000
    static let lcLazyLoadDylib: UInt32 = 0x20
    static let lcLoadUpwardDylib: UInt32 = 0x23 | 0x8000_0000
    static let lcRpath: UInt32 = 0x1c | 0x8000_0000
    static let lcCodeSignature: UInt32 = 0x1d
    static let lcEncryptionInfo: UInt32 = 0x21
    static let lcEncryptionInfo64: UInt32 = 0x2c
    static let lcVersionMinIPhoneOS: UInt32 = 0x25
    static let lcBuildVersion: UInt32 = 0x32

    static let dylibLoadCommands: Set<UInt32> = [
        0xc,                    // LC_LOAD_DYLIB
        0x18 | 0x8000_0000,     // LC_LOAD_WEAK_DYLIB
        0x1f | 0x8000_0000,     // LC_REEXPORT_DYLIB
        0x20,                   // LC_LAZY_LOAD_DYLIB
        0x23 | 0x8000_0000      // LC_LOAD_UPWARD_DYLIB
    ]
}

enum MachOError: LocalizedError {
    case notMachO
    case truncated
    case noSpace(needed: Int, available: Int)

    var errorDescription: String? {
        switch self {
        case .notMachO:
            return L.tr("macho.error.notMachO")
        case .truncated:
            return L.tr("macho.error.truncated")
        case .noSpace(let needed, let available):
            return L.tr("macho.error.noSpace", needed, available)
        }
    }
}

// MARK: - Leitura/escrita de inteiros sem alinhamento

extension Data {
    func moU32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    func moU32BE(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    func moU64BE(_ offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= count else { return 0 }
        return withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
    }

    mutating func moSetU32(_ value: UInt32, at offset: Int) {
        guard offset >= 0, offset + 4 <= count else { return }
        withUnsafeMutableBytes { $0.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt32.self) }
    }

    /// Lê uma string C terminada em zero, sem passar de `limit`.
    func moCString(at offset: Int, limit: Int) -> String {
        let end = Swift.min(limit, count)
        guard offset >= 0, offset < end else { return "" }
        var bytes: [UInt8] = []
        var i = offset
        while i < end {
            let b = self[startIndex + i]
            if b == 0 { break }
            bytes.append(b)
            i += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - Uma arquitetura (fatia) do binário

final class MachOSlice {
    struct Command {
        let cmd: UInt32
        let offset: Int
        let size: Int
    }

    let fileOffset: UInt64
    let is64: Bool
    let cpuType: Int32
    let cpuSubtype: Int32
    /// Cabeçalho + load commands desta fatia (começa no byte 0 da fatia).
    fileprivate(set) var buffer: Data
    fileprivate let originalLength: Int
    /// Até onde os load commands podem crescer (offset da primeira seção).
    let commandsLimit: Int
    fileprivate(set) var dirty = false

    var headerSize: Int { is64 ? 32 : 28 }
    var ncmds: UInt32 { buffer.moU32(16) }
    var sizeofcmds: UInt32 { buffer.moU32(20) }
    var freeSpace: Int { commandsLimit - (headerSize + Int(sizeofcmds)) }
    private var alignment: Int { is64 ? 8 : 4 }

    private init(fileOffset: UInt64, is64: Bool, cpuType: Int32, cpuSubtype: Int32, buffer: Data, commandsLimit: Int) {
        self.fileOffset = fileOffset
        self.is64 = is64
        self.cpuType = cpuType
        self.cpuSubtype = cpuSubtype
        self.buffer = buffer
        self.originalLength = buffer.count
        self.commandsLimit = commandsLimit
    }

    static func load(handle: FileHandle, at offset: UInt64, fileSize: UInt64) throws -> MachOSlice? {
        try handle.seek(toOffset: offset)
        guard let head = try handle.read(upToCount: 32), head.count >= 28 else { return nil }
        let magic = head.moU32(0)
        let is64: Bool
        if magic == MachOConst.mhMagic64 {
            is64 = true
        } else if magic == MachOConst.mhMagic {
            is64 = false
        } else {
            return nil
        }
        let headerSize = is64 ? 32 : 28
        let total = headerSize + Int(head.moU32(20))
        guard offset + UInt64(total) <= fileSize else { throw MachOError.truncated }

        try handle.seek(toOffset: offset)
        guard let buffer = try handle.read(upToCount: total), buffer.count == total else {
            throw MachOError.truncated
        }

        let slice = MachOSlice(
            fileOffset: offset,
            is64: is64,
            cpuType: Int32(bitPattern: head.moU32(4)),
            cpuSubtype: Int32(bitPattern: head.moU32(8)),
            buffer: buffer,
            commandsLimit: Self.firstSectionOffset(in: buffer, is64: is64) ?? total
        )
        return slice
    }

    /// Menor offset de seção com dados no arquivo: os load commands não podem passar dele.
    private static func firstSectionOffset(in buffer: Data, is64: Bool) -> Int? {
        let headerSize = is64 ? 32 : 28
        let ncmds = Int(buffer.moU32(16))
        var p = headerSize
        var best = Int.max
        for _ in 0..<ncmds {
            guard p + 8 <= buffer.count else { break }
            let cmd = buffer.moU32(p)
            let size = Int(buffer.moU32(p + 4))
            guard size >= 8, p + size <= buffer.count else { break }
            if cmd == MachOConst.lcSegment64 {
                let nsects = Int(buffer.moU32(p + 64))
                for s in 0..<nsects {
                    let so = p + 72 + s * 80
                    guard so + 80 <= p + size else { break }
                    let off = Int(buffer.moU32(so + 48))
                    let type = buffer.moU32(so + 64) & 0xff
                    if off > 0 && type != 0x1 && type != 0xc && type != 0x12 { best = Swift.min(best, off) }
                }
            } else if cmd == MachOConst.lcSegment {
                let nsects = Int(buffer.moU32(p + 48))
                for s in 0..<nsects {
                    let so = p + 56 + s * 68
                    guard so + 68 <= p + size else { break }
                    let off = Int(buffer.moU32(so + 40))
                    let type = buffer.moU32(so + 56) & 0xff
                    if off > 0 && type != 0x1 && type != 0xc && type != 0x12 { best = Swift.min(best, off) }
                }
            }
            p += size
        }
        guard best != Int.max else { return nil }
        return Swift.max(best, headerSize + Int(buffer.moU32(20)))
    }

    var commands: [Command] {
        var result: [Command] = []
        var p = headerSize
        for _ in 0..<Int(ncmds) {
            guard p + 8 <= buffer.count else { break }
            let cmd = buffer.moU32(p)
            let size = Int(buffer.moU32(p + 4))
            guard size >= 8, p + size <= buffer.count else { break }
            result.append(Command(cmd: cmd, offset: p, size: size))
            p += size
        }
        return result
    }

    /// Lê a string de um load command (o campo `stringField` guarda o offset dela).
    func string(in command: Command, stringField: Int) -> String {
        let rel = Int(buffer.moU32(command.offset + stringField))
        guard rel > 0, rel < command.size else { return "" }
        return buffer.moCString(at: command.offset + rel, limit: command.offset + command.size)
    }

    var architecture: String {
        let sub = cpuSubtype & 0xff
        switch cpuType {
        case 0x0100_000c: return sub == 2 ? "arm64e" : "arm64"
        case 12: return sub == 11 ? "armv7s" : (sub == 9 ? "armv7" : "arm")
        case 0x0100_0007: return "x86_64"
        case 7: return "i386"
        default: return "cpu\(cpuType)"
        }
    }

    // MARK: Edição

    fileprivate func append(_ command: Data) throws {
        guard command.count <= freeSpace else {
            throw MachOError.noSpace(needed: command.count, available: freeSpace)
        }
        let oldCount = ncmds
        let oldSize = sizeofcmds
        let end = headerSize + Int(oldSize)
        if buffer.count > end {
            buffer.removeSubrange(end..<buffer.count)
        }
        buffer.append(command)
        buffer.moSetU32(oldCount + 1, at: 16)
        buffer.moSetU32(oldSize + UInt32(command.count), at: 20)
        dirty = true
    }

    fileprivate func replace(_ command: Command, with newCommand: Data) throws {
        let delta = newCommand.count - command.size
        if delta > 0 && delta > freeSpace {
            throw MachOError.noSpace(needed: delta, available: freeSpace)
        }
        let oldSize = Int(sizeofcmds)
        buffer.replaceSubrange(command.offset..<(command.offset + command.size), with: newCommand)
        buffer.moSetU32(UInt32(oldSize + delta), at: 20)
        dirty = true
    }

    fileprivate func overwriteString(in command: Command, stringField: Int, with value: String) -> Bool {
        let rel = Int(buffer.moU32(command.offset + stringField))
        let bytes = Array(value.utf8)
        let room = command.size - rel
        guard rel > 0, bytes.count + 1 <= room else { return false }
        let start = command.offset + rel
        var zeroed = [UInt8](repeating: 0, count: room)
        zeroed.replaceSubrange(0..<bytes.count, with: bytes)
        buffer.replaceSubrange(start..<(start + room), with: zeroed)
        dirty = true
        return true
    }

    func makeDylibCommand(cmd: UInt32, path: String, template: Command? = nil) -> Data {
        let nameOffset = 24
        let pathBytes = Array(path.utf8)
        var size = nameOffset + pathBytes.count + 1
        size = (size + alignment - 1) / alignment * alignment
        var data = Data(count: size)
        data.moSetU32(cmd, at: 0)
        data.moSetU32(UInt32(size), at: 4)
        data.moSetU32(UInt32(nameOffset), at: 8)
        if let template {
            // preserva timestamp e versões do comando antigo
            data.moSetU32(buffer.moU32(template.offset + 12), at: 12)
            data.moSetU32(buffer.moU32(template.offset + 16), at: 16)
            data.moSetU32(buffer.moU32(template.offset + 20), at: 20)
        } else {
            data.moSetU32(2, at: 12)
            data.moSetU32(0x0001_0000, at: 16)
            data.moSetU32(0x0001_0000, at: 20)
        }
        data.replaceSubrange(nameOffset..<(nameOffset + pathBytes.count), with: pathBytes)
        return data
    }

    func makeRpathCommand(path: String) -> Data {
        let pathOffset = 12
        let pathBytes = Array(path.utf8)
        var size = pathOffset + pathBytes.count + 1
        size = (size + alignment - 1) / alignment * alignment
        var data = Data(count: size)
        data.moSetU32(MachOConst.lcRpath, at: 0)
        data.moSetU32(UInt32(size), at: 4)
        data.moSetU32(UInt32(pathOffset), at: 8)
        data.replaceSubrange(pathOffset..<(pathOffset + pathBytes.count), with: pathBytes)
        return data
    }

    fileprivate func writeBack(to handle: FileHandle) throws {
        guard dirty else { return }
        var data = buffer
        if data.count < originalLength {
            data.append(Data(count: originalLength - data.count))
        }
        try handle.seek(toOffset: fileOffset)
        try handle.write(contentsOf: data)
    }
}

// MARK: - Arquivo Mach-O (fino ou "fat")

final class MachOFile {
    let url: URL
    let isFat: Bool
    private(set) var slices: [MachOSlice]

    init(url: URL) throws {
        self.url = url
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard let head = try handle.read(upToCount: 8), head.count == 8 else { throw MachOError.notMachO }

        let beMagic = head.moU32BE(0)
        var found: [MachOSlice] = []
        if beMagic == MachOConst.fatMagic || beMagic == MachOConst.fatMagic64 {
            let fat64 = beMagic == MachOConst.fatMagic64
            let count = Int(head.moU32BE(4))
            guard count > 0, count < 32 else { throw MachOError.notMachO }
            let entrySize = fat64 ? 32 : 20
            try handle.seek(toOffset: 8)
            guard let table = try handle.read(upToCount: count * entrySize), table.count == count * entrySize else {
                throw MachOError.truncated
            }
            for i in 0..<count {
                let base = i * entrySize
                let offset = fat64 ? table.moU64BE(base + 8) : UInt64(table.moU32BE(base + 8))
                if let slice = try MachOSlice.load(handle: handle, at: offset, fileSize: fileSize) {
                    found.append(slice)
                }
            }
            isFat = true
        } else {
            if let slice = try MachOSlice.load(handle: handle, at: 0, fileSize: fileSize) {
                found.append(slice)
            }
            isFat = false
        }
        guard !found.isEmpty else { throw MachOError.notMachO }
        slices = found
    }

    /// Verifica rapidamente os 4 primeiros bytes.
    static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        let le = head.moU32(0)
        let be = head.moU32BE(0)
        return le == MachOConst.mhMagic64 || le == MachOConst.mhMagic
            || be == MachOConst.fatMagic || be == MachOConst.fatMagic64
    }

    func save() throws {
        guard slices.contains(where: { $0.dirty }) else { return }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        for slice in slices {
            try slice.writeBack(to: handle)
        }
    }

    // MARK: Consultas (primeira arquitetura)

    var architectures: [String] { slices.map { $0.architecture } }

    var loadedDylibs: [String] {
        guard let s = slices.first else { return [] }
        return s.commands
            .filter { MachOConst.dylibLoadCommands.contains($0.cmd) }
            .map { s.string(in: $0, stringField: 8) }
    }

    var installName: String? {
        guard let s = slices.first,
              let c = s.commands.first(where: { $0.cmd == MachOConst.lcIdDylib }) else { return nil }
        return s.string(in: c, stringField: 8)
    }

    var rpaths: [String] {
        guard let s = slices.first else { return [] }
        return s.commands.filter { $0.cmd == MachOConst.lcRpath }.map { s.string(in: $0, stringField: 8) }
    }

    var isEncrypted: Bool {
        for s in slices {
            for c in s.commands where c.cmd == MachOConst.lcEncryptionInfo || c.cmd == MachOConst.lcEncryptionInfo64 {
                if s.buffer.moU32(c.offset + 16) != 0 { return true }
            }
        }
        return false
    }

    var minimumOS: String? {
        guard let s = slices.first else { return nil }
        for c in s.commands {
            if c.cmd == MachOConst.lcBuildVersion {
                return Self.version(s.buffer.moU32(c.offset + 12))
            }
            if c.cmd == MachOConst.lcVersionMinIPhoneOS {
                return Self.version(s.buffer.moU32(c.offset + 8))
            }
        }
        return nil
    }

    private static func version(_ v: UInt32) -> String {
        let major = v >> 16
        let minor = (v >> 8) & 0xff
        let patch = v & 0xff
        return patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }

    /// Entitlements embutidos na assinatura de código (slot 5, XML).
    func entitlements() -> [String: Any]? {
        guard let s = slices.first,
              let cs = s.commands.first(where: { $0.cmd == MachOConst.lcCodeSignature }) else { return nil }
        let dataOffset = UInt64(s.buffer.moU32(cs.offset + 8))
        let dataSize = Int(s.buffer.moU32(cs.offset + 12))
        guard dataSize > 12, dataSize < 32 * 1024 * 1024,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: s.fileOffset + dataOffset)) != nil,
              let blob = try? handle.read(upToCount: dataSize), blob.count == dataSize,
              blob.moU32BE(0) == 0xfade0cc0 else { return nil }

        let count = Int(blob.moU32BE(8))
        for i in 0..<Swift.min(count, 64) {
            let type = blob.moU32BE(12 + i * 8)
            let offset = Int(blob.moU32BE(16 + i * 8))
            guard type == 5, offset + 8 <= blob.count, blob.moU32BE(offset) == 0xfade7171 else { continue }
            let length = Int(blob.moU32BE(offset + 4))
            guard length > 8, offset + length <= blob.count else { continue }
            let xml = blob.subdata(in: (offset + 8)..<(offset + length))
            return (try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil)) as? [String: Any]
        }
        return nil
    }

    // MARK: Edição (todas as arquiteturas)

    /// Adiciona um LC_LOAD_DYLIB (ou weak). Retorna `false` se já existia.
    @discardableResult
    func addDylib(_ path: String, weak: Bool = false) throws -> Bool {
        if loadedDylibs.contains(path) { return false }
        for s in slices {
            let cmd = s.makeDylibCommand(cmd: weak ? MachOConst.lcLoadWeakDylib : MachOConst.lcLoadDylib, path: path)
            try s.append(cmd)
        }
        return true
    }

    @discardableResult
    func addRpath(_ path: String) throws -> Bool {
        if rpaths.contains(path) { return false }
        for s in slices {
            try s.append(s.makeRpathCommand(path: path))
        }
        return true
    }

    /// Troca o caminho de uma dependência. Mantém a ordem dos load commands.
    @discardableResult
    func changeDylibPath(from old: String, to new: String) throws -> Bool {
        guard old != new else { return false }
        var changed = false
        for s in slices {
            for c in s.commands where MachOConst.dylibLoadCommands.contains(c.cmd) {
                guard s.string(in: c, stringField: 8) == old else { continue }
                if !s.overwriteString(in: c, stringField: 8, with: new) {
                    try s.replace(c, with: s.makeDylibCommand(cmd: c.cmd, path: new, template: c))
                }
                changed = true
                break
            }
        }
        return changed
    }

    /// Troca o install name (LC_ID_DYLIB) de uma dylib.
    func setInstallName(_ name: String) throws {
        for s in slices {
            guard let c = s.commands.first(where: { $0.cmd == MachOConst.lcIdDylib }) else { continue }
            if s.string(in: c, stringField: 8) == name { continue }
            if !s.overwriteString(in: c, stringField: 8, with: name) {
                try s.replace(c, with: s.makeDylibCommand(cmd: c.cmd, path: name, template: c))
            }
        }
    }
}
