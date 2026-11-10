import Foundation

/// An Apple DOS 3.3 file system on a 140K disk image (35 tracks x 16 sectors).
/// DOS 3.3 has no directories; paths must be empty.
public final class DOS33Volume {
    public let image: DiskImage
    let tracks = 35
    static let maxPairs = 122                 // track/sector pairs per T/S list sector

    public struct Entry {
        public var name: String
        public var tsTrack: Int
        public var tsSector: Int
        public var type: UInt8                // bit 7 = locked
        public var sectors: Int
        public var track: Int                 // where the catalog entry lives
        public var sector: Int
        public var offset: Int
        public var locked: Bool { type & 0x80 != 0 }
    }

    public init(image: DiskImage) throws {
        guard image.blockCount == 280 else { throw ProDOSError.unsupported("DOS 3.3 is supported on 140K disks only") }
        self.image = image
        let v = image.readSector(17, 0)
        guard v[0x27] == 122, v[0x34] == 35, v[0x35] == 16, (1...3).contains(Int(v[3])) else {
            throw ProDOSError.unsupported("no DOS 3.3 catalog found")
        }
    }

    public var volumeNumber: Int { Int(image.readSector(17, 0)[6]) }

    // MARK: Free-sector bitmap (in the VTOC, 4 bytes per track, bit set = free)

    private func bit(_ t: Int, _ s: Int) -> (offset: Int, mask: UInt8) {
        (0x38 + 4 * t + (s >= 8 ? 0 : 1), UInt8(1 << (s & 7)))
    }

    func isFree(_ t: Int, _ s: Int) -> Bool {
        let b = bit(t, s)
        return image.readSector(17, 0)[b.offset] & b.mask != 0
    }

    func setFree(_ t: Int, _ s: Int, _ free: Bool) {
        let b = bit(t, s)
        var v = image.readSector(17, 0)
        if free { v[b.offset] |= b.mask } else { v[b.offset] &= ~b.mask }
        image.writeSector(17, 0, v)
    }

    public func freeSectorCount() -> Int {
        var n = 0
        for t in 0..<tracks { for s in 0..<16 where isFree(t, s) { n += 1 } }
        return n
    }

    /// Allocates a free sector (tracks 18-34, then 16-1), marks it used and zeroes it.
    func alloc() throws -> (Int, Int) {
        let order = Array(18..<tracks) + Array(stride(from: 16, through: 1, by: -1))
        for t in order {
            for s in stride(from: 15, through: 0, by: -1) where isFree(t, s) {
                setFree(t, s, false)
                image.writeSector(t, s, [UInt8](repeating: 0, count: 256))
                return (t, s)
            }
        }
        throw ProDOSError.diskFull
    }

    // MARK: Catalog

    func catalogSectors() -> [(Int, Int)] {
        let v = image.readSector(17, 0)
        var t = Int(v[1]), s = Int(v[2])
        var out: [(Int, Int)] = []
        var seen = Set<Int>()
        while t != 0, t < tracks, s < 16, seen.insert(t * 16 + s).inserted {
            out.append((t, s))
            let c = image.readSector(t, s)
            t = Int(c[1]); s = Int(c[2])
        }
        return out
    }

    func allEntries() -> [Entry] {
        var res: [Entry] = []
        for (t, s) in catalogSectors() {
            let c = image.readSector(t, s)
            for i in 0..<7 {
                let o = 0x0B + i * 35
                if c[o] == 0 || c[o] == 0xFF { continue }
                let chars = c[o + 3..<o + 33].map { $0 & 0x7F }
                var name = String(decoding: chars, as: UTF8.self)
                while name.hasSuffix(" ") { name.removeLast() }
                res.append(Entry(name: name, tsTrack: Int(c[o]), tsSector: Int(c[o + 1]), type: c[o + 2],
                                 sectors: Int(c[o + 33]) | Int(c[o + 34]) << 8, track: t, sector: s, offset: o))
            }
        }
        return res
    }

    public func entry(_ name: String) -> Entry? {
        allEntries().first { $0.name.uppercased() == name.uppercased() }
    }

