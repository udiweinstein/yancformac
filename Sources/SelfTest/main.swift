// Self-contained test runner for ProDOSKit (no XCTest / Swift Testing needed).
// Run with:  swift run SelfTest
import Foundation
import ProDOSKit

var failures = 0
var checks = 0

func check(_ cond: @autoclosure () throws -> Bool, _ text: String, line: Int = #line) {
    checks += 1
    do {
        if try !cond() { failures += 1; print("  FAIL (line \(line)): \(text)") }
    } catch {
        failures += 1; print("  FAIL (line \(line)): \(text) threw \(error)")
    }
}

func checkThrows<E: Error & Equatable, R>(_ expected: E, line: Int = #line, _ body: () throws -> R) {
    checks += 1
    do {
        _ = try body()
        failures += 1; print("  FAIL (line \(line)): expected \(expected), nothing thrown")
    } catch let e as E where e == expected {
    } catch {
        failures += 1; print("  FAIL (line \(line)): expected \(expected), got \(error)")
    }
}

func checkThrowsAny<R>(line: Int = #line, _ body: () throws -> R) {
    checks += 1
    do {
        _ = try body()
        failures += 1; print("  FAIL (line \(line)): expected an error")
    } catch {
    }
}

struct Missing: Error {}
func unwrap<T>(_ v: T?, line: Int = #line) throws -> T {
    guard let v else { print("  FAIL (line \(line)): unexpected nil"); failures += 1; throw Missing() }
    return v
}

// little-endian helpers (the library's own are internal)
func le16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
func put16(_ b: inout [UInt8], _ o: Int, _ v: Int) { b[o] = UInt8(v & 0xFF); b[o + 1] = UInt8((v >> 8) & 0xFF) }
func put24(_ b: inout [UInt8], _ o: Int, _ v: Int) { put16(&b, o, v & 0xFFFF); b[o + 2] = UInt8((v >> 16) & 0xFF) }

