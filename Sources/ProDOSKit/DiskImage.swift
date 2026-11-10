import Foundation

// MARK: - Errors

public enum ProDOSError: Error, LocalizedError, Equatable {
    case notADiskImage(String)
    case notProDOS
    case pathNotFound(String)
    case fileNotFound(String)
    case duplicateName(String)
    case diskFull
    case directoryFull
    case invalidName(String)
    case directoryNotEmpty(String)
    case fileLocked(String)
    case unsupported(String)
    case damaged(String)

    public var errorDescription: String? {
        switch self {
        case .notADiskImage(let s): return "Not a supported disk image (\(s))"
        case .notProDOS: return "The image does not contain a ProDOS volume"
        case .pathNotFound(let s): return "Directory not found: \(s)"
        case .fileNotFound(let s): return "File not found: \(s)"
        case .duplicateName(let s): return "A file named \(s) already exists"
        case .diskFull: return "Disk full"
        case .directoryFull: return "Directory full (a volume directory holds 51 entries)"
        case .invalidName(let s): return "Invalid ProDOS name: \(s)"
        case .directoryNotEmpty(let s): return "Directory is not empty: \(s)"
        case .fileLocked(let s): return "File is locked: \(s)"
        case .unsupported(let s): return "Unsupported: \(s)"
        case .damaged(let s): return "Damaged volume: \(s)"
        }
    }
}

// MARK: - Little-endian helpers

@inline(__always) func le16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
@inline(__always) func le24(_ b: [UInt8], _ o: Int) -> Int { le16(b, o) | Int(b[o + 2]) << 16 }
@inline(__always) func le32(_ b: [UInt8], _ o: Int) -> Int { le24(b, o) | Int(b[o + 3]) << 24 }
@inline(__always) func put16(_ b: inout [UInt8], _ o: Int, _ v: Int) {
    b[o] = UInt8(v & 0xFF); b[o + 1] = UInt8((v >> 8) & 0xFF)
}
@inline(__always) func put24(_ b: inout [UInt8], _ o: Int, _ v: Int) {
    put16(&b, o, v & 0xFFFF); b[o + 2] = UInt8((v >> 16) & 0xFF)
}

// MARK: - Disk image (block device)

/// A disk image held in memory and accessed as 512-byte ProDOS blocks.
/// Supports ProDOS-order (.po, .hdv, .2mg) and DOS-order (.dsk, .do, .2mg) images.
public final class DiskImage {
    public let url: URL
    public let dosOrder: Bool
    public let blockCount: Int
    private var bytes: [UInt8]
    private let dataOffset: Int

    public static let fileExtensions: Set<String> = ["po", "hdv", "2mg", "2img", "dsk", "do"]

    /// ProDOS logical sector -> DOS 3.3 sector, inside one 16-sector track.
    static let prodosToDos = [0, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 15]

    public static func isDiskImage(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    public init(url: URL) throws {
        self.url = url
        let raw = [UInt8](try Data(contentsOf: url))
        let ext = url.pathExtension.lowercased()
        var off = 0
        var len = raw.count
        var dos = false
        switch ext {
        case "2mg", "2img":
            guard raw.count >= 64, Array(raw[0..<4]) == [0x32, 0x49, 0x4D, 0x47] else {
                throw ProDOSError.notADiskImage("missing 2IMG header")
            }
            let format = le32(raw, 0x0C)
            guard format != 2 else { throw ProDOSError.unsupported("nibble-format 2IMG images") }
            off = le32(raw, 0x18)
            len = le32(raw, 0x1C)
            if len == 0 { len = raw.count - off }
            dos = (format == 0)
        case "dsk", "do":
            if raw.count == 143_360 {
                let dosOK = DiskImage.looksLikeProDOS(raw, off: 0, dos: true)
                let proOK = DiskImage.looksLikeProDOS(raw, off: 0, dos: false)
                dos = dosOK || !proOK
            }
        case "po", "hdv":
            dos = false
        default:
            throw ProDOSError.notADiskImage(".\(ext)")
        }
        guard off >= 0, len >= 512 * 7, off + len <= raw.count else {
            throw ProDOSError.notADiskImage("size \(raw.count) bytes")
        }
        self.bytes = raw
        self.dataOffset = off
        self.dosOrder = dos
        self.blockCount = len / 512
    }

    public static func halfOffsets(_ block: Int, off: Int, dos: Bool) -> (Int, Int) {
        if !dos {
            let o = off + block * 512
            return (o, o + 256)
        }
        let track = block / 8
        let b = block % 8
        let base = off + track * 4096
        return (base + prodosToDos[2 * b] * 256, base + prodosToDos[2 * b + 1] * 256)
    }

    static func looksLikeProDOS(_ raw: [UInt8], off: Int, dos: Bool) -> Bool {
        let (a, b) = halfOffsets(2, off: off, dos: dos)
        guard a + 256 <= raw.count, b + 256 <= raw.count else { return false }
        let blk = Array(raw[a..<a + 256]) + Array(raw[b..<b + 256])
        return blk[4] >> 4 == 0xF && blk[4 + 0x1F] == 0x27 && blk[4 + 0x20] == 0x0D
    }

    public func readBlock(_ n: Int) -> [UInt8] {
        precondition(n >= 0 && n < blockCount, "block \(n) out of range")
        let (a, b) = DiskImage.halfOffsets(n, off: dataOffset, dos: dosOrder)
        return Array(bytes[a..<a + 256]) + Array(bytes[b..<b + 256])
    }

    public func writeBlock(_ n: Int, _ data: [UInt8]) {
        precondition(n >= 0 && n < blockCount, "block \(n) out of range")
        precondition(data.count == 512)
        let (a, b) = DiskImage.halfOffsets(n, off: dataOffset, dos: dosOrder)
        bytes.replaceSubrange(a..<a + 256, with: data[0..<256])
        bytes.replaceSubrange(b..<b + 256, with: data[256..<512])
    }

    /// Writes the whole image back to its file.
    public func save() throws {
        try Data(bytes).write(to: url, options: .atomic)
    }
}