    /// T/S list sectors and data sectors of a file (trailing empty pairs dropped).
    func sectorsOf(_ e: Entry) -> (tsl: [(Int, Int)], data: [(Int, Int)]) {
        var t = e.tsTrack, s = e.tsSector
        var tsl: [(Int, Int)] = []
        var data: [(Int, Int)] = []
        var seen = Set<Int>()
        while t != 0, t < tracks, s < 16, seen.insert(t * 16 + s).inserted {
            tsl.append((t, s))
            let b = image.readSector(t, s)
            for i in 0..<DOS33Volume.maxPairs {
                data.append((Int(b[0x0C + 2 * i]), Int(b[0x0D + 2 * i])))
            }
            t = Int(b[1]); s = Int(b[2])
        }
        while let last = data.last, last.0 == 0 { data.removeLast() }
        return (tsl, data)
    }

    public func rawData(_ e: Entry) -> [UInt8] {
        var out: [UInt8] = []
        for (t, s) in sectorsOf(e).data {
            out += (t == 0 || t >= tracks || s >= 16) ? [UInt8](repeating: 0, count: 256) : image.readSector(t, s)
        }
        return out
    }

    public static func typeLetter(_ type: UInt8) -> String {
        switch type & 0x7F {
        case 0x00: return "T"
        case 0x01: return "I"
        case 0x02: return "A"
        case 0x04: return "B"
        case 0x08: return "S"
        case 0x10: return "R"
        case 0x20: return "a"
        case 0x40: return "b"
        default: return "?"
        }
    }

    /// File data without the DOS header, with a ProDOS-style type and aux type.
    func decode(_ e: Entry) -> FileContents {
        let r = rawData(e)
        func le(_ o: Int) -> Int { r.count > o + 1 ? Int(r[o]) | Int(r[o + 1]) << 8 : 0 }
        func slice(_ from: Int, _ count: Int) -> Data {
            guard from < r.count else { return Data() }
            return Data(r[from..<min(r.count, from + count)])
        }
        switch e.type & 0x7F {
        case 0x04:                                        // B: address, length, data
            return FileContents(data: slice(4, le(2)), fileType: 0x06, auxType: le(0))
        case 0x02:                                        // A: length, tokenized Applesoft
            return FileContents(data: slice(2, le(0)), fileType: 0xFC, auxType: 0x0801)
        case 0x01:                                        // I: length, Integer BASIC
            return FileContents(data: slice(2, le(0)), fileType: 0xFA, auxType: 0)
        case 0x00:                                        // T: high-bit text, ends at the first zero
            let end = r.firstIndex(of: 0) ?? r.count
            return FileContents(data: Data(r[0..<end].map { $0 & 0x7F }), fileType: 0x04, auxType: 0)
        case 0x10:
            return FileContents(data: Data(r), fileType: 0xFE, auxType: 0)
        default:
            return FileContents(data: Data(r), fileType: 0x06, auxType: 0)
        }
    }

    // MARK: Names

