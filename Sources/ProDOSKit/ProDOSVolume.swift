import Foundation

// MARK: - Dates

public enum ProDOSDate {
    /// Encodes a date as the ProDOS (date, time) words.
    public static func encode(_ d: Date) -> (date: Int, time: Int) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute], from: d)
        let y = (c.year ?? 2000) % 100
        return (y << 9 | (c.month ?? 1) << 5 | (c.day ?? 1), (c.hour ?? 0) << 8 | (c.minute ?? 0))
    }

    /// Decodes ProDOS date/time words (ProDOS 2.4 rule: years 0-39 are 2000-2039).
    public static func decode(date: Int, time: Int) -> Date? {
        guard date != 0 else { return nil }
        let y = (date >> 9) & 0x7F
        var c = DateComponents()
        c.year = y < 40 ? 2000 + y : 1900 + y
        c.month = (date >> 5) & 0x0F
        c.day = date & 0x1F
        c.hour = (time >> 8) & 0x1F
        c.minute = time & 0x3F
        guard let m = c.month, (1...12).contains(m), let dd = c.day, (1...31).contains(dd) else { return nil }
        return Calendar(identifier: .gregorian).date(from: c)
    }
}

// MARK: - Directory entry

public struct ProDOSEntry: Hashable {
    public var name: String
    public var storageType: Int
    public var fileType: Int
    public var keyPointer: Int
    public var blocksUsed: Int
    public var eof: Int
    public var access: Int
    public var auxType: Int
    public var created: Date?
    public var modified: Date?
    /// Raw ProDOS date/time words, kept for exact copies between images.
    public var createdRaw: (Int, Int)
    public var modifiedRaw: (Int, Int)
    /// Block and byte offset of this entry inside its directory.
    public let block: Int
    public let offset: Int

    public var isDirectory: Bool { storageType == 0xD }
    public var isLocked: Bool { access & 0x80 == 0 }

    public static func == (a: ProDOSEntry, b: ProDOSEntry) -> Bool { a.block == b.block && a.offset == b.offset }
    public func hash(into h: inout Hasher) { h.combine(block); h.combine(offset) }
}

// MARK: - Volume

/// A ProDOS file system inside a `DiskImage`.
/// Paths are arrays of directory names below the volume root, e.g. ["GAMES", "ARCADE"].
public final class ProDOSVolume {
    public let image: DiskImage
    public private(set) var volumeName: String
    public let totalBlocks: Int
    let bitmapPointer: Int
    private var allocHint = 0

    public init(image: DiskImage) throws {
        self.image = image
        let b = image.readBlock(2)
        guard b[4] >> 4 == 0xF, b[4 + 0x1F] == 0x27, b[4 + 0x20] == 0x0D else { throw ProDOSError.notProDOS }
        let len = Int(b[4] & 0x0F)
        volumeName = String(decoding: b[5..<5 + len], as: UTF8.self)
        bitmapPointer = le16(b, 4 + 0x23)
        totalBlocks = min(le16(b, 4 + 0x25) == 0 ? 65535 : le16(b, 4 + 0x25), image.blockCount)
        guard bitmapPointer > 2, bitmapPointer < totalBlocks else { throw ProDOSError.damaged("bad bitmap pointer") }
    }

    public convenience init(url: URL) throws {
        try self.init(image: DiskImage(url: url))
    }

    public func save() throws { try image.save() }

    // MARK: Names

    static let upper: ClosedRange<Unicode.Scalar> = "A"..."Z"
    static let digit: ClosedRange<Unicode.Scalar> = "0"..."9"

    /// Returns the upper-case name if valid for ProDOS, else throws.
    public static func validName(_ s: String) throws -> String {
        let n = s.uppercased()
        guard (1...15).contains(n.count),
              let f = n.unicodeScalars.first, upper.contains(f),
              n.unicodeScalars.allSatisfy({ upper.contains($0) || digit.contains($0) || $0 == "." })
        else { throw ProDOSError.invalidName(s) }
        return n
    }

