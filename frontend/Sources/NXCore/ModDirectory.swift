import Foundation
import Darwin

/// One game's RomFS overlays. Filesystem state is separate from the launcher's existing opt-in list.
package struct ModDirectory: Sendable {
    package struct Entry: Identifiable, Equatable, Sendable {
        package let name: String
        package let parked: Bool
        package let usable: Bool
        package let overlay: String?
        package var id: String { (parked ? ".disabled/" : "") + name }
        fileprivate let identity: ModTree.Identity
    }

    package enum Failure: Error, Equatable {
        case invalidLocation, unsupportedLayout, unsafeItem, tooLarge, duplicate, stale, persistence, gameRunning
    }

    private static let disabled = ".disabled"
    private static let mutations = NSLock()
    private let root: URL
    private let titleID: String

    package init(root: URL, titleID: String) {
        self.root = root
        self.titleID = titleID
    }

    package var folder: URL { root.appendingPathComponent("mods").appendingPathComponent(titleID) }

    package func revealFolder() throws -> URL {
        _ = try openTitle(create: true)
        return folder
    }

    /// A bad entry does not hide the other entries. Deep validation is deferred until enabling or launching.
    package func list() -> [Entry] {
        guard let title = try? openTitle() else { return [] }
        var entries = entries(in: title, parked: false)
        if let parked = try? title.directory(Self.disabled) { entries += self.entries(in: parked, parked: true) }
        return entries.sorted(by: Self.precedes)
    }

    private static func precedes(_ lhs: Entry, _ rhs: Entry) -> Bool {
        let order = lhs.name.localizedStandardCompare(rhs.name)
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }

    /// Only opted-in, non-parked, validated paths, in the same order the UI lists them.
    package func enabledEntries(_ enabled: [String]) -> [Entry] {
        guard !enabled.isEmpty, let title = try? openTitle() else { return [] }
        let enabled = Set(enabled)
        return entries(in: title, parked: false, enabled: enabled).sorted(by: Self.precedes)
            .filter(\.usable)
    }

    /// Publish only a complete private copy, off by default. Never import from or into the source tree.
    package func importFolder(_ source: URL) throws -> String {
        let name = source.lastPathComponent
        guard source.isFileURL, Self.safeName(name), !ModTree.notLooseData(name), !source.path.contains("\0") else { throw Failure.invalidLocation }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let input = try ModTree.Directory(path: source.path)
        let library = try openRoot()
        let inputPath = try input.actualPath()
        let parentName = URL(fileURLWithPath: inputPath).deletingLastPathComponent().lastPathComponent
        if name.lowercased() == "romfs", Self.isTitleID(parentName), parentName.uppercased() != titleID.uppercased() {
            throw Failure.unsupportedLayout
        }
        let destination = try library.actualPath() + "/mods/" + titleID
        func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
        guard inputPath != "/", key(inputPath) != key(destination),
              !key(inputPath).hasPrefix(key(destination) + "/"),
              !key(destination).hasPrefix(key(inputPath) + "/") else { throw Failure.invalidLocation }
        let payload = try payload(in: input, selectedName: name)
        let title = try openTitle(in: library, create: true)
        let parked = try title.directory(Self.disabled, create: true)
        try Self.mutations.withLock { try ensureAvailable(name, in: [title, parked]) }

        let stagingName = ".import-" + UUID().uuidString
        let stage = try parked.makeDirectory(stagingName)
        defer { parked.removeTree(stagingName) }
        let copy = try stage.makeDirectory("romfs")
        try ModTree.process(payload, into: copy)
        try Self.mutations.withLock {
            try ensureAvailable(name, in: [title, parked])
            try parked.move(stagingName, to: parked, as: name)
        }
        return name
    }

    /// A swap is an exclusive rename. If storing the opt-in fails, move the same folder back without clobbering anything.
    package func setEnabled(_ on: Bool, entry: Entry, persist: () -> Bool) throws {
        try Self.mutations.withLock {
            guard Self.safeName(entry.name) else { throw Failure.invalidLocation }
            let title = try openTitle()
            let parked = try title.directoryIfPresent(Self.disabled)
            let from = entry.parked ? parked : title
            guard let from else { throw Failure.stale }
            let mod = try checkedEntry(entry, in: from)
            if on { _ = try payload(in: mod) }
            let shouldMove = entry.parked == on
            if !shouldMove {
                guard persist() else { throw Failure.persistence }
                return
            }
            let to = on ? title : try title.directory(Self.disabled, create: true)
            try ensureAvailable(entry.name, in: [to])
            try from.move(entry.name, to: to, as: entry.name)
            guard persist() else {
                try to.move(entry.name, to: from, as: entry.name)
                throw Failure.persistence
            }
        }
    }

    /// The caller runs the potentially large walk off the main actor before calling `setEnabled`.
    package func validateForEnable(_ entry: Entry) throws {
        let title = try openTitle()
        let from = entry.parked ? try title.directory(Self.disabled) : title
        try ModTree.process(payload(in: checkedEntry(entry, in: from)), into: nil)
    }

    private func checkedEntry(_ entry: Entry, in parent: ModTree.Directory) throws -> ModTree.Directory {
        guard Self.safeName(entry.name), (try parent.names()).contains(entry.name),
              let mod = try? parent.directory(entry.name), try mod.identity() == entry.identity else { throw Failure.stale }
        return mod
    }

    private func openRoot() throws -> ModTree.Directory {
        guard root.isFileURL, Self.isTitleID(titleID), !root.path.contains(":"), !root.path.contains("\0") else { throw Failure.invalidLocation }
        let library = try ModTree.Directory(path: root.standardizedFileURL.resolvingSymlinksInPath().path)
        guard !(try library.actualPath()).contains(":") else { throw Failure.invalidLocation }
        return library
    }

    private func openTitle(create: Bool = false) throws -> ModTree.Directory {
        try openTitle(in: openRoot(), create: create)
    }

    private func openTitle(in root: ModTree.Directory, create: Bool) throws -> ModTree.Directory {
        try root.directory("mods", create: create).directory(titleID, create: create)
    }

    private func entries(in parent: ModTree.Directory, parked: Bool, enabled: Set<String>? = nil) -> [Entry] {
        guard let names = try? parent.names() else { return [] }
        return names.filter(Self.safeName).compactMap { name in
            if let enabled, !enabled.contains(name) { return nil }
            guard let mod = try? parent.directory(name), let identity = try? mod.identity() else { return nil }
            let path = try? {
                let payload = try payload(in: mod)
                if enabled != nil { try ModTree.process(payload, into: nil) }
                return folder.appendingPathComponent(name + payload.path(relativeTo: mod)).path
            }()
            return Entry(name: name, parked: parked, usable: path != nil, overlay: parked ? nil : path, identity: identity)
        }
    }

    private func payload(in mod: ModTree.Directory, selectedName: String? = nil) throws -> ModTree.Directory {
        func child(_ name: String, in directory: ModTree.Directory) throws -> ModTree.Directory? {
            let matches = try directory.names().filter { $0.lowercased() == name.lowercased() }
            guard matches.count <= 1 else { throw Failure.unsupportedLayout }
            return try matches.first.map { try directory.directory($0) }
        }
        func wrapped(_ contents: ModTree.Directory) throws -> ModTree.Directory {
            guard let title = try child(titleID, in: contents), let data = try child("romfs", in: title) else {
                throw Failure.unsupportedLayout
            }
            return data
        }
        if let selectedName, Self.isTitleID(selectedName), selectedName.uppercased() != titleID.uppercased() {
            throw Failure.unsupportedLayout
        }
        if let overlay = try child("romfs", in: mod) { return overlay }
        if let atmosphere = try child("atmosphere", in: mod) {
            guard let contents = try child("contents", in: atmosphere) else { throw Failure.unsupportedLayout }
            return try wrapped(contents)
        }
        if let contents = try child("contents", in: mod) { return try wrapped(contents) }
        // Finder can select the contents or title folder itself, not just its parent package.
        if let selectedName {
            if selectedName.lowercased() == "contents" { return try wrapped(mod) }
            if Self.isTitleID(selectedName) { throw Failure.unsupportedLayout }
        }
        let top = try mod.names().filter { !ModTree.metadata($0) }
        guard !top.isEmpty, !top.contains(where: { Self.isTitleID($0) || $0.lowercased() == "exefs" }),
              top.contains(where: { !ModTree.notLooseData($0) }) else { throw Failure.unsupportedLayout }
        return mod
    }

    private func ensureAvailable(_ name: String, in dirs: [ModTree.Directory]) throws {
        func key(_ value: String) -> String { value.precomposedStringWithCanonicalMapping.lowercased() }
        for dir in dirs {
            if try dir.kind(name) != nil || dir.names().contains(where: { key($0) == key(name) }) { throw Failure.duplicate }
        }
    }

    private static func safeName(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix(".") && !s.contains("/") && !s.contains(":") &&
            s.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func isTitleID(_ s: String) -> Bool {
        s.utf8.count == 16 && s.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
}
