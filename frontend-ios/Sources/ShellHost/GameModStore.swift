import Darwin
import Foundation

/// Owns Files imports and reversible moves. The engine only sees complete, enabled mods.
actor GameModStore {
    struct Mod: Identifiable, Equatable, Sendable {
        var name: String
        var enabled: Bool
        var id: String { (enabled ? "on/" : "off/") + name }
    }

    enum Failure: Error, Equatable {
        case unsupported, wrongTitle, unsafe, tooLarge, collision, unavailable, io
    }

    struct Limits: Sendable {
        var entries = 100_000
        var depth = 32
        var bytes: Int64 = 16 * 1024 * 1024 * 1024
    }

    static let disabledFolder = ".disabled"
    private let appDataRoot: URL
    private let limits: Limits

    init(appDataRoot: URL, limits: Limits = Limits()) {
        self.appDataRoot = appDataRoot
        self.limits = limits
    }

    func install(_ source: URL, for titleID: String) throws {
        guard source.isFileURL, Self.validTitle(titleID) else { throw Failure.unsafe }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [.withoutChanges], error: &coordinationError) { readable in
            result = Result { try copyMod(readable, named: source.lastPathComponent, titleID: titleID) }
        }
        if let result { try result.get() }
        else { throw Failure.io }
    }

    private func copyMod(_ source: URL, named name: String, titleID: String) throws {
        guard Self.safeName(name), !Self.reserved(name), !Self.codeFile(name) else { throw Failure.unsafe }
        if Self.validTitle(name), name.caseInsensitiveCompare(titleID) != .orderedSame { throw Failure.wrongTitle }
        let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
        let storePath = appDataRoot.resolvingSymlinksInPath().standardizedFileURL.path
        // Do not read a tree that our own staging directory could end up inside, or reimport app game data.
        guard sourcePath != storePath, !sourcePath.hasPrefix(storePath + "/"), !storePath.hasPrefix(sourcePath + "/") else {
            throw Failure.unsafe
        }
        let sourceFD = try Self.openDirectory(source.path, at: AT_FDCWD)
        defer { close(sourceFD) }
        var budget = Budget(limits: limits)

        let target = try openMods(titleID, create: true)
        defer { close(target.fd) }
        if let off = try Self.optionalDirectory(Self.disabledFolder, at: target.fd) {
            defer { close(off) }
            try Self.requireAbsent(name, at: off)
        }
        try Self.requireAbsent(name, at: target.fd)
        let stage = ".import-" + UUID().uuidString
        guard mkdirat(target.fd, stage, 0o700) == 0 else { throw Failure.io }
        var published = false
        defer { if !published { _ = removefileat(target.fd, stage, nil, UInt32(REMOVEFILE_RECURSIVE)) } }
        let stageFD = try Self.openDirectory(stage, at: target.fd)
        defer { close(stageFD) }
        let romfs = try Self.makeDirectory("romfs", at: stageFD)
        defer { close(romfs) }
        try copyPayload(sourceFD, to: romfs, titleID: titleID, budget: &budget)
        guard budget.files > 0 else { throw Failure.unsupported }
        try Task.checkCancellation()
        try Self.publish(stage, from: target.fd, as: name, to: target.fd)
        published = true
    }

    func mods(for titleID: String) throws -> [Mod] {
        guard Self.validTitle(titleID) else { throw Failure.unsafe }
        let target: (url: URL, fd: Int32)
        do { target = try openMods(titleID, create: false) }
        catch Failure.unavailable { return [] }
        defer { close(target.fd) }
        let enabled = GameMods.entries(in: target.url, titleID: titleID).map { Mod(name: $0.name, enabled: true) }
        guard let disabled = try Self.optionalDirectory(Self.disabledFolder, at: target.fd) else { return enabled }
        close(disabled)
        return enabled + GameMods.entries(in: target.url.appendingPathComponent(Self.disabledFolder), titleID: titleID)
            .map { Mod(name: $0.name, enabled: false) }
    }

    func setEnabled(_ enabled: Bool, mod: Mod, for titleID: String) throws {
        guard Self.safeName(mod.name), Self.validTitle(titleID) else { throw Failure.unsafe }
        guard enabled != mod.enabled else { return }
        let target = try openMods(titleID, create: false)
        defer { close(target.fd) }
        let off: Int32
        if enabled {
            off = try Self.openDirectory(Self.disabledFolder, at: target.fd)
        } else {
            off = try Self.makeDirectory(Self.disabledFolder, at: target.fd, existingOK: true)
        }
        defer { close(off) }
        let from = enabled ? off : target.fd
        let to = enabled ? target.fd : off
        let folder = enabled ? target.url.appendingPathComponent(Self.disabledFolder) : target.url
        guard GameMods.entries(in: folder, titleID: titleID).contains(where: { $0.name == mod.name }) else { throw Failure.unavailable }
        try Self.publish(mod.name, from: from, as: mod.name, to: to)
    }

    private func openMods(_ titleID: String, create: Bool) throws -> (url: URL, fd: Int32) {
        guard Self.validTitle(titleID), !appDataRoot.path.contains(":") else { throw Failure.unsafe }
        let parent = appDataRoot.deletingLastPathComponent()
        let root = try Self.openDirectory(parent.path, at: AT_FDCWD)
        defer { close(root) }
        func directory(_ name: String, at fd: Int32) throws -> Int32 {
            if create { return try Self.makeDirectory(name, at: fd, existingOK: true) }
            return try Self.openDirectory(name, at: fd)
        }
        let games = try directory(appDataRoot.lastPathComponent, at: root)
        defer { close(games) }
        let game = try directory(titleID, at: games)
        defer { close(game) }
        return (appDataRoot.appendingPathComponent(titleID).appendingPathComponent("mods"), try directory("mods", at: game))
    }

    private struct Budget {
        var limits: Limits
        var entries = 0
        var files = 0
        var bytes: Int64 = 0
    }

    /// Names come from the actual directory entries, never from an archive or a manifest path.
    private func names(in fd: Int32, budget: inout Budget) throws -> [String] {
        let duplicate = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard duplicate >= 0 else { throw Failure.io }
        guard let stream = fdopendir(duplicate) else { close(duplicate); throw Failure.io }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw Failure.io }
                return result
            }
            let count = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { String(bytes: $0.prefix(count), encoding: .utf8) }
            if name == "." || name == ".." { continue }
            budget.entries += 1
            guard budget.entries <= budget.limits.entries else { throw Failure.tooLarge }
            guard let name else { throw Failure.unsafe }
            if name.hasPrefix(".") { continue }
            guard Self.safeName(name) else { throw Failure.unsafe }
            result.append(name)
        }
    }

    private func copyPayload(_ source: Int32, to out: Int32, titleID: String, budget: inout Budget) throws {
        let top = try names(in: source, budget: &budget)
        func matching(_ name: String) -> [String] { top.filter { $0.lowercased() == name } }
        let direct = matching("romfs"), atmosphere = matching("atmosphere"), contents = matching("contents")
        guard direct.count + atmosphere.count + contents.count <= 1 else { throw Failure.unsupported }
        if let romfs = direct.first {
            try copyDirectory(romfs, at: source, into: out, budget: &budget)
        } else if let wrapper = (atmosphere + contents).first {
            let first = try Self.openDirectory(wrapper, at: source)
            defer { close(first) }
            let titles: Int32
            if atmosphere.isEmpty { titles = first }
            else {
                let wrappers = try names(in: first, budget: &budget).filter { $0.lowercased() == "contents" }
                guard wrappers.count == 1 else { throw Failure.unsupported }
                titles = try Self.openDirectory(wrappers[0], at: first)
            }
            defer { if titles != first { close(titles) } }
            let ids = try names(in: titles, budget: &budget)
            guard ids.count == 1, let id = ids.first, Self.validTitle(id), id.caseInsensitiveCompare(titleID) == .orderedSame else {
                throw Failure.wrongTitle
            }
            let title = try Self.openDirectory(id, at: titles)
            defer { close(title) }
            let payload = try names(in: title, budget: &budget).filter { $0.lowercased() == "romfs" }
            guard payload.count == 1 else { throw Failure.unsupported }
            try copyDirectory(payload[0], at: title, into: out, budget: &budget)
        } else {
            guard !top.contains(where: Self.reserved) else { throw Failure.unsupported }
            try copy(top, from: source, to: out, depth: 1, budget: &budget)
        }
    }

    private func copyDirectory(_ name: String, at parent: Int32, into out: Int32, budget: inout Budget) throws {
        let fd = try Self.openDirectory(name, at: parent)
        defer { close(fd) }
        try copy(names(in: fd, budget: &budget), from: fd, to: out, depth: 1, budget: &budget)
    }

    private func copy(_ names: [String], from input: Int32, to out: Int32, depth: Int, budget: inout Budget) throws {
        guard depth <= budget.limits.depth else { throw Failure.tooLarge }
        for name in names {
            try Task.checkCancellation()
            guard !Self.reserved(name), !Self.codeFile(name) else { throw Failure.unsupported }
            var info = stat()
            guard fstatat(input, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.io }
            let type = info.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFDIR else { throw Failure.unsafe }
            // Open without following links, then check the actual opened inode, not just the directory listing.
            let fd = openat(input, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (type == S_IFDIR ? O_DIRECTORY : 0))
            guard fd >= 0 else { throw Failure.unsafe }
            defer { close(fd) }
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == type else { throw Failure.unsafe }
            if type == S_IFDIR {
                let child = try Self.makeDirectory(name, at: out)
                defer { close(child) }
                try copy(self.names(in: fd, budget: &budget), from: fd, to: child, depth: depth + 1, budget: &budget)
            } else {
                guard info.st_nlink == 1, info.st_mode & 0o111 == 0 else { throw Failure.unsafe }
                try copyFile(name, from: fd, to: out, size: info.st_size, budget: &budget)
            }
        }
    }

    private func copyFile(_ name: String, from input: Int32, to out: Int32, size: Int64, budget: inout Budget) throws {
        guard size >= 0, size <= budget.limits.bytes - budget.bytes else { throw Failure.tooLarge }
        let dest = openat(out, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard dest >= 0 else { throw errno == EEXIST ? Failure.collision : Failure.io }
        defer { close(dest) }
        var bytes = [UInt8](repeating: 0, count: Int(min(256 * 1024, max(16, size))))
        var copied: Int64 = 0
        var header: [UInt8] = []
        while true {
            try Task.checkCancellation()
            let n = read(input, &bytes, bytes.count)
            if n < 0, errno == EINTR { continue }
            guard n >= 0 else { throw Failure.io }
            if n == 0 { break }
            guard Int64(n) <= size - copied else { throw Failure.io }
            if header.count < 16 {
                header.append(contentsOf: bytes.prefix(min(16 - header.count, n)))
                guard !Self.unsupportedHeader(header) else { throw Failure.unsupported }
            }
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < n {
                    let amount = write(dest, buffer.baseAddress!.advanced(by: offset), n - offset)
                    if amount < 0, errno == EINTR { continue }
                    guard amount > 0 else { throw Failure.io }
                    offset += amount
                }
            }
            copied += Int64(n)
        }
        guard copied == size else { throw Failure.io }
        budget.bytes += copied
        budget.files += 1
    }

    static func validTitle(_ id: String) -> Bool {
        id.utf8.count == 16 && id.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && !name.hasPrefix(".") &&
            !name.contains(where: { "/:\\".contains($0) }) && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func reserved(_ name: String) -> Bool {
        ["exefs", "exefs_patches", "romfs_patches", "atmosphere", "contents", "cheats"].contains(name.lowercased())
    }

    private static func codeFile(_ name: String) -> Bool {
        name.lowercased() == "romfs.img" ||
        ["zip", "7z", "rar", "ips", "ips32", "bps", "ups", "xdelta", "pchtxt", "nso", "nro", "nsp", "xci", "nca", "exe", "dll", "dylib", "so", "app", "framework",
         "sh", "bat", "cmd", "ps1", "skse", "pex", "lua", "py", "js", "asi", "plugin", "esp", "esm", "esl"].contains((name as NSString).pathExtension.lowercased())
    }

    /// Reject common renamed executables. This is not a validator for game-specific asset formats.
    private static func unsupportedHeader(_ bytes: [UInt8]) -> Bool {
        let prefix = bytes.prefix(4)
        if prefix.elementsEqual([0x7f, 0x45, 0x4c, 0x46]) || prefix.elementsEqual("NSO0".utf8) ||
            prefix.elementsEqual("PK\u{3}\u{4}".utf8) || bytes.dropFirst(16 - 4).prefix(4).elementsEqual("NRO0".utf8) {
            return true
        }
        return [[0xfe, 0xed, 0xfa, 0xce], [0xfe, 0xed, 0xfa, 0xcf], [0xce, 0xfa, 0xed, 0xfe],
                [0xcf, 0xfa, 0xed, 0xfe], [0xca, 0xfe, 0xba, 0xbe], [0xca, 0xfe, 0xba, 0xbf]]
            .contains { prefix.elementsEqual($0) }
    }

    private static func optionalDirectory(_ name: String, at parent: Int32) throws -> Int32? {
        do { return try openDirectory(name, at: parent) }
        catch Failure.unavailable { return nil }
    }

    private static func openDirectory(_ name: String, at parent: Int32) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 { return fd }
        switch errno {
        case ENOENT: throw Failure.unavailable
        case ELOOP, ENOTDIR: throw Failure.unsafe
        default: throw Failure.io
        }
    }

    private static func makeDirectory(_ name: String, at parent: Int32, existingOK: Bool = false) throws -> Int32 {
        if mkdirat(parent, name, 0o700) != 0, !(existingOK && errno == EEXIST) {
            throw errno == EEXIST ? Failure.collision : Failure.io
        }
        return try openDirectory(name, at: parent)
    }

    private static func requireAbsent(_ name: String, at parent: Int32) throws {
        var info = stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { throw Failure.collision }
        guard errno == ENOENT else { throw Failure.io }
    }

    private static func publish(_ name: String, from source: Int32, as newName: String, to dest: Int32) throws {
        guard renameatx_np(source, name, dest, newName, UInt32(RENAME_EXCL)) == 0 else {
            throw errno == EEXIST || errno == ENOTEMPTY ? Failure.collision : Failure.io
        }
    }
}
