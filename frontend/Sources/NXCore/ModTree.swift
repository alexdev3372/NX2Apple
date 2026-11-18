import Foundation
import Darwin

/// Copy bytes, not links, executable permissions, extended attributes or resource forks. Directory descriptors keep
/// both the walk and the writes anchored even if a folder is renamed while being read.
enum ModTree {
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    private static let limitEntries = 200_000
    private static let limitDepth = 64
    private static let limitBytes: Int64 = 32 * 1024 * 1024 * 1024
    private static let packageExtensions: Set<String> = ["app", "zip", "rar", "7z", "tar", "nsp", "xci", "nsz", "xcz"]
    private static let patchExtensions: Set<String> = ["dylib", "so", "dll", "exe", "sh", "command", "nso", "npdm", "kip", "ips", "ips32", "pchtxt"]

    static func metadata(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._") || name == "__MACOSX"
    }

    static func notLooseData(_ name: String) -> Bool {
        let lower = name.lowercased()
        return codePatch(lower) || lower.hasSuffix(".tar.gz") || packageExtensions.contains((lower as NSString).pathExtension)
    }

    private static func codePatch(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "exefs" || lower == "exefs_patches" || lower == "kip_patches" ||
            patchExtensions.contains((lower as NSString).pathExtension)
    }

