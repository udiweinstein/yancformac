import AppKit
import Foundation
import ProDOSKit

// MARK: - Model types

/// Where a panel is looking: a Mac folder, or a directory inside a ProDOS disk image.
enum Location: Equatable {
    case mac(URL)
    case image(URL, [String])
}

struct Item: Identifiable, Equatable {
    enum Kind { case up, folder, file, image }
    let name: String
    let kind: Kind
    var size: Int64 = 0
    var typeText = ""
    var date: Date?
    var locked = false
    var fileType = 0
    var auxType = 0
    var id: String { name }
}

struct Panel {
    var location: Location
    var items: [Item] = []
    var cursor = 0
    var tagged: Set<String> = []
}

final class ImageSession {
    let url: URL
    let volume: DiskVolume
    init(url: URL) throws {
        self.url = url
        volume = try DiskVolumes.open(url)
    }
}

enum Dialog {
    case confirm(title: String, message: String, ok: String, action: () -> Void, alt: (label: String, action: () -> Void)?)
    case input(title: String, prompt: String, text: String, action: (String) -> Void)
    case overwrite(count: Int, action: (Bool) -> Void)
    case newImage(action: (String, Int) -> Void)
    case view(title: String, text: String)
    case message(title: String, text: String)
    case help
}

// MARK: - Commander

final class Commander: ObservableObject {
    @Published var panels: [Panel]
    @Published var active = 0
    @Published var dialog: Dialog?
    @Published var alert: String?

    private var sessions: [URL: ImageSession] = [:]
    private let fm = FileManager.default
    private var searchBuffer = ""
    private var searchTime = Date.distantPast

