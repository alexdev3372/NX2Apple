import Darwin
import Foundation

/// A game's mods (#557): folders in `Documents/games/<title ID>/mods/`, each holding RomFS files that replace the game's own
/// (`DM_ROMFS_OVERLAY`, `hle_fs.c`). The layout is the Mac launcher's `GameMod` (`mods/<title ID>/<mod>`): the files are in
/// `<mod>/romfs`, in an Atmosphere layout (`<mod>/atmosphere/contents/<title ID>/romfs`, `<mod>/contents/<title ID>/romfs`)
/// or in the folder itself. A mod with only `exefs/` changes the game's code, which the rewriter does not take, so it is
/// skipped. A name that starts with a dot is skipped too. The folder belongs to one game, so a mod never reaches another one.
public enum GameMods {
    /// The RomFS folder of each usable mod, in name order (Finder order).
    public static func romfsFolders(in mods: URL, titleID: String, _ fm: FileManager = .default) -> [String] {
        entries(in: mods, titleID: titleID, fm).map(\.path)
    }

    static func entries(in mods: URL, titleID: String, _ fm: FileManager = .default) -> [(name: String, path: String)] {
        guard GameModStore.validTitle(titleID), !mods.path.contains(":"),
              isDirectory(mods), isDirectory(mods.deletingLastPathComponent()) else { return [] }
        let names = ((try? fm.contentsOfDirectory(atPath: mods.path)) ?? []).filter(GameModStore.safeName).sorted {
            let order = $0.localizedStandardCompare($1)
            return order == .orderedSame ? $0.utf8.lexicographicallyPrecedes($1.utf8) : order == .orderedAscending
        }
        return names.compactMap { name in
            let mod = mods.appendingPathComponent(name)
            guard isDirectory(mod) else { return nil }
            let candidates = [["romfs"], ["atmosphere", "contents", titleID, "romfs"], ["contents", titleID, "romfs"]]
            for components in candidates {
                if let folder = components.reduce(Optional(mod), { parent, component in
                    guard let child = parent?.appendingPathComponent(component), isDirectory(child) else { return nil }
                    return child
                }) { return (name, folder.path) }
            }
            let top = ((try? fm.contentsOfDirectory(atPath: mod.path)) ?? []).filter(GameModStore.safeName).map { $0.lowercased() }
            let wrappers = ["exefs", "atmosphere", "contents", "exefs_patches", "romfs_patches", "cheats"]
            // The loose legacy format can have other directories next to ExeFS. A broken explicit RomFS root must not
            // be reinterpreted as loose data, especially if it is a link.
            return top.contains("romfs") || top.allSatisfy(wrappers.contains) ? nil : (name, mod.path)
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// The `DM_ROMFS_OVERLAY` value for the usable mods, or nil when the folder is missing or holds none. Where two mods
    /// replace one file, the one first in name order wins (the host looks in the folders in order), as on the Mac.
    public static func overlay(in mods: URL, titleID: String, _ fm: FileManager = .default) -> String? {
        let folders = romfsFolders(in: mods, titleID: titleID, fm)
        return folders.isEmpty ? nil : folders.joined(separator: ":")
    }
}