    /// Turns any file name into a legal ProDOS name ("read me.txt" -> "READ.ME.TXT").
    public static func sanitizedName(_ s: String) -> String {
        var out = ""
        for u in s.uppercased().unicodeScalars {
            if upper.contains(u) || digit.contains(u) || u == "." { out.unicodeScalars.append(u) }
            else if !out.hasSuffix(".") { out += "." }
        }
        while out.hasPrefix(".") { out.removeFirst() }
        if out.isEmpty { out = "FILE" }
        if let f = out.unicodeScalars.first, !upper.contains(f) { out = "X" + out }
        if out.count > 15 { out = String(out.prefix(15)) }
        while out.hasSuffix(".") && out.count > 1 { out.removeLast() }
        return out
    }

    // MARK: Bitmap

    private func bitLocation(_ n: Int) -> (block: Int, byte: Int, mask: UInt8) {
        (bitmapPointer + n / 4096, (n % 4096) / 8, UInt8(0x80 >> (n % 8)))
    }

    func isFree(_ n: Int) -> Bool {
        let l = bitLocation(n)
        return image.readBlock(l.block)[l.byte] & l.mask != 0
    }

    func setFree(_ n: Int, _ free: Bool) {
        let l = bitLocation(n)
        var b = image.readBlock(l.block)
        if free { b[l.byte] |= l.mask } else { b[l.byte] &= ~l.mask }
        image.writeBlock(l.block, b)
    }

    public func freeBlockCount() -> Int {
        var count = 0
        var n = 0
        let bitmapBlocks = (totalBlocks + 4095) / 4096
        for i in 0..<bitmapBlocks {
            let b = image.readBlock(bitmapPointer + i)
            for byte in b {
                for bit in 0..<8 where n < totalBlocks {
                    if byte & UInt8(0x80 >> bit) != 0 { count += 1 }
                    n += 1
                }
                if n >= totalBlocks { break }
            }
        }
        return count
    }

    /// Allocates a free block, marks it used and fills it with zeros.
    func allocBlock() throws -> Int {
        let bitmapBlocks = (totalBlocks + 4095) / 4096
        for pass in 0..<2 {
            let start = pass == 0 ? allocHint : 0
            var bi = start / 4096
            while bi < bitmapBlocks {
                var b = image.readBlock(bitmapPointer + bi)
                let firstByte = bi == start / 4096 ? (start % 4096) / 8 : 0
                for byte in firstByte..<512 where b[byte] != 0 {
                    for bit in 0..<8 {
                        let n = bi * 4096 + byte * 8 + bit
                        if n >= totalBlocks { break }
                        let mask = UInt8(0x80 >> bit)
                        if b[byte] & mask != 0 {
                            b[byte] &= ~mask
                            image.writeBlock(bitmapPointer + bi, b)
                            image.writeBlock(n, [UInt8](repeating: 0, count: 512))
                            allocHint = n + 1
                            return n
                        }
                    }
                }
                bi += 1
            }
        }
        throw ProDOSError.diskFull
    }

    // MARK: Directories

    /// Key block of the directory at `path`.
    public func directoryKeyBlock(_ path: [String]) throws -> Int {
        var key = 2
        for comp in path {
            guard let e = try entries(inDirectoryAt: key).first(where: { $0.isDirectory && $0.name.uppercased() == comp.uppercased() })
            else { throw ProDOSError.pathNotFound("/" + ([volumeName] + path).joined(separator: "/")) }
            key = e.keyPointer
        }
        return key
    }

    public func entries(_ path: [String]) throws -> [ProDOSEntry] {
        try entries(inDirectoryAt: directoryKeyBlock(path))
    }

    func entries(inDirectoryAt key: Int) throws -> [ProDOSEntry] {
        let kb = image.readBlock(key)
        let entryLen = Int(kb[4 + 0x1F])
        let perBlock = Int(kb[4 + 0x20])
        guard entryLen >= 0x27, perBlock >= 1, 4 + perBlock * entryLen <= 512 else {
            throw ProDOSError.damaged("bad directory header in block \(key)")
        }
        var result: [ProDOSEntry] = []
        var blk = key
        var visited = Set<Int>()
        while blk != 0 {
            guard blk < totalBlocks, visited.insert(blk).inserted else { throw ProDOSError.damaged("directory chain loop") }
            let b = image.readBlock(blk)
            for i in 0..<perBlock {
                let o = 4 + i * entryLen
                let st = Int(b[o]) >> 4
                if st == 0 || st >= 0xE { continue }
                result.append(parseEntry(b, blk, o))
            }
            blk = le16(b, 2)
        }
        return result
    }