    static func process(_ source: Directory, into copy: Directory?) throws {
        var bytes = limitBytes
        var entries = limitEntries
        var files = 0
        var buffer = copy == nil ? [] : [UInt8](repeating: 0, count: 256 * 1024)
        func visit(_ source: Directory, _ copy: Directory?, depth: Int) throws {
            guard depth <= limitDepth else { throw ModDirectory.Failure.tooLarge }
            for name in try source.names() {
                entries -= 1
                guard entries >= 0 else { throw ModDirectory.Failure.tooLarge }
                guard let kind = try source.kind(name) else { throw ModDirectory.Failure.stale }
                if metadata(name), copy != nil { continue }
                guard name.rangeOfCharacter(from: .controlCharacters) == nil,
                      kind == S_IFDIR || kind == S_IFREG else { throw ModDirectory.Failure.unsafeItem }
                if codePatch(name) { throw ModDirectory.Failure.unsupportedLayout }
                if kind == S_IFDIR {
                    try visit(source.directory(name), copy?.makeDirectory(name), depth: depth + 1)
                } else {
                    let file = try source.regularFile(name)
                    defer { close(file) }
                    var info = stat()
                    guard fstat(file, &info) == 0 else { throw posix() }
                    guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw ModDirectory.Failure.unsafeItem }
                    guard info.st_size >= 0, info.st_size <= bytes else { throw ModDirectory.Failure.tooLarge }
                    bytes -= info.st_size
                    if !metadata(name) { files += 1 }
                    if let copy { try copy.copyBytes(from: file, name: name, size: info.st_size, buffer: &buffer) }
                }
            }
        }
        try visit(source, copy, depth: 0)
        guard files > 0 else { throw ModDirectory.Failure.unsupportedLayout }
    }

    struct Identity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let birth: Int
        let nanos: Int
    }

    final class Directory {
        private let fd: Int32
        private let components: [String]

        init(path: String) throws {
            fd = open(path, directoryFlags)
            guard fd >= 0 else { throw Self.openError() }
            components = []
        }

        private init(fd: Int32, components: [String]) {
            self.fd = fd
            self.components = components
        }

        deinit { close(fd) }

        func path(relativeTo directory: Directory) -> String {
            components.dropFirst(directory.components.count).map { "/" + $0 }.joined()
        }

        func actualPath() throws -> String {
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(fd, F_GETPATH, &path) == 0 else { throw ModTree.posix() }
            return String(cString: path)
        }

        func identity() throws -> Identity {
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw ModTree.posix() }
            return Identity(device: info.st_dev, inode: info.st_ino, birth: info.st_birthtimespec.tv_sec, nanos: info.st_birthtimespec.tv_nsec)
        }

        func directory(_ name: String, create: Bool = false) throws -> Directory {
            if create, mkdirat(fd, name, 0o700) != 0, errno != EEXIST { throw ModTree.posix() }
            let child = openat(fd, name, directoryFlags)
            guard child >= 0 else { throw Self.openError() }
            return Directory(fd: child, components: components + [name])
        }

        func directoryIfPresent(_ name: String) throws -> Directory? {
            guard try kind(name) != nil else { return nil }
            return try directory(name)
        }

        func makeDirectory(_ name: String) throws -> Directory {
            guard mkdirat(fd, name, 0o700) == 0 else { throw ModTree.posix() }
            do { return try directory(name) }
            catch { unlinkat(fd, name, AT_REMOVEDIR); throw error }
        }

        func names() throws -> [String] {
            let streamFD = openat(fd, ".", directoryFlags) // independent directory offset for each read
            guard streamFD >= 0 else { throw ModTree.posix() }
            guard let stream = fdopendir(streamFD) else {
                let error = ModTree.posix()
                close(streamFD)
                throw error
            }
            defer { closedir(stream) }
            var names: [String] = []
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 { throw ModTree.posix() }
                    return names
                }
                let name = withUnsafeBytes(of: &entry.pointee.d_name) {
                    String(bytes: $0.prefix(Int(entry.pointee.d_namlen)), encoding: .utf8)
                }
                guard let name else { throw ModDirectory.Failure.unsafeItem }
                if name != ".", name != ".." { names.append(name) }
                guard names.count <= limitEntries else { throw ModDirectory.Failure.tooLarge }
            }
        }

        func kind(_ name: String) throws -> mode_t? {
            var info = stat()
            if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { return nil }
                throw ModTree.posix()
            }
            return info.st_mode & S_IFMT
        }

        func regularFile(_ name: String) throws -> Int32 {
            let file = openat(fd, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard file >= 0 else { throw Self.openError() }
            return file
        }

        func copyBytes(from file: Int32, name: String, size: Int64, buffer: inout [UInt8]) throws {
            let destination = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard destination >= 0 else { throw ModTree.posix() }
            defer { close(destination) }
            var remaining = size
            while remaining > 0 {
                let limit = min(buffer.count, Int(remaining))
                let count = buffer.withUnsafeMutableBytes { read(file, $0.baseAddress, limit) }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw ModTree.posix() }
                guard count > 0 else { throw ModDirectory.Failure.stale }
                try buffer.withUnsafeBytes { data in
                    var sent = 0
                    while sent < count {
                        let written = write(destination, data.baseAddress!.advanced(by: sent), count - sent)
                        if written < 0, errno == EINTR { continue }
                        guard written > 0 else { throw ModTree.posix() }
                        sent += written
                    }
                }
                remaining -= Int64(count)
            }
            var current = stat()
            guard fstat(file, &current) == 0 else { throw ModTree.posix() }
            guard current.st_size == size else { throw ModDirectory.Failure.stale }
        }

        func move(_ name: String, to target: Directory, as newName: String) throws {
            guard renameatx_np(fd, name, target.fd, newName, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw ModDirectory.Failure.duplicate }
                throw ModTree.posix()
            }
        }

        /// Only used for our staging copy. Never follow a link while cleaning it up.
        func removeTree(_ name: String) {
            guard let child = try? directory(name), let names = try? child.names() else { return }
            for item in names {
                let kind = try? child.kind(item)
                if kind == S_IFDIR { child.removeTree(item) }
                else { unlinkat(child.fd, item, 0) }
            }
            unlinkat(fd, name, AT_REMOVEDIR)
        }

        private static func openError() -> Error {
            errno == ELOOP || errno == ENOTDIR ? ModDirectory.Failure.unsafeItem : ModTree.posix()
        }
    }

    private static func posix() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