    var isModal: Bool { dialog != nil || alert != nil }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        panels = [Panel(location: .mac(home)), Panel(location: .mac(home))]
        reload(0)
        reload(1)
    }

    // MARK: Images

    func session(_ url: URL) throws -> ImageSession {
        let key = url.standardizedFileURL
        if let s = sessions[key] { return s }
        let s = try ImageSession(url: key)
        sessions[key] = s
        return s
    }

    private func forget(_ url: URL) {
        let key = url.standardizedFileURL
        sessions[key] = nil
        for i in 0..<2 {
            if case .image(let u, _) = panels[i].location, u == key {
                panels[i].location = .mac(key.deletingLastPathComponent())
                panels[i].items = []
            }
        }
    }

    // MARK: Listing

    func reload(_ i: Int, select: String? = nil) {
        var p = panels[i]
        let keep = select ?? (p.items.indices.contains(p.cursor) ? p.items[p.cursor].name : nil)
        do {
            p.items = try list(p.location)
        } catch {
            p.items = [Item(name: "..", kind: .up)]
            alert = error.localizedDescription
        }
        let names = Set(p.items.map(\.name))
        p.tagged = p.tagged.intersection(names)
        if let keep, let idx = p.items.firstIndex(where: { $0.name == keep }) {
            p.cursor = idx
        } else {
            p.cursor = min(p.cursor, max(0, p.items.count - 1))
        }
        panels[i] = p
    }

    func reloadAll() {
        reload(0)
        reload(1)
    }

    private func list(_ loc: Location) throws -> [Item] {
        switch loc {
        case .mac(let url):
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            let urls = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            var dirs: [Item] = []
            var files: [Item] = []
            for u in urls {
                let rv = try? u.resourceValues(forKeys: Set(keys))
                let name = u.lastPathComponent
                if rv?.isDirectory == true {
                    dirs.append(Item(name: name, kind: .folder, date: rv?.contentModificationDate))
                } else {
                    let isImg = DiskImage.isDiskImage(u)
                    files.append(Item(name: name, kind: isImg ? .image : .file, size: Int64(rv?.fileSize ?? 0),
                                      typeText: isImg ? "IMG" : String(u.pathExtension.uppercased().prefix(3)),
                                      date: rv?.contentModificationDate))
                }
            }
            let order: (Item, Item) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let up: [Item] = url.path == "/" ? [] : [Item(name: "..", kind: .up)]
            return up + dirs.sorted(by: order) + files.sorted(by: order)

        case .image(let url, let path):
            let vol = try session(url).volume
            var dirs: [Item] = []
            var files: [Item] = []
            for e in try vol.list(path) {
                let it = Item(name: e.name, kind: e.isDirectory ? .folder : .file, size: Int64(e.size),
                              typeText: e.typeText, date: e.modified, locked: e.locked,
                              fileType: e.fileType, auxType: e.auxType)
                if e.isDirectory { dirs.append(it) } else { files.append(it) }
            }
            let order: (Item, Item) -> Bool = { $0.name.uppercased() < $1.name.uppercased() }
            return [Item(name: "..", kind: .up)] + dirs.sorted(by: order) + files.sorted(by: order)
        }
    }

    // MARK: Text for the views

    func title(_ loc: Location) -> String {
        switch loc {
        case .mac(let url):
            let home = fm.homeDirectoryForCurrentUser.path
            return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
        case .image(let url, let path):
            let vol = sessions[url.standardizedFileURL]?.volume.displayName ?? "?"
            return url.lastPathComponent + "  /" + ([vol] + path).joined(separator: "/")
        }
    }

    func title(_ i: Int) -> String { title(panels[i].location) }

    func freeText(_ i: Int) -> String {
        switch panels[i].location {
        case .mac(let url):
            let rv = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            guard let free = rv?.volumeAvailableCapacityForImportantUsage else { return "" }
            return ByteCountFormatter.string(fromByteCount: free, countStyle: .file) + " free"
        case .image(let url, _):
            guard let v = sessions[url.standardizedFileURL]?.volume else { return "" }
            return v.formatName + "  –  " + v.freeSpaceText()
        }
    }

    func infoText(_ i: Int) -> String {
        let p = panels[i]
        if !p.tagged.isEmpty {
            let bytes = p.items.filter { p.tagged.contains($0.name) }.reduce(Int64(0)) { $0 + $1.size }
            return "\(bytes.formatted()) bytes in \(p.tagged.count) tagged"
        }
        guard p.items.indices.contains(p.cursor) else { return "" }
        let it = p.items[p.cursor]
        switch it.kind {
        case .up: return ".. (parent)"
        case .folder: return it.name + "  <DIR>"
        case .image: return it.name + "  disk image – Return opens it"
        case .file:
            var s = it.name + "  \(it.size.formatted()) bytes"
            if case .image = p.location { s += String(format: "  %@ $%04X", it.typeText, it.auxType) }
            return s
        }
    }

    // MARK: Cursor

    func move(_ delta: Int) {
        let n = panels[active].items.count
        guard n > 0 else { return }
        panels[active].cursor = max(0, min(n - 1, panels[active].cursor + delta))
    }

    func click(_ i: Int, _ row: Int) {
        active = i
        if panels[i].items.indices.contains(row) { panels[i].cursor = row }
    }

    var current: Item? {
        let p = panels[active]
        return p.items.indices.contains(p.cursor) ? p.items[p.cursor] : nil
    }

    func toggleTag() {
        guard let it = current, it.kind != .up else { move(1); return }
        if panels[active].tagged.contains(it.name) { panels[active].tagged.remove(it.name) }
        else { panels[active].tagged.insert(it.name) }
        move(1)
    }

    func tagAll(_ mode: Int) {          // 1 all files, 0 none, 2 invert
        var t = Set<String>()
        for it in panels[active].items where it.kind == .file || it.kind == .image {
            let on = panels[active].tagged.contains(it.name)
            if mode == 1 || (mode == 2 && !on) { t.insert(it.name) }
        }
        panels[active].tagged = t
    }

    func quickSearch(_ ch: String) {
        let now = Date()
        if now.timeIntervalSince(searchTime) > 1.0 { searchBuffer = "" }
        searchTime = now
        searchBuffer += ch.lowercased()
        if let idx = panels[active].items.firstIndex(where: { $0.kind != .up && $0.name.lowercased().hasPrefix(searchBuffer) }) {
            panels[active].cursor = idx
        }
    }

    // MARK: Navigation

    private func setLocation(_ loc: Location, select: String? = nil) {
        panels[active].location = loc
        panels[active].items = []
        panels[active].tagged = []
        panels[active].cursor = 0
        reload(active, select: select)
    }

    func enter() {
        guard let it = current else { return }
        let loc = panels[active].location
        switch (it.kind, loc) {
        case (.up, _):
            goUp()
        case (.folder, .mac(let u)):
            setLocation(.mac(u.appendingPathComponent(it.name).standardizedFileURL))
        case (.folder, .image(let u, let p)):
            setLocation(.image(u, p + [it.name]))
        case (.image, .mac(let u)):
            let iu = u.appendingPathComponent(it.name).standardizedFileURL
            do {
                _ = try session(iu)
                setLocation(.image(iu, []))
            } catch {
                alert = "\(it.name): \(error.localizedDescription)"
            }
        case (.file, .mac(let u)):
            NSWorkspace.shared.open(u.appendingPathComponent(it.name))
        case (.file, .image):
            view()
        default:
            break
        }
    }

    func goUp() {
        switch panels[active].location {
        case .mac(let u):
            guard u.path != "/" else { return }
            setLocation(.mac(u.deletingLastPathComponent().standardizedFileURL), select: u.lastPathComponent)
        case .image(let u, let p):
            if p.isEmpty {
                setLocation(.mac(u.deletingLastPathComponent().standardizedFileURL), select: u.lastPathComponent)
            } else {
                setLocation(.image(u, Array(p.dropLast())), select: p.last)
            }
        }
    }

    func reread() {
        for u in Array(sessions.keys) where !fm.fileExists(atPath: u.path) { forget(u) }
        sessions.removeAll()
        reloadAll()
    }

    // MARK: Selection

    func selection(_ i: Int) -> [Item] {
        let p = panels[i]
        if !p.tagged.isEmpty { return p.items.filter { p.tagged.contains($0.name) } }
        guard p.items.indices.contains(p.cursor), p.items[p.cursor].kind != .up else { return [] }
        return [p.items[p.cursor]]
    }

    // MARK: Copy / move (F5, F6)

    private func targetName(_ it: Item, from: Location, to: Location) -> String {
        switch (from, to) {
        case (.mac, .image(let u, _)):
            let base = TypeSuffix.parse(it.name).name
            return (try? session(u).volume.legalName(base)) ?? base
        case (.image, .image(let u, _)):
            return (try? session(u).volume.legalName(it.name)) ?? it.name
        case (.image, .mac):
            return it.kind == .folder ? Commander.macName(it.name)
                : TypeSuffix.make(name: Commander.macName(it.name), type: it.fileType, aux: it.auxType)
        default:
            return it.name
        }
    }

    private func exists(_ name: String, in loc: Location) -> Bool {
        switch loc {
        case .mac(let u): return fm.fileExists(atPath: u.appendingPathComponent(name).path)
        case .image(let u, let p): return ((try? session(u).volume.lookup(p, name)) ?? nil) != nil
        }
    }

    func copy(move: Bool = false) {
        let src = active, dst = 1 - active
        let items = selection(src)
        guard !items.isEmpty else { return }
        let from = panels[src].location, to = panels[dst].location
        guard from != to else { alert = "Source and destination are the same."; return }
        let existing = items.filter { exists(targetName($0, from: from, to: to), in: to) }.count
        let verb = move ? "Move" : "Copy"
        let run: (Bool) -> Void = { [weak self] overwrite in
            self?.performCopy(items, from: from, to: to, overwrite: overwrite, move: move)
        }
        var alt: (label: String, action: () -> Void)?
        if move && items.count == 1 { alt = ("Rename…", { [weak self] in self?.rename() }) }
        dialog = .confirm(title: verb, message: "\(verb) \(items.count) item(s) to\n\(title(to))", ok: verb, action: { [weak self] in
            if existing == 0 { run(false) } else { self?.dialog = .overwrite(count: existing, action: run) }
        }, alt: alt)
    }

    private func performCopy(_ items: [Item], from: Location, to: Location, overwrite: Bool, move: Bool) {
        var errors: [String] = []
        var touched = Set<URL>()
        for it in items {
            do {
                try copyOne(it, from: from, to: to, overwrite: overwrite, touched: &touched)
                if move { try deleteOne(it, at: from, touched: &touched) }
            } catch {
                errors.append("\(it.name): \(error.localizedDescription)")
            }
        }
        saveAll(touched, &errors)
        panels[active].tagged = []
        reloadAll()
        if !errors.isEmpty { alert = errors.prefix(10).joined(separator: "\n") }
    }

    private func saveAll(_ touched: Set<URL>, _ errors: inout [String]) {
        for u in touched {
            do { try sessions[u]?.volume.save() } catch { errors.append("\(u.lastPathComponent): \(error.localizedDescription)") }
        }
    }

    private func copyOne(_ it: Item, from: Location, to: Location, overwrite: Bool, touched: inout Set<URL>) throws {
        switch (from, to) {
        case (.mac(let s), .mac(let d)):
            let src = s.appendingPathComponent(it.name), dst = d.appendingPathComponent(it.name)
            if fm.fileExists(atPath: dst.path) {
                guard overwrite else { return }
                try fm.removeItem(at: dst)
            }
            try fm.copyItem(at: src, to: dst)
        case (.mac(let s), .image(let u, let p)):
            try importMac(s.appendingPathComponent(it.name), into: u, path: p, overwrite: overwrite, touched: &touched)
        case (.image(let u, let p), .mac(let d)):
            try exportImage(u, p, it.name, to: d, overwrite: overwrite)
        case (.image(let su, let sp), .image(let du, let dp)):
            if su == du, dp.count > sp.count, Array(dp.prefix(sp.count + 1)).map({ $0.uppercased() }) == (sp + [it.name]).map({ $0.uppercased() }) {
                throw ProDOSError.unsupported("copying a directory into itself")
            }
            try copyImageToImage(su, sp, it.name, du, dp, overwrite: overwrite, touched: &touched)
        }
    }

    private func importMac(_ url: URL, into u: URL, path p: [String], overwrite: Bool, touched: inout Set<URL>) throws {
        let vol = try session(u).volume
        touched.insert(u.standardizedFileURL)
        var isDir: ObjCBool = false
        _ = fm.fileExists(atPath: url.path, isDirectory: &isDir)
        let parsed = TypeSuffix.parse(url.lastPathComponent)
        let name = vol.legalName(parsed.name)
        if isDir.boolValue {
            guard vol.supportsDirectories else { throw ProDOSError.unsupported("\(vol.formatName) disks have no directories") }
            if try vol.lookup(p, name) == nil { try vol.makeDirectory(p, name: name) }
            for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                try importMac(child, into: u, path: p + [name], overwrite: overwrite, touched: &touched)
            }
            return
        }
        if try vol.lookup(p, name) != nil && !overwrite { return }
        let data = try Data(contentsOf: url)
        let guess = ProDOSFileType.guess(fromExtension: (parsed.name as NSString).pathExtension)
        let type = parsed.type ?? guess.type
        let aux = parsed.aux ?? guess.aux
        var payload = data
        if parsed.type == nil && type == 0x04 {
            payload = Data(data.map { $0 == 0x0A ? 0x0D : $0 })          // Mac LF -> Apple II CR
        }
        let mod: (Int, Int)? = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate.map { d -> (Int, Int) in
                let e = ProDOSDate.encode(d)
                return (e.date, e.time)
            }
        try vol.write(p, name: name, contents: FileContents(data: payload, fileType: type, auxType: aux, modified: mod),
                      overwrite: overwrite)
    }

    private func exportImage(_ u: URL, _ p: [String], _ name: String, to d: URL, overwrite: Bool) throws {
        let vol = try session(u).volume
        guard let e = try vol.lookup(p, name) else { throw ProDOSError.fileNotFound(name) }
        if e.isDirectory {
            let target = d.appendingPathComponent(Commander.macName(e.name))
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for c in try vol.list(p + [e.name]) {
                try exportImage(u, p + [e.name], c.name, to: target, overwrite: overwrite)
            }
            return
        }
        let target = d.appendingPathComponent(TypeSuffix.make(name: Commander.macName(e.name), type: e.fileType, aux: e.auxType))
        if fm.fileExists(atPath: target.path) {
            guard overwrite else { return }
            try fm.removeItem(at: target)
        }
        try vol.read(p, e.name).data.write(to: target)
        if let m = e.modified { try? fm.setAttributes([.modificationDate: m], ofItemAtPath: target.path) }
    }

    private func copyImageToImage(_ su: URL, _ sp: [String], _ name: String, _ du: URL, _ dp: [String],
                                  overwrite: Bool, touched: inout Set<URL>) throws {
        let sv = try session(su).volume
        let dv = try session(du).volume
        touched.insert(du.standardizedFileURL)
        guard let e = try sv.lookup(sp, name) else { throw ProDOSError.fileNotFound(name) }
        let dn = dv.legalName(e.name)
        if e.isDirectory {
            guard dv.supportsDirectories else { throw ProDOSError.unsupported("\(dv.formatName) disks have no directories") }
            if try dv.lookup(dp, dn) == nil { try dv.makeDirectory(dp, name: dn) }
            for c in try sv.list(sp + [e.name]) {
                try copyImageToImage(su, sp + [e.name], c.name, du, dp + [dn], overwrite: overwrite, touched: &touched)
            }
            return
        }
        if try dv.lookup(dp, dn) != nil && !overwrite { return }
        try dv.write(dp, name: dn, contents: sv.read(sp, e.name), overwrite: overwrite)
    }

    // MARK: Delete (F8)

    func delete() {
        let items = selection(active)
        guard !items.isEmpty else { return }
        let loc = panels[active].location
        var msg = "Delete \(items.count) item(s)"
        if case .mac = loc { msg += " (move to Trash)" }
        let locked = items.filter(\.locked).count
        if locked > 0 { msg += "\n\(locked) of them locked" }
        dialog = .confirm(title: "Delete", message: msg + "?", ok: "Delete", action: { [weak self] in
            guard let self else { return }
            var errors: [String] = []
            var touched = Set<URL>()
            for it in items {
                do { try self.deleteOne(it, at: loc, touched: &touched) }
                catch { errors.append("\(it.name): \(error.localizedDescription)") }
            }
            self.saveAll(touched, &errors)
            self.panels[self.active].tagged = []
            self.reloadAll()
            if !errors.isEmpty { self.alert = errors.prefix(10).joined(separator: "\n") }
        }, alt: nil)
    }

    private func deleteOne(_ it: Item, at loc: Location, touched: inout Set<URL>) throws {
        switch loc {
        case .mac(let u):
            let url = u.appendingPathComponent(it.name)
            if it.kind == .image { forget(url) }
            try fm.trashItem(at: url, resultingItemURL: nil)
        case .image(let u, let p):
            let vol = try session(u).volume
            touched.insert(u.standardizedFileURL)
            try deleteInImage(vol, p, it.name)
        }
    }

    private func deleteInImage(_ vol: DiskVolume, _ p: [String], _ name: String) throws {
        guard let e = try vol.lookup(p, name) else { throw ProDOSError.fileNotFound(name) }
        if e.isDirectory {
            for c in try vol.list(p + [e.name]) { try deleteInImage(vol, p + [e.name], c.name) }
        }
        try vol.remove(p, name: e.name)
    }

    /// Apple II names may contain characters a Mac file name can't.
    static func macName(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    // MARK: Rename (F6 -> Rename…), mkdir (F7), new image (F9)

    func rename() {
        guard let it = current, it.kind != .up else { return }
        let loc = panels[active].location
        dialog = .input(title: "Rename", prompt: "New name for \(it.name):", text: it.name) { [weak self] newName in
            guard let self, !newName.isEmpty, newName != it.name else { return }
            do {
                switch loc {
                case .mac(let u):
                    if it.kind == .image { self.forget(u.appendingPathComponent(it.name)) }
                    try self.fm.moveItem(at: u.appendingPathComponent(it.name), to: u.appendingPathComponent(newName))
                    self.reloadAll()
                    self.reload(self.active, select: newName)
                case .image(let u, let p):
                    let vol = try self.session(u).volume
                    try vol.renameFile(p, from: it.name, to: newName)
                    try vol.save()
                    self.reloadAll()
                    self.reload(self.active, select: newName.uppercased())
                }
            } catch {
                self.alert = error.localizedDescription
            }
        }
    }

    func makeDirectory() {
        let loc = panels[active].location
        dialog = .input(title: "Make directory", prompt: "Create the directory:", text: "") { [weak self] name in
            guard let self, !name.isEmpty else { return }
            do {
                switch loc {
                case .mac(let u):
                    try self.fm.createDirectory(at: u.appendingPathComponent(name), withIntermediateDirectories: false)
                    self.reloadAll()
                    self.reload(self.active, select: name)
                case .image(let u, let p):
                    let vol = try self.session(u).volume
                    try vol.makeDirectory(p, name: name)
                    try vol.save()
                    self.reloadAll()
                    self.reload(self.active, select: name.uppercased())
                }
            } catch {
                self.alert = error.localizedDescription
            }
        }
    }

    func newImage() {
        guard case .mac(let folder) = panels[active].location else {
            alert = "New images are created in a Mac folder – go up out of the image first."
            return
        }
        dialog = .newImage { [weak self] name, blocks in
            guard let self else { return }
            do {
                let url: URL
                let data: Data
                if blocks < 0 {                                   // DOS 3.3 data disk
                    let fname = Commander.macName(name.isEmpty ? "NEWDISK" : name)
                    url = folder.appendingPathComponent(fname + ".dsk")
                    data = DOS33Volume.blankImage()
                } else {
                    let vname = try ProDOSVolume.validName(name)
                    url = folder.appendingPathComponent(vname + ".po")
                    data = try ProDOSVolume.blankImage(volumeName: vname, blocks: blocks)
                }
                guard !self.fm.fileExists(atPath: url.path) else { throw ProDOSError.duplicateName(url.lastPathComponent) }
                try data.write(to: url)
                self.reloadAll()
                self.reload(self.active, select: url.lastPathComponent)
            } catch {
                self.alert = error.localizedDescription
            }
        }
    }

    // MARK: Make bootable

    /// Copies boot blocks, PRODOS and (if missing) a .SYSTEM program from the
    /// bootable ProDOS disk in the other panel to the disk in the active panel.
    func makeBootable() {
        guard case .image(let tu, _) = panels[active].location,
              let target = try? session(tu).volume as? ProDOSVolume else {
            alert = "Open the ProDOS disk image you want to make bootable in the active panel first."
            return
        }
        guard case .image(let su, _) = panels[1 - active].location,
              let source = try? session(su).volume as? ProDOSVolume, source.hasBootBlocks,
              (try? source.entry([], "PRODOS")) ?? nil != nil else {
            alert = "Open a bootable ProDOS disk (with PRODOS on it, e.g. the ProDOS 2.4.3 disk) in the other panel."
            return
        }
        guard su != tu else { alert = "Choose two different disk images."; return }
        let sourceSystem = (try? source.firstSystemFile()) ?? nil
        let targetSystem = (try? target.firstSystemFile()) ?? nil
        var steps = "• boot blocks (0 and 1)\n• PRODOS"
        if targetSystem == nil, let s = sourceSystem { steps += "\n• \(s)" }
        dialog = .confirm(title: "Make Bootable",
                          message: "Copy to \(target.volumeName) from \(source.volumeName):\n\(steps)",
                          ok: "Make Bootable", action: { [weak self] in
            guard let self else { return }
            do {
                try target.copyBootBlocks(from: source)
                try target.write([], name: "PRODOS", contents: source.read([], "PRODOS"), overwrite: true)
                var system = targetSystem
                if system == nil, let s = sourceSystem {
                    try target.write([], name: s, contents: source.read([], s), overwrite: true)
                    system = s
                }
                try target.save()
                self.reloadAll()
                var text = "\(target.volumeName) is now bootable."
                if let system { text += "\nProDOS will start \(system)." }
                else { text += "\nCopy a .SYSTEM program (e.g. BASIC.SYSTEM) onto it so ProDOS has something to run." }
                self.dialog = .message(title: "Make Bootable", text: text)
            } catch {
                self.reloadAll()
                self.alert = error.localizedDescription
            }
        }, alt: nil)
    }

    // MARK: View (F3)

    func view() {
        guard let it = current, it.kind == .file || it.kind == .image else { return }
        do {
            let data: Data
            switch panels[active].location {
            case .mac(let u):
                let h = try FileHandle(forReadingFrom: u.appendingPathComponent(it.name))
                data = h.readData(ofLength: 256 * 1024)
                try? h.close()
            case .image(let u, let p):
                data = try session(u).volume.read(p, it.name).data
            }
            dialog = .view(title: it.name, text: Commander.render(data, appleText: it.fileType == 0x04))
        } catch {
            alert = error.localizedDescription
        }
    }

    /// Text if it looks like text (high bit stripped, CR -> newline), otherwise a hex dump.
    static func render(_ data: Data, appleText: Bool) -> String {
        let sample = data.prefix(4096)
        let printable = sample.filter { b in let c = b & 0x7F; return c >= 0x20 || c == 0x0D || c == 0x0A || c == 0x09 }.count
        if appleText || (sample.isEmpty == false && printable * 100 / sample.count >= 90) {
            let chars = data.prefix(256 * 1024).map { b -> Character in
                let c = b & 0x7F
                if c == 0x0D || c == 0x0A { return "\n" }
                if c == 0x09 { return "\t" }
                return c >= 0x20 && c < 0x7F ? Character(UnicodeScalar(c)) : "."
            }
            return String(chars)
        }
        var lines: [String] = []
        let bytes = [UInt8](data.prefix(64 * 1024))
        var o = 0
        while o < bytes.count {
            let row = bytes[o..<min(o + 16, bytes.count)]
            let hex = row.map { String(format: "%02X", $0) }.joined(separator: " ")
            let asc = String(row.map { b -> Character in let c = b & 0x7F; return c >= 0x20 && c < 0x7F ? Character(UnicodeScalar(c)) : "." })
            lines.append(String(format: "%06X  ", o) + hex.padding(toLength: 48, withPad: " ", startingAt: 0) + "  " + asc)
            o += 16
        }
        if data.count > bytes.count { lines.append("… (\(data.count) bytes, first 64K shown)") }
        return lines.joined(separator: "\n")
    }

    // MARK: Keyboard

    /// Returns true when the key was handled.
    func handle(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return false }
        if flags.contains(.control) {
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "r"?: reread(); return true
            case "u"?: panels.swapAt(0, 1); return true
            default: return false
            }
        }
        switch e.keyCode {
        case 126: move(-1)
        case 125: move(1)
        case 116, 123: move(-20)
        case 121, 124: move(20)
        case 115: move(-100_000)
        case 119: move(100_000)
        case 48: active = 1 - active
        case 36, 76: enter()
        case 51, 53: goUp()
        case 49: toggleTag()
        case 122: dialog = .help
        case 99: view()
        case 96: copy()
        case 97: copy(move: true)
        case 98: makeDirectory()
        case 100: delete()
        case 101: newImage()
        case 109: NSApp.terminate(nil)
        default:
            guard let ch = e.charactersIgnoringModifiers, ch.count == 1 else { return false }
            switch ch {
            case "1": dialog = .help
            case "3": view()
            case "5": copy()
            case "6": copy(move: true)
            case "7": makeDirectory()
            case "8": delete()
            case "9": newImage()
            case "0": NSApp.terminate(nil)
            case "+": tagAll(1)
            case "-": tagAll(0)
            case "*": tagAll(2)
            default:
                guard ch.first!.isLetter || ch.first!.isNumber || ch == "." else { return false }
                quickSearch(ch)
            }
        }
        return true
    }
}