    func parseEntry(_ b: [UInt8], _ blk: Int, _ o: Int) -> ProDOSEntry {
        let len = Int(b[o] & 0x0F)
        var chars = Array(b[o + 1..<o + 1 + len])
        // GS/OS lower-case flags (version / min_version fields)
        let flags = Int(b[o + 0x1C]) | Int(b[o + 0x1D]) << 8
        if flags & 0x8000 != 0 {
            for i in 0..<len where flags & (0x4000 >> i) != 0 && chars[i] >= 0x41 && chars[i] <= 0x5A {
                chars[i] += 0x20
            }
        }
        let cd = le16(b, o + 0x18), ct = le16(b, o + 0x1A)
        let md = le16(b, o + 0x21), mt = le16(b, o + 0x23)
        return ProDOSEntry(
            name: String(decoding: chars, as: UTF8.self),
            storageType: Int(b[o]) >> 4,
            fileType: Int(b[o + 0x10]),
            keyPointer: le16(b, o + 0x11),
            blocksUsed: le16(b, o + 0x13),
            eof: le24(b, o + 0x15),
            access: Int(b[o + 0x1E]),
            auxType: le16(b, o + 0x1F),
            created: ProDOSDate.decode(date: cd, time: ct),
            modified: ProDOSDate.decode(date: md, time: mt),
            createdRaw: (cd, ct),
            modifiedRaw: (md, mt),
            block: blk, offset: o)
    }

    func find(_ path: [String], _ name: String) throws -> (key: Int, entry: ProDOSEntry?) {
        let key = try directoryKeyBlock(path)
        let e = try entries(inDirectoryAt: key).first { $0.name.uppercased() == name.uppercased() }
        return (key, e)
    }

    public func entry(_ path: [String], _ name: String) throws -> ProDOSEntry? {
        try find(path, name).entry
    }

    private func adjustFileCount(_ key: Int, by delta: Int) {
        var kb = image.readBlock(key)
        put16(&kb, 4 + 0x21, max(0, le16(kb, 4 + 0x21) + delta))
        image.writeBlock(key, kb)
    }

    /// Puts a 39-byte entry into the first free slot of the directory, growing a
    /// subdirectory by one block when it is full. Returns the entry's location.
    @discardableResult
    func insertEntry(_ dirKey: Int, _ entry: [UInt8]) throws -> (block: Int, offset: Int) {
        var e = entry
        put16(&e, 0x25, dirKey)                          // header_pointer
        let kb = image.readBlock(dirKey)
        let entryLen = Int(kb[4 + 0x1F])
        let perBlock = Int(kb[4 + 0x20])
        var blk = dirKey
        var last = dirKey
        var visited = Set<Int>()
        while blk != 0 {
            guard visited.insert(blk).inserted else { throw ProDOSError.damaged("directory chain loop") }
            var b = image.readBlock(blk)
            for i in 0..<perBlock {
                if blk == dirKey && i == 0 { continue }
                let o = 4 + i * entryLen
                if b[o] >> 4 == 0 {
                    b.replaceSubrange(o..<o + 0x27, with: e)
                    image.writeBlock(blk, b)
                    adjustFileCount(dirKey, by: 1)
                    return (blk, o)
                }
            }
            last = blk
            blk = le16(b, 2)
        }
        guard dirKey != 2 else { throw ProDOSError.directoryFull }
        // grow the subdirectory
        let nb = try allocBlock()
        var lb = image.readBlock(last)
        put16(&lb, 2, nb)
        image.writeBlock(last, lb)
        var newBlock = [UInt8](repeating: 0, count: 512)
        put16(&newBlock, 0, last)
        newBlock.replaceSubrange(4..<4 + 0x27, with: e)
        image.writeBlock(nb, newBlock)
        adjustFileCount(dirKey, by: 1)
        // the subdirectory's own entry in its parent: one more block, 512 more bytes
        let hdr = image.readBlock(dirKey)
        let pp = le16(hdr, 4 + 0x23)
        let pe = Int(hdr[4 + 0x25])
        let pel = Int(hdr[4 + 0x26])
        if pp != 0, pe >= 1, pel >= 0x27 {
            var pb = image.readBlock(pp)
            let po = 4 + (pe - 1) * pel
            put16(&pb, po + 0x13, le16(pb, po + 0x13) + 1)
            put24(&pb, po + 0x15, le24(pb, po + 0x15) + 512)
            image.writeBlock(pp, pb)
        }
        return (nb, 4)
    }