    /// DOS 3.3 names: up to 30 characters, starting with a letter, no commas.
    public static func validName(_ s: String) throws -> String {
        let n = s.uppercased()
        guard (1...30).contains(n.count),
              let f = n.unicodeScalars.first, ("A"..."Z").contains(Character(f)),
              n.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F && $0 != "," })
        else { throw ProDOSError.invalidName(s) }
        return n
    }

    public static func sanitizedName(_ s: String) -> String {
        var out = ""
        for u in s.uppercased().unicodeScalars where u.value >= 0x20 && u.value < 0x7F && u != "," {
            out.unicodeScalars.append(u)
        }
        out = out.trimmingCharacters(in: .whitespaces)
        if out.isEmpty { out = "FILE" }
        if let f = out.first, !("A"..."Z").contains(f) { out = "X" + out }
        if out.count > 30 { out = String(out.prefix(30)) }
        return out
    }

    // MARK: Writing

    public func writeFile(name: String, contents c: FileContents, overwrite: Bool) throws {
        let name = try DOS33Volume.validName(name)
        if let old = entry(name) {
            guard overwrite else { throw ProDOSError.duplicateName(name) }
            try deleteFile(old.name)
        }
        let data = [UInt8](c.data)
        guard data.count <= 0xFFFF || c.fileType == 0x04 || c.fileType == 0xFE else {
            throw ProDOSError.unsupported("DOS 3.3 files of this type are limited to 64K")
        }
        let dosType: UInt8
        var payload: [UInt8]
        func len16(_ n: Int) -> [UInt8] { [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF)] }
        switch c.fileType {
        case 0x04:
            dosType = 0x00
            payload = data.map { $0 | 0x80 }
        case 0xFC:
            dosType = 0x02
            payload = len16(data.count) + data
        case 0xFA:
            dosType = 0x01
            payload = len16(data.count) + data
        case 0xFE:
            dosType = 0x10
            payload = data
        default:
            dosType = 0x04
            payload = len16(c.auxType) + len16(data.count) + data
        }
        let nData = (payload.count + 255) / 256
        let nTSL = max(1, (nData + DOS33Volume.maxPairs - 1) / DOS33Volume.maxPairs)
        guard freeSectorCount() >= nData + nTSL else { throw ProDOSError.diskFull }

        // free catalog slot
        var slot: (Int, Int, Int)?
        search: for (t, s) in catalogSectors() {
            let cat = image.readSector(t, s)
            for i in 0..<7 {
                let o = 0x0B + i * 35
                if cat[o] == 0 || cat[o] == 0xFF { slot = (t, s, o); break search }
            }
        }
        guard let freeSlot = slot else { throw ProDOSError.directoryFull }
        let (ct, cs, co) = freeSlot

        var tsl: [(Int, Int)] = []
        for _ in 0..<nTSL { tsl.append(try alloc()) }
        var ds: [(Int, Int)] = []
        for i in 0..<nData {
            let ts = try alloc()
            var blk = [UInt8](repeating: 0, count: 256)
            let from = i * 256, to = min(from + 256, payload.count)
            blk.replaceSubrange(0..<(to - from), with: payload[from..<to])
            image.writeSector(ts.0, ts.1, blk)
            ds.append(ts)
        }
        for (k, ts) in tsl.enumerated() {
            var b = [UInt8](repeating: 0, count: 256)
            if k + 1 < tsl.count { b[1] = UInt8(tsl[k + 1].0); b[2] = UInt8(tsl[k + 1].1) }
            let first = k * DOS33Volume.maxPairs
            b[5] = UInt8(first & 0xFF); b[6] = UInt8(first >> 8)
            for (i, d) in ds[first..<min(first + DOS33Volume.maxPairs, ds.count)].enumerated() {
                b[0x0C + 2 * i] = UInt8(d.0)
                b[0x0D + 2 * i] = UInt8(d.1)
            }
            image.writeSector(ts.0, ts.1, b)
        }
        var cat = image.readSector(ct, cs)
        cat[co] = UInt8(tsl[0].0)
        cat[co + 1] = UInt8(tsl[0].1)
        cat[co + 2] = dosType
        let nameBytes = Array(name.utf8)
        for i in 0..<30 { cat[co + 3 + i] = (i < nameBytes.count ? nameBytes[i] : 0x20) | 0x80 }
        let total = nData + nTSL
        cat[co + 33] = UInt8(total & 0xFF)
        cat[co + 34] = UInt8(total >> 8)
        image.writeSector(ct, cs, cat)
    }

    public func deleteFile(_ name: String) throws {
        guard let e = entry(name) else { throw ProDOSError.fileNotFound(name) }
        let secs = sectorsOf(e)
        for (t, s) in secs.data + secs.tsl where t != 0 && t < tracks && s < 16 {
            setFree(t, s, true)
        }
        var cat = image.readSector(e.track, e.sector)
        cat[e.offset + 0x20] = cat[e.offset]        // DOS keeps the old track here
        cat[e.offset] = 0xFF
        image.writeSector(e.track, e.sector, cat)
    }

    public func renameEntry(from: String, to: String) throws {
        let newName = try DOS33Volume.validName(to)
        guard let e = entry(from) else { throw ProDOSError.fileNotFound(from) }
        if newName != e.name.uppercased(), entry(newName) != nil { throw ProDOSError.duplicateName(newName) }
        var cat = image.readSector(e.track, e.sector)
        let nameBytes = Array(newName.utf8)
        for i in 0..<30 { cat[e.offset + 3 + i] = (i < nameBytes.count ? nameBytes[i] : 0x20) | 0x80 }
        image.writeSector(e.track, e.sector, cat)
    }

    // MARK: Blank disks

    /// An empty DOS 3.3 data disk in DOS order (not bootable: no DOS on tracks 0-2).
    public static func blankImage(volume: Int = 254) -> Data {
        var img = [UInt8](repeating: 0, count: 35 * 16 * 256)
        func put(_ t: Int, _ s: Int, _ b: [UInt8]) {
            let o = (t * 16 + s) * 256
            img.replaceSubrange(o..<o + 256, with: b)
        }
        var v = [UInt8](repeating: 0, count: 256)
        v[1] = 17; v[2] = 15; v[3] = 3; v[6] = UInt8(volume & 0xFF); v[0x27] = 122
        v[0x30] = 17; v[0x31] = 1; v[0x34] = 35; v[0x35] = 16; v[0x36] = 0; v[0x37] = 1
        for t in 1..<35 where t != 17 {
            v[0x38 + 4 * t] = 0xFF
            v[0x38 + 4 * t + 1] = 0xFF
        }
        put(17, 0, v)
        for s in stride(from: 15, through: 1, by: -1) {
            var c = [UInt8](repeating: 0, count: 256)
            if s > 1 { c[1] = 17; c[2] = UInt8(s - 1) }
            put(17, s, c)
        }
        return Data(img)
    }
}