final class ProDOSKitTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("prodoskit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func blank(_ name: String = "TEST", blocks: Int = 280, file: String = "t.po") throws -> ProDOSVolume {
        let url = dir.appendingPathComponent(file)
        try ProDOSVolume.blankImage(volumeName: name, blocks: blocks).write(to: url)
        return try ProDOSVolume(url: url)
    }

    func read(_ v: ProDOSVolume, _ path: [String], _ name: String) throws -> Data {
        guard let e = try v.entry(path, name) else { throw ProDOSError.fileNotFound(name) }
        return try v.readFile(e)
    }

    func bytes(_ n: Int, seed: UInt8 = 7) -> Data {
        Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    func testBlankVolume() throws {
        let v = try blank("BLANK")
        check(v.volumeName == "BLANK", "v.volumeName == \"BLANK\"")
        check(v.totalBlocks == 280, "v.totalBlocks == 280")
        check(v.freeBlockCount() == 280 - 7, "v.freeBlockCount() == 280 - 7")
        check(try v.entries([]).count == 0, "try v.entries([]).count == 0")
    }

    func testSeedlingSaplingTreeRoundTrip() throws {
        let v = try blank(blocks: 1600)
        let free0 = v.freeBlockCount()
        let small = bytes(100), medium = bytes(20_000, seed: 3), big = bytes(200_000, seed: 9)
        try v.writeFile([], name: "SMALL", data: small, fileType: 0x04, auxType: 0)
        try v.writeFile([], name: "MEDIUM", data: medium, fileType: 0x06, auxType: 0x2000)
        try v.writeFile([], name: "BIG", data: big, fileType: 0x06, auxType: 0)
        try v.save()

        let v2 = try ProDOSVolume(url: v.image.url)          // re-open from disk
        let s = try unwrap(v2.entry([], "SMALL"))
        let m = try unwrap(v2.entry([], "MEDIUM"))
        let b = try unwrap(v2.entry([], "BIG"))
        check([s.storageType, m.storageType, b.storageType] == [1, 2, 3], "[s.storageType, m.storageType, b.storageType] == [1, 2, 3]")
        check(m.auxType == 0x2000, "m.auxType == 0x2000")
        check(try v2.readFile(s) == small, "try v2.readFile(s) == small")
        check(try v2.readFile(m) == medium, "try v2.readFile(m) == medium")
        check(try v2.readFile(b) == big, "try v2.readFile(b) == big")
        check(s.blocksUsed == 1, "s.blocksUsed == 1")
        check(m.blocksUsed == 40 + 1, "m.blocksUsed == 40 + 1")
        check(b.blocksUsed == 391 + 2 + 1, "b.blocksUsed == 391 + 2 + 1")
        check(v2.freeBlockCount() == free0 - s.blocksUsed - m.blocksUsed - b.blocksUsed, "v2.freeBlockCount() == free0 - s.blocksUsed - m.blocksUsed - b.blocksUsed")

        let slot = (s.block, s.offset)
        for n in ["SMALL", "MEDIUM", "BIG"] { try v2.delete([], name: n) }
        check(v2.image.readBlock(slot.0)[slot.1] == 0, "deleted entry byte is fully zero (like ProDOS)")
        check(v2.freeBlockCount() == free0, "v2.freeBlockCount() == free0")
        check(try v2.entries([]).count == 0, "try v2.entries([]).count == 0")
    }

    func testEmptyAndExact512Files() throws {
        let v = try blank()
        try v.writeFile([], name: "EMPTY", data: Data(), fileType: 0x04, auxType: 0)
        try v.writeFile([], name: "EXACT", data: bytes(512), fileType: 0x06, auxType: 0)
        try v.writeFile([], name: "EXACT1", data: bytes(513), fileType: 0x06, auxType: 0)
        check(try read(v, [], "EMPTY") == Data(), "try read(v, [], \"EMPTY\") == Data()")
        check(try read(v, [], "EXACT") == bytes(512), "try read(v, [], \"EXACT\") == bytes(512)")
        check(try read(v, [], "EXACT1") == bytes(513), "try read(v, [], \"EXACT1\") == bytes(513)")
        check(try v.entry([], "EXACT1")?.storageType == 2, "try v.entry([], \"EXACT1\")?.storageType == 2")
    }

    func testSubdirectoryGrowsAndShrinks() throws {
        let v = try blank(blocks: 800)
        let free0 = v.freeBlockCount()
        try v.createDirectory([], name: "SUB")
        try v.createDirectory(["SUB"], name: "INNER")
        for i in 0..<30 {
            try v.writeFile(["SUB"], name: "F\(i)", data: bytes(10 + i), fileType: 0x06, auxType: 0)
        }
        check(try v.entries(["SUB"]).count == 31, "try v.entries([\"SUB\"]).count == 31")
        let sub = try unwrap(v.entry([], "SUB"))
        check(sub.isDirectory, "sub.isDirectory")
        // 31 entries + header = 3 blocks
        check(sub.blocksUsed == 3, "sub.blocksUsed == 3")
        check(sub.eof == 3 * 512, "sub.eof == 3 * 512")
        check(try read(v, ["SUB"], "F29") == bytes(39), "try read(v, [\"SUB\"], \"F29\") == bytes(39)")

        try v.writeFile(["SUB", "INNER"], name: "DEEP", data: bytes(1000), fileType: 0x06, auxType: 0)
        check(try read(v, ["SUB", "INNER"], "DEEP") == bytes(1000), "try read(v, [\"SUB\", \"INNER\"], \"DEEP\") == bytes(1000)")

        checkThrows(ProDOSError.directoryNotEmpty("SUB")) { try v.delete([], name: "SUB") }
        try v.delete(["SUB", "INNER"], name: "DEEP")
        try v.delete(["SUB"], name: "INNER")
        for i in 0..<30 { try v.delete(["SUB"], name: "F\(i)") }
        try v.delete([], name: "SUB")
        check(v.freeBlockCount() == free0, "v.freeBlockCount() == free0")
    }

    func testSubdirectoryHeaderPointsToParent() throws {
        let v = try blank()
        for i in 0..<14 { try v.writeFile([], name: "X\(i)", data: bytes(5), fileType: 6, auxType: 0) }
        try v.createDirectory([], name: "LATE")            // lands in the 2nd volume-directory block
        let e = try unwrap(v.entry([], "LATE"))
        let kb = v.image.readBlock(e.keyPointer)
        check(kb[4] >> 4 == 0xE, "kb[4] >> 4 == 0xE")
        check(kb[4 + 0x10] == 0x75, "kb[4 + 0x10] == 0x75")
        check(le16(kb, 4 + 0x23) == e.block, "le16(kb, 4 + 0x23) == e.block")
        check(Int(kb[4 + 0x25]) == (e.offset - 4) / 0x27 + 1, "Int(kb[4 + 0x25]) == (e.offset - 4) / 0x27 + 1")
        check(kb[4 + 0x26] == 0x27, "kb[4 + 0x26] == 0x27")
    }

    func testVolumeDirectoryFull() throws {
        let v = try blank(blocks: 800)
        for i in 0..<51 { try v.writeFile([], name: "F\(i)", data: bytes(1), fileType: 6, auxType: 0) }
        checkThrows(ProDOSError.directoryFull) { try v.writeFile([], name: "ONEMORE", data: bytes(1), fileType: 6, auxType: 0) }
    }

    func testDiskFull() throws {
        let v = try blank(blocks: 280)
        let free0 = v.freeBlockCount()
        checkThrows(ProDOSError.diskFull) { try v.writeFile([], name: "HUGE", data: bytes(200_000), fileType: 6, auxType: 0) }
        check(v.freeBlockCount() == free0, "v.freeBlockCount() == free0")
    }

    func testDuplicateOverwriteRenameLocked() throws {
        let v = try blank()
        try v.writeFile([], name: "A", data: bytes(10), fileType: 6, auxType: 0)
        checkThrowsAny { try v.writeFile([], name: "a", data: bytes(10), fileType: 6, auxType: 0) }
        try v.writeFile([], name: "A", data: bytes(700), fileType: 4, auxType: 0, overwrite: true)
        check(try read(v, [], "A") == bytes(700), "try read(v, [], \"A\") == bytes(700)")

        try v.rename([], from: "A", to: "renamed.txt")
        check(try v.entry([], "A") == nil, "try v.entry([], \"A\") == nil")
        check(try v.entry([], "RENAMED.TXT") != nil, "try v.entry([], \"RENAMED.TXT\") != nil")
        try v.writeFile([], name: "B", data: bytes(1), fileType: 6, auxType: 0)
        checkThrowsAny { try v.rename([], from: "B", to: "RENAMED.TXT") }
        checkThrowsAny { try v.rename([], from: "B", to: "1BAD") }

        try v.createDirectory([], name: "D")
        try v.rename([], from: "D", to: "DIR2")
        let dir2 = try unwrap(v.entry([], "DIR2"))
        check(v.image.readBlock(dir2.keyPointer)[5] == UInt8(ascii: "D"), "v.image.readBlock(dir2.keyPointer)[5] == UInt8(ascii: \"D\")")
        try v.writeFile(["DIR2"], name: "IN", data: bytes(3), fileType: 6, auxType: 0)
        check(try v.entry(["DIR2"], "IN") != nil, "try v.entry([\"DIR2\"], \"IN\") != nil")

        try v.setAccess([], name: "B", access: 0x21)
        check(try v.entry([], "B")?.isLocked == true, "try v.entry([], \"B\")?.isLocked == true")
        checkThrows(ProDOSError.fileLocked("B")) { try v.delete([], name: "B") }
        try v.delete([], name: "B", force: true)
    }

    func testDOSOrderDsk() throws {
        let v = try blank("DOSORD")
        try v.writeFile([], name: "HELLO", data: bytes(3000), fileType: 6, auxType: 0x0300)
        try v.save()
        // re-interleave the ProDOS-order image into DOS 3.3 sector order
        let po = [UInt8](try Data(contentsOf: v.image.url))
        var dsk = [UInt8](repeating: 0, count: po.count)
        for blk in 0..<280 {
            let (a, b) = DiskImage.halfOffsets(blk, off: 0, dos: true)
            dsk.replaceSubrange(a..<a + 256, with: po[blk * 512..<blk * 512 + 256])
            dsk.replaceSubrange(b..<b + 256, with: po[blk * 512 + 256..<blk * 512 + 512])
        }
        let url = dir.appendingPathComponent("disk.dsk")
        try Data(dsk).write(to: url)
        let img = try DiskImage(url: url)
        check(img.dosOrder, "img.dosOrder")
        let d = try ProDOSVolume(image: img)
        check(d.volumeName == "DOSORD", "d.volumeName == \"DOSORD\"")
        check(try read(d, [], "HELLO") == bytes(3000), "try read(d, [], \"HELLO\") == bytes(3000)")
        // write through the DOS-order mapping and read back
        try d.writeFile([], name: "NEW", data: bytes(5000, seed: 1), fileType: 6, auxType: 0)
        try d.save()
        let d2 = try ProDOSVolume(url: url)
        check(try read(d2, [], "NEW") == bytes(5000, seed: 1), "try read(d2, [], \"NEW\") == bytes(5000, seed: 1)")
    }

    func testTwoIMG() throws {
        let po = try ProDOSVolume.blankImage(volumeName: "TWOMG", blocks: 1600)
        var h = [UInt8](repeating: 0, count: 64)
        h.replaceSubrange(0..<4, with: Array("2IMG".utf8))
        h[0x0C] = 1                                       // ProDOS order
        put16(&h, 0x18, 64)
        put24(&h, 0x1C, po.count)
        let url = dir.appendingPathComponent("x.2mg")
        try (Data(h) + po).write(to: url)
        let v = try ProDOSVolume(url: url)
        check(v.volumeName == "TWOMG", "v.volumeName == \"TWOMG\"")
        try v.writeFile([], name: "F", data: bytes(777), fileType: 6, auxType: 0)
        try v.save()
        let raw = try Data(contentsOf: url)
        // header kept
        check(Array(raw.prefix(4)) == Array("2IMG".utf8), "Array(raw.prefix(4)) == Array(\"2IMG\".utf8)")
        check(try read(ProDOSVolume(url: url), [], "F") == bytes(777), "try read(ProDOSVolume(url: url), [], \"F\") == bytes(777)")
    }

    func testNamesAndSuffixes() throws {
        check(try ProDOSVolume.validName("basic.system") == "BASIC.SYSTEM", "try ProDOSVolume.validName(\"basic.system\") == \"BASIC.SYSTEM\"")
        checkThrowsAny { try ProDOSVolume.validName("9LIVES") }
        checkThrowsAny { try ProDOSVolume.validName("SIXTEEN.CHARS.XX") }
        check(ProDOSVolume.sanitizedName("read me.txt") == "READ.ME.TXT", "ProDOSVolume.sanitizedName(\"read me.txt\") == \"READ.ME.TXT\"")
        check(ProDOSVolume.sanitizedName("2048 game") == "X2048.GAME", "ProDOSVolume.sanitizedName(\"2048 game\") == \"X2048.GAME\"")
        check(ProDOSVolume.sanitizedName("a_very_long_file_name.bin").count == 15, "ProDOSVolume.sanitizedName(\"a_very_long_file_name.bin\").count == 15")
        check(TypeSuffix.make(name: "PRODOS", type: 0xFF, aux: 0x2000) == "PRODOS#FF2000", "TypeSuffix.make(name: \"PRODOS\", type: 0xFF, aux: 0x2000) == \"PRODOS#FF2000\"")
        let p = TypeSuffix.parse("PRODOS#FF2000")
        check(p.name == "PRODOS", "p.name == \"PRODOS\"")
        check(p.type == 0xFF, "p.type == 0xFF")
        check(p.aux == 0x2000, "p.aux == 0x2000")
        check(nil == TypeSuffix.parse("NOTES#1").type, "nil == TypeSuffix.parse(\"NOTES#1\").type")
    }

    func testDates() throws {
        let (d, t) = ProDOSDate.encode(DateComponents(calendar: Calendar(identifier: .gregorian),
                                                      year: 2026, month: 11, day: 9, hour: 18, minute: 30).date!)
        check(d == (26 << 9) | (11 << 5) | 9, "d == (26 << 9) | (11 << 5) | 9")
        check(t == (18 << 8) | 30, "t == (18 << 8) | 30")
        let back = ProDOSDate.decode(date: d, time: t)!
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute], from: back)
        check([c.year, c.month, c.day, c.hour, c.minute] == [2026, 11, 9, 18, 30], "[c.year, c.month, c.day, c.hour, c.minute] == [2026, 11, 9, 18, 30]")
        check(nil == ProDOSDate.decode(date: 0, time: 0), "nil == ProDOSDate.decode(date: 0, time: 0)")
    }
}