    static func makeEntry(storage: Int, name: String, fileType: Int, key: Int, blocksUsed: Int, eof: Int,
                          access: Int, auxType: Int, created: (Int, Int), modified: (Int, Int)) -> [UInt8] {
        var e = [UInt8](repeating: 0, count: 0x27)
        let n = Array(name.utf8)
        e[0] = UInt8(storage << 4 | n.count)
        e.replaceSubrange(1..<1 + n.count, with: n)
        e[0x10] = UInt8(fileType)
        put16(&e, 0x11, key)
        put16(&e, 0x13, blocksUsed)
        put24(&e, 0x15, eof)
        put16(&e, 0x18, created.0)
        put16(&e, 0x1A, created.1)
        e[0x1E] = UInt8(access)
        put16(&e, 0x1F, auxType)
        put16(&e, 0x21, modified.0)
        put16(&e, 0x23, modified.1)
        return e
    }

    // MARK: Reading files

    /// Returns the data fork of a file (sparse blocks read as zeros).
    public func readFile(_ e: ProDOSEntry) throws -> Data {
        switch e.storageType {
        case 1, 2, 3:
            return Data(try readFork(storage: e.storageType, key: e.keyPointer, eof: e.eof))
        case 5:
            let kb = image.readBlock(e.keyPointer)
            return Data(try readFork(storage: Int(kb[0]), key: le16(kb, 1), eof: le24(kb, 5)))
        default:
            throw ProDOSError.unsupported("storage type \(e.storageType) for \(e.name)")
        }
    }

    func readFork(storage: Int, key: Int, eof: Int) throws -> [UInt8] {
        let needed = (eof + 511) / 512
        var out: [UInt8] = []
        out.reserveCapacity(needed * 512)
        func dataBlock(_ p: Int) throws -> [UInt8] {
            if p == 0 { return [UInt8](repeating: 0, count: 512) }
            guard p < totalBlocks else { throw ProDOSError.damaged("block pointer \(p)") }
            return image.readBlock(p)
        }
        switch storage {
        case 1:
            out = try dataBlock(key)
        case 2:
            let ib = image.readBlock(key)
            for i in 0..<min(256, max(needed, 1)) {
                out += try dataBlock(Int(ib[i]) | Int(ib[256 + i]) << 8)
            }
        case 3:
            let mb = image.readBlock(key)
            var remaining = needed
            for m in 0..<128 where remaining > 0 {
                let ip = Int(mb[m]) | Int(mb[256 + m]) << 8
                let ib = ip == 0 ? [UInt8](repeating: 0, count: 512) : image.readBlock(ip)
                for i in 0..<min(256, remaining) {
                    out += try dataBlock(Int(ib[i]) | Int(ib[256 + i]) << 8)
                }
                remaining -= min(256, remaining)
            }
        default:
            throw ProDOSError.unsupported("storage type \(storage)")
        }
        if out.count > eof { out.removeLast(out.count - eof) }
        if out.count < eof { out += [UInt8](repeating: 0, count: eof - out.count) }
        return out
    }

    // MARK: Writing files

