import Foundation

/// One file or directory, as shown in a panel (any file system).
public struct VolumeEntry {
    public var name: String
    public var isDirectory: Bool
    public var size: Int
    public var fileType: Int          // ProDOS-style file type
    public var auxType: Int
    public var typeText: String       // what the panel shows ("BIN", "B", ...)
    public var modified: Date?
    public var locked: Bool
}

/// A file's data plus the attributes that travel with it when copied.
public struct FileContents {
    public var data: Data
    public var fileType: Int
    public var auxType: Int
    public var access: Int?
    public var created: (Int, Int)?
    public var modified: (Int, Int)?

    public init(data: Data, fileType: Int, auxType: Int, access: Int? = nil,
                created: (Int, Int)? = nil, modified: (Int, Int)? = nil) {
        self.data = data
        self.fileType = fileType
        self.auxType = auxType
        self.access = access
        self.created = created
        self.modified = modified
    }
}

/// What the app needs from a file system inside a disk image.
public protocol DiskVolume: AnyObject {
    var image: DiskImage { get }
    var displayName: String { get }
    var formatName: String { get }
    var supportsDirectories: Bool { get }
    func freeSpaceText() -> String
    func list(_ path: [String]) throws -> [VolumeEntry]
    func lookup(_ path: [String], _ name: String) throws -> VolumeEntry?
    func read(_ path: [String], _ name: String) throws -> FileContents
    func write(_ path: [String], name: String, contents: FileContents, overwrite: Bool) throws
    func makeDirectory(_ path: [String], name: String) throws
    func remove(_ path: [String], name: String) throws
    func renameFile(_ path: [String], from: String, to: String) throws
    func legalName(_ s: String) -> String
    func save() throws
}

public enum DiskVolumes {
    /// Opens an image as ProDOS, or else as DOS 3.3.
    public static func open(_ url: URL) throws -> DiskVolume {
        let image = try DiskImage(url: url)
        if let v = try? ProDOSVolume(image: image) { return v }
        if let v = try? DOS33Volume(image: image) { return v }
        throw ProDOSError.unsupported("no ProDOS or DOS 3.3 file system found")
    }
}

extension ProDOSVolume: DiskVolume {
    public var displayName: String { volumeName }
    public var formatName: String { "ProDOS" }
    public var supportsDirectories: Bool { true }

    public func freeSpaceText() -> String { "\(freeBlockCount()) of \(totalBlocks) blocks free" }

    static func convert(_ e: ProDOSEntry) -> VolumeEntry {
        VolumeEntry(name: e.name, isDirectory: e.isDirectory, size: e.eof, fileType: e.fileType,
                    auxType: e.auxType, typeText: ProDOSFileType.name(e.fileType),
                    modified: e.modified, locked: e.isLocked)
    }

    public func list(_ path: [String]) throws -> [VolumeEntry] {
        try entries(path).map(ProDOSVolume.convert)
    }

    public func lookup(_ path: [String], _ name: String) throws -> VolumeEntry? {
        try entry(path, name).map(ProDOSVolume.convert)
    }

    public func read(_ path: [String], _ name: String) throws -> FileContents {
        guard let e = try entry(path, name) else { throw ProDOSError.fileNotFound(name) }
        return FileContents(data: try readFile(e), fileType: e.fileType, auxType: e.auxType,
                            access: e.access, created: e.createdRaw, modified: e.modifiedRaw)
    }

    public func write(_ path: [String], name: String, contents c: FileContents, overwrite: Bool) throws {
        try writeFile(path, name: name, data: c.data, fileType: c.fileType, auxType: c.auxType,
                      access: c.access ?? 0xE3, created: c.created, modified: c.modified, overwrite: overwrite)
    }

    public func makeDirectory(_ path: [String], name: String) throws {
        try createDirectory(path, name: name)
    }

    public func remove(_ path: [String], name: String) throws {
        try delete(path, name: name, force: true)
    }

    public func renameFile(_ path: [String], from: String, to: String) throws {
        try rename(path, from: from, to: to)
    }

    public func legalName(_ s: String) -> String { ProDOSVolume.sanitizedName(s) }
}
