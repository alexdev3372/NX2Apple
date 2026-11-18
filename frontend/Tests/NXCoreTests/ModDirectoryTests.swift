import Foundation
import XCTest
@testable import NXCore

final class ModDirectoryTests: XCTestCase {
    private let title = "01007EF00011E000"
    private let other = "010015100B514000"
    private let fm = FileManager.default
    private var temporary: URL!
    private var root: URL { temporary.appendingPathComponent("library") }
    private var mods: URL { root.appendingPathComponent("mods/\(title)") }

    override func setUpWithError() throws {
        temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try fm.removeItem(at: temporary) }

    @discardableResult private func put(_ path: String, _ content: String = "fixture") throws -> URL {
        let file = temporary.appendingPathComponent(path)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: file)
        return file
    }

    private func importFolder(_ name: String, titleID: String? = nil) throws -> String {
        try ModDirectory(root: root, titleID: titleID ?? title).importFolder(temporary.appendingPathComponent(name))
    }

    func testImportCopiesOnlyMatchingRomFSAndStartsDisabled() throws {
        let source = try put("Scenery/atmosphere/contents/\(title.lowercased())/romfs/Maps/a.bin")
        try put("Scenery/atmosphere/contents/\(title.lowercased())/exefs/main.npdm")
        try put("Scenery/atmosphere/contents/\(other)/romfs/Wrong.bin")
        XCTAssertEqual(try importFolder("Scenery"), "Scenery")
        let directory = ModDirectory(root: root, titleID: title)
        let listed = try XCTUnwrap(directory.list().first)
        XCTAssertEqual(listed.name, "Scenery")
        XCTAssertTrue(listed.parked)
        XCTAssertTrue(listed.usable)
        XCTAssertNil(listed.overlay)
        let copy = mods.appendingPathComponent(".disabled/Scenery/romfs/Maps/a.bin")
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: source))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: mods.appendingPathComponent(".disabled/Scenery").path), ["romfs"])
        XCTAssertTrue(ModDirectory(root: root, titleID: other).list().isEmpty)
    }

    func testLooseAndExplicitRomFSImport() throws {
        try put("Loose/Data/file.bin")
        try put("Wrapped/romfs/Data/file.bin")
        try put("Wrapped/romfs/Data/effect.elixir.gz", "compressed asset")
        try put("Loose/.DS_Store")
        for name in ["Loose", "Wrapped"] {
            XCTAssertEqual(try importFolder(name), name)
            let copy = mods.appendingPathComponent(".disabled/\(name)/romfs")
            XCTAssertTrue(fm.fileExists(atPath: copy.appendingPathComponent("Data/file.bin").path))
            XCTAssertFalse(fm.fileExists(atPath: copy.appendingPathComponent(".DS_Store").path))
        }
        let directory = ModDirectory(root: root, titleID: title)
        let wrapped = try XCTUnwrap(directory.list().first { $0.name == "Wrapped" })
        try directory.validateForEnable(wrapped)
        try directory.setEnabled(true, entry: wrapped) { true }
        XCTAssertEqual(directory.enabledEntries(["Wrapped"]).map(\.name), ["Wrapped"])
    }

    func testWrongTitleAndCodeAndEmptyFoldersDoNotFallBackToLoose() throws {
        for path in ["Wrong/contents/\(other)/romfs/file.bin", "Wrong/README.txt", "Executable/exefs/main.npdm",
                     "Executable/README.txt", "Patch/only.ips", "Empty/romfs/.DS_Store", "BadRomfs/romfs"] { try put(path) }
        for name in ["Wrong", "Wrong/contents/\(other)/romfs", "Executable", "Patch", "Empty", "BadRomfs"] {
            XCTAssertThrowsError(try importFolder(name), name)
        }
        XCTAssertTrue(ModDirectory(root: root, titleID: title).list().isEmpty)
    }

    func testDoesNotFollowLinksOrPublishPartialCopy() throws {
        let outside = try put("Outside/data.bin", "keep")
        let first = try put("Bad/romfs/normal.bin")
        try fm.createSymbolicLink(at: first.deletingLastPathComponent().appendingPathComponent("unsafe.bin"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: temporary.appendingPathComponent("Alias"), withDestinationURL: outside.deletingLastPathComponent())
        for name in ["Bad", "Alias"] {
            XCTAssertThrowsError(try importFolder(name)) { XCTAssertEqual($0 as? ModDirectory.Failure, .unsafeItem) }
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: mods.appendingPathComponent(".disabled").path), [])
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")
    }

    func testUnsafeDestinationAndSourcePathsDoNotWrite() throws {
        try put("Pack/file.bin")
        try put("Bad:Name/file.bin")
        XCTAssertThrowsError(try importFolder("Bad:Name"))
        XCTAssertThrowsError(try importFolder("Pack", titleID: "../../escape"))
        XCTAssertThrowsError(try importFolder("library"))
        let outside = try put("Outside/keep.bin").deletingLastPathComponent()
        try fm.createSymbolicLink(at: root.appendingPathComponent("mods"), withDestinationURL: outside)
        XCTAssertThrowsError(try importFolder("Pack"))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: outside.path), ["keep.bin"])
    }

    func testDuplicateNamesNeverReplaceActiveOrDisabledFiles() throws {
        try put("Pack/file.bin", "new")
        let active = try put("library/mods/\(title)/PACK/romfs/file.bin", "active")
        XCTAssertThrowsError(try importFolder("Pack")) { XCTAssertEqual($0 as? ModDirectory.Failure, .duplicate) }
        XCTAssertEqual(try String(contentsOf: active, encoding: .utf8), "active")
        try fm.removeItem(at: mods.appendingPathComponent("PACK"))
        try put("library/mods/\(title)/.disabled/Pack/romfs/file.bin", "disabled")
        XCTAssertThrowsError(try importFolder("Pack")) { XCTAssertEqual($0 as? ModDirectory.Failure, .duplicate) }
        let existing = mods.appendingPathComponent(".disabled/Pack/romfs/file.bin")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "disabled")
    }

    func testMoveAndRollBackWhenPreferenceSaveFails() throws {
        try put("Pack/file.bin")
        let directory = ModDirectory(root: root, titleID: title)
        try importFolder("Pack")
        let parked = try XCTUnwrap(directory.list().first)
        XCTAssertThrowsError(try directory.setEnabled(true, entry: parked, persist: { false })) {
            XCTAssertEqual($0 as? ModDirectory.Failure, .persistence)
        }
        XCTAssertEqual(directory.list(), [parked])
        try directory.setEnabled(true, entry: parked, persist: { true })
        let active = try XCTUnwrap(directory.list().first)
        XCTAssertFalse(active.parked)
        XCTAssertTrue(directory.enabledEntries([]).isEmpty)
        XCTAssertEqual(directory.enabledEntries(["Pack"]), [active])
        try directory.setEnabled(false, entry: active, persist: { true })
        XCTAssertEqual(directory.list(), [parked])
        XCTAssertTrue(directory.enabledEntries(["Pack"]).isEmpty, "a stale opt-in cannot enable a parked folder")
    }

    func testMoveCollisionAndUnsafeManuallyAddedPayloadAreNotLaunched() throws {
        let outside = try put("Outside/secret.bin")
        let initial = try put("library/mods/\(title)/Pack/romfs/data.bin", "active")
        let directory = ModDirectory(root: root, titleID: title)
        let active = try XCTUnwrap(directory.list().first)
        let parked = try put("library/mods/\(title)/.disabled/Pack/romfs/data.bin", "disabled")
        XCTAssertThrowsError(try directory.setEnabled(false, entry: active) { XCTFail("must not persist"); return true }) {
            XCTAssertEqual($0 as? ModDirectory.Failure, .duplicate)
        }
        XCTAssertEqual(try String(contentsOf: initial, encoding: .utf8), "active")
        XCTAssertEqual(try String(contentsOf: parked, encoding: .utf8), "disabled")
        try fm.createSymbolicLink(at: initial.deletingLastPathComponent().appendingPathComponent("secret.bin"), withDestinationURL: outside)
        XCTAssertTrue(directory.enabledEntries(["Pack"]).isEmpty)
    }

    func testStaleToggleDoesNotMoveReplacementWithSameName() throws {
        try put("library/mods/\(title)/Pack/romfs/data.bin")
        let directory = ModDirectory(root: root, titleID: title)
        let old = try XCTUnwrap(directory.list().first)
        try fm.moveItem(at: mods.appendingPathComponent("Pack"), to: temporary.appendingPathComponent("Original"))
        let replacement = try put("library/mods/\(title)/Pack/romfs/other.bin", "replacement")
        XCTAssertThrowsError(try directory.setEnabled(false, entry: old) { XCTFail("must not persist"); return true }) {
            XCTAssertEqual($0 as? ModDirectory.Failure, .stale)
        }
        XCTAssertEqual(try String(contentsOf: replacement, encoding: .utf8), "replacement")
    }
}