    /// Creates a file. With `overwrite`, an existing file of that name is deleted first.
    public func writeFile(_ path: [String], name: String, data: Data, fileType: Int, auxType: Int,
                          access: Int = 0xE3, created: (Int, Int)? = nil, modified: (Int, Int)? = nil,
                          overwrite: Bool = false) throws {
        let name = try ProDOSVolume.validName(name)
        let found = try find(path, name)
        if let old = found.entry {
            guard overwrite, !old.isDirectory else { throw ProDOSError.duplicateName(name) }
            try delete(path, name: name, force: true)
        }
        guard data.count <= 0xFF_FFFF else { throw ProDOSError.unsupported("files over 16 MB") }
        let bytes = [UInt8](data)
        let nData = max(1, (bytes.count + 511) / 512)
        let storage = bytes.count <= 512 ? 1 : (nData <= 256 ? 2 : 3)
        let indexBlocks = storage == 1 ? 0 : (storage == 2 ? 1 : (nData + 255) / 256 + 1)
        let total = nData + indexBlocks
        guard freeBlockCount() >= total + 1 else { throw ProDOSError.diskFull }

        var dataPtrs: [Int] = []
        for i in 0..<nData {
            let p = try allocBlock()
            var blk = [UInt8](repeating: 0, count: 512)
            let s = i * 512
            if s < bytes.count {
                let e = min(s + 512, bytes.count)
                blk.replaceSubrange(0..<(e - s), with: bytes[s..<e])
            }
            image.writeBlock(p, blk)
            dataPtrs.append(p)
        }
        func indexBlock(_ ptrs: ArraySlice<Int>) throws -> Int {
            let ib = try allocBlock()
            var b = [UInt8](repeating: 0, count: 512)
            for (i, p) in ptrs.enumerated() { b[i] = UInt8(p & 0xFF); b[256 + i] = UInt8(p >> 8) }
            image.writeBlock(ib, b)
            return ib
        }
        let key: Int
        switch storage {
        case 1: key = dataPtrs[0]
        case 2: key = try indexBlock(dataPtrs[0...])
        default:
            var indexes: [Int] = []
            var i = 0
            while i < dataPtrs.count {
                indexes.append(try indexBlock(dataPtrs[i..<min(i + 256, dataPtrs.count)]))
                i += 256
            }
            key = try indexBlock(indexes[0...])
        }
        let enc = ProDOSDate.encode(Date())
        let now: (Int, Int) = (enc.date, enc.time)
        let entry = ProDOSVolume.makeEntry(storage: storage, name: name, fileType: fileType, key: key,
                                           blocksUsed: total, eof: bytes.count, access: access, auxType: auxType,
                                           created: created ?? now, modified: modified ?? now)
        do {
            try insertEntry(found.key, entry)
        } catch {
            for p in dataPtrs { setFree(p, true) }
            if storage != 1 { freeIndexTree(storage: storage, key: key, freeData: false) }
            throw error
        }
    }

    // MARK: Directories

    public func createDirectory(_ path: [String], name: String) throws {
        let name = try ProDOSVolume.validName(name)
        let found = try find(path, name)
        guard found.entry == nil else { throw ProDOSError.duplicateName(name) }
        guard freeBlockCount() >= 2 else { throw ProDOSError.diskFull }
        let key = try allocBlock()
        let now = ProDOSDate.encode(Date())
        var kb = [UInt8](repeating: 0, count: 512)
        let n = Array(name.utf8)
        kb[4] = UInt8(0xE0 | n.count)
        kb.replaceSubrange(5..<5 + n.count, with: n)
        kb[4 + 0x10] = 0x75                               // required by ProDOS
        put16(&kb, 4 + 0x18, now.date)
        put16(&kb, 4 + 0x1A, now.time)
        kb[4 + 0x1E] = 0xE3
        kb[4 + 0x1F] = 0x27
        kb[4 + 0x20] = 0x0D
        image.writeBlock(key, kb)
        let entry = ProDOSVolume.makeEntry(storage: 0xD, name: name, fileType: 0x0F, key: key, blocksUsed: 1,
                                           eof: 512, access: 0xE3, auxType: 0,
                                           created: (now.date, now.time), modified: (now.date, now.time))
        let loc: (block: Int, offset: Int)
        do { loc = try insertEntry(found.key, entry) } catch { setFree(key, true); throw error }
        kb = image.readBlock(key)
        put16(&kb, 4 + 0x23, loc.block)
        kb[4 + 0x25] = UInt8((loc.offset - 4) / 0x27 + 1)
        kb[4 + 0x26] = 0x27
        image.writeBlock(key, kb)
    }

    // MARK: Delete / rename