let tests: [(String, (ProDOSKitTests) -> () throws -> Void)] = [
    ("testBlankVolume", ProDOSKitTests.testBlankVolume),
    ("testSeedlingSaplingTreeRoundTrip", ProDOSKitTests.testSeedlingSaplingTreeRoundTrip),
    ("testEmptyAndExact512Files", ProDOSKitTests.testEmptyAndExact512Files),
    ("testSubdirectoryGrowsAndShrinks", ProDOSKitTests.testSubdirectoryGrowsAndShrinks),
    ("testSubdirectoryHeaderPointsToParent", ProDOSKitTests.testSubdirectoryHeaderPointsToParent),
    ("testVolumeDirectoryFull", ProDOSKitTests.testVolumeDirectoryFull),
    ("testDiskFull", ProDOSKitTests.testDiskFull),
    ("testDuplicateOverwriteRenameLocked", ProDOSKitTests.testDuplicateOverwriteRenameLocked),
    ("testDOSOrderDsk", ProDOSKitTests.testDOSOrderDsk),
    ("testTwoIMG", ProDOSKitTests.testTwoIMG),
    ("testNamesAndSuffixes", ProDOSKitTests.testNamesAndSuffixes),
    ("testDates", ProDOSKitTests.testDates),
]

for (name, test) in tests {
    let before = failures
    do {
        let suite = try ProDOSKitTests()
        try test(suite)()
    } catch {
        failures += 1
        print("  FAIL: \(name) threw \(error)")
    }
    print(failures == before ? "PASS  \(name)" : "FAIL  \(name)")
}
print("")
print(failures == 0 ? "All \(tests.count) tests passed (\(checks) checks)." : "\(failures) failure(s) in \(checks) checks.")
exit(failures == 0 ? 0 : 1)