// MARK: - DiskVolume

extension DOS33Volume: DiskVolume {
    public var displayName: String { "DOS 3.3 #\(volumeNumber)" }
    public var formatName: String { "DOS 3.3" }
    public var supportsDirectories: Bool { false }

    public func freeSpaceText() -> String { "\(freeSectorCount()) of 560 sectors free" }

    private func requireRoot(_ path: [String]) throws {
        guard path.isEmpty else { throw ProDOSError.pathNotFound(path.joined(separator: "/")) }
    }

    func convert(_ e: Entry) -> VolumeEntry {
        let c = decode(e)
        return VolumeEntry(name: e.name, isDirectory: false, size: c.data.count, fileType: c.fileType,
                           auxType: c.auxType, typeText: DOS33Volume.typeLetter(e.type),
                           modified: nil, locked: e.locked)
    }

    public func list(_ path: [String]) throws -> [VolumeEntry] {
        try requireRoot(path)
        return allEntries().map(convert)
    }

    public func lookup(_ path: [String], _ name: String) throws -> VolumeEntry? {
        try requireRoot(path)
        return entry(name).map(convert)
    }

    public func read(_ path: [String], _ name: String) throws -> FileContents {
        try requireRoot(path)
        guard let e = entry(name) else { throw ProDOSError.fileNotFound(name) }
        return decode(e)
    }

    public func write(_ path: [String], name: String, contents: FileContents, overwrite: Bool) throws {
        try requireRoot(path)
        try writeFile(name: name, contents: contents, overwrite: overwrite)
    }

    public func makeDirectory(_ path: [String], name: String) throws {
        throw ProDOSError.unsupported("DOS 3.3 disks have no directories")
    }

    public func remove(_ path: [String], name: String) throws {
        try requireRoot(path)
        try deleteFile(name)
    }

    public func renameFile(_ path: [String], from: String, to: String) throws {
        try requireRoot(path)
        try renameEntry(from: from, to: to)
    }

    public func legalName(_ s: String) -> String { DOS33Volume.sanitizedName(s) }

    public func save() throws { try image.save() }
}