    /// Deletes a file or an empty directory. `force` also deletes locked files.
    public func delete(_ path: [String], name: String, force: Bool = false) throws {
        let found = try find(path, name)
        guard let e = found.entry else { throw ProDOSError.fileNotFound(name) }
        if e.isLocked && !force { throw ProDOSError.fileLocked(e.name) }
        if e.isDirectory {
            guard try entries(inDirectoryAt: e.keyPointer).isEmpty else { throw ProDOSError.directoryNotEmpty(e.name) }
            var blk = e.keyPointer
            var visited = Set<Int>()
            while blk != 0 && blk < totalBlocks && visited.insert(blk).inserted {
                let next = le16(image.readBlock(blk), 2)
                setFree(blk, true)
                blk = next
            }
        } else {
            switch e.storageType {
            case 1, 2, 3:
                freeIndexTree(storage: e.storageType, key: e.keyPointer, freeData: true)
            case 5:
                let kb = image.readBlock(e.keyPointer)
                freeIndexTree(storage: Int(kb[0]), key: le16(kb, 1), freeData: true)
                freeIndexTree(storage: Int(kb[0x100]), key: le16(kb, 0x101), freeData: true)
                setFree(e.keyPointer, true)
            default:
                throw ProDOSError.unsupported("storage type \(e.storageType)")
            }
        }
        // ProDOS (DESTROY) clears the whole storage_type/name_length byte;
        // a deleted entry that keeps its name length confuses the ProDOS boot code.
        var b = image.readBlock(e.block)
        b[e.offset] = 0
        image.writeBlock(e.block, b)
        adjustFileCount(found.key, by: -1)
    }

    /// Frees a seedling/sapling/tree. With `freeData == false` only index blocks are freed.
    func freeIndexTree(storage: Int, key: Int, freeData: Bool) {
        func ok(_ p: Int) -> Bool { p != 0 && p < totalBlocks }
        switch storage {
        case 1:
            if freeData && ok(key) { setFree(key, true) }
        case 2:
            guard ok(key) else { return }
            let ib = image.readBlock(key)
            if freeData { for i in 0..<256 { let p = Int(ib[i]) | Int(ib[256 + i]) << 8; if ok(p) { setFree(p, true) } } }
            setFree(key, true)
        case 3:
            guard ok(key) else { return }
            let mb = image.readBlock(key)
            for m in 0..<128 {
                let ip = Int(mb[m]) | Int(mb[256 + m]) << 8
                if ok(ip) { freeIndexTree(storage: 2, key: ip, freeData: freeData) }
            }
            setFree(key, true)
        default:
            break
        }
    }

    public func rename(_ path: [String], from: String, to: String) throws {
        let newName = try ProDOSVolume.validName(to)
        let found = try find(path, from)
        guard let e = found.entry else { throw ProDOSError.fileNotFound(from) }
        if newName != e.name.uppercased(), try entry(path, newName) != nil { throw ProDOSError.duplicateName(newName) }
        let n = Array(newName.utf8)
        var b = image.readBlock(e.block)
        b[e.offset] = UInt8(e.storageType << 4 | n.count)
        for i in 0..<15 { b[e.offset + 1 + i] = i < n.count ? n[i] : 0 }
        b[e.offset + 0x1C] = 0                              // clear GS/OS lower-case flags
        b[e.offset + 0x1D] = 0
        image.writeBlock(e.block, b)
        if e.isDirectory {
            var kb = image.readBlock(e.keyPointer)
            kb[4] = UInt8(0xE0 | n.count)
            for i in 0..<15 { kb[5 + i] = i < n.count ? n[i] : 0 }
            image.writeBlock(e.keyPointer, kb)
        }
    }

    public func setAccess(_ path: [String], name: String, access: Int) throws {
        guard let e = try entry(path, name) else { throw ProDOSError.fileNotFound(name) }
        var b = image.readBlock(e.block)
        b[e.offset + 0x1E] = UInt8(access)
        image.writeBlock(e.block, b)
    }

    // MARK: Boot blocks

    /// True when block 0 holds a ProDOS boot loader (it starts with $01).
    public var hasBootBlocks: Bool { image.readBlock(0)[0] == 0x01 }

    /// Copies the boot loader (blocks 0 and 1) from another, bootable ProDOS volume.
    public func copyBootBlocks(from source: ProDOSVolume) throws {
        guard source.hasBootBlocks else { throw ProDOSError.unsupported("the source disk has no boot blocks") }
        image.writeBlock(0, source.image.readBlock(0))
        image.writeBlock(1, source.image.readBlock(1))
    }

    /// The first SYS file whose name ends in .SYSTEM, in directory order (what ProDOS starts).
    public func firstSystemFile() throws -> String? {
        try entries([]).first { $0.fileType == 0xFF && $0.name.uppercased().hasSuffix(".SYSTEM") }?.name
    }

    // MARK: Blank volumes

    /// Builds an empty ProDOS-order volume (not bootable: no boot loader or PRODOS file).
    public static func blankImage(volumeName: String, blocks: Int) throws -> Data {
        let name = try validName(volumeName)
        guard (16...65535).contains(blocks) else { throw ProDOSError.unsupported("\(blocks) blocks") }
        var img = [UInt8](repeating: 0, count: blocks * 512)
        for blk in 2...5 {
            let o = blk * 512
            put16(&img, o, blk == 2 ? 0 : blk - 1)
            put16(&img, o + 2, blk == 5 ? 0 : blk + 1)
        }
        let now = ProDOSDate.encode(Date())
        let h = 2 * 512 + 4
        let n = Array(name.utf8)
        img[h] = UInt8(0xF0 | n.count)
        img.replaceSubrange(h + 1..<h + 1 + n.count, with: n)
        put16(&img, h + 0x18, now.date)
        put16(&img, h + 0x1A, now.time)
        img[h + 0x1E] = 0xC3
        img[h + 0x1F] = 0x27
        img[h + 0x20] = 0x0D
        put16(&img, h + 0x23, 6)
        put16(&img, h + 0x25, blocks)
        let bitmapBlocks = (blocks + 4095) / 4096
        for blk in (6 + bitmapBlocks)..<blocks {
            img[6 * 512 + blk / 8] |= UInt8(0x80 >> (blk % 8))
        }
        return Data(img)
    }
}

// MARK: - File type names

public enum ProDOSFileType {
    static let names: [Int: String] = [
        0x00: "NON", 0x01: "BAD", 0x04: "TXT", 0x06: "BIN", 0x08: "FOT", 0x0F: "DIR",
        0x19: "ADB", 0x1A: "AWP", 0x1B: "ASP", 0xB0: "SRC", 0xB3: "S16", 0xC0: "PNT",
        0xC1: "PIC", 0xC9: "FND", 0xE0: "LBR", 0xEF: "PAS", 0xF0: "CMD", 0xFA: "INT",
        0xFB: "IVR", 0xFC: "BAS", 0xFD: "VAR", 0xFE: "REL", 0xFF: "SYS",
    ]

    public static func name(_ t: Int) -> String { names[t] ?? String(format: "$%02X", t) }

    /// Type and aux type guessed from a Mac file name extension.
    public static func guess(fromExtension ext: String) -> (type: Int, aux: Int) {
        switch ext.lowercased() {
        case "txt", "text": return (0x04, 0)
        case "sys", "system": return (0xFF, 0x2000)
        case "bas": return (0xFC, 0x0801)
        case "s16": return (0xB3, 0)
        default: return (0x06, 0)
        }
    }
}

/// CiderPress-style "NAME#TTAAAA" suffix that keeps ProDOS type/aux in a Mac file name.
public enum TypeSuffix {
    public static func make(name: String, type: Int, aux: Int) -> String {
        name + String(format: "#%02X%04X", type, aux)
    }

    /// Splits "NAME#FF2000" into ("NAME", 0xFF, 0x2000). Returns nil type when there is no suffix.
    public static func parse(_ s: String) -> (name: String, type: Int?, aux: Int?) {
        guard let hash = s.lastIndex(of: "#") else { return (s, nil, nil) }
        let hex = s[s.index(after: hash)...]
        guard hex.count == 6, hex.allSatisfy({ $0.isHexDigit }),
              let t = Int(hex.prefix(2), radix: 16), let a = Int(hex.suffix(4), radix: 16)
        else { return (s, nil, nil) }
        return (String(s[..<hash]), t, a)
    }
}
