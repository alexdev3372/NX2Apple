import Darwin
import Foundation
import Testing
@testable import ShellHost

@Suite struct GameModStoreTests {
    @Test func copiesWrappedAssetsIntoTheSelectedTitlesOverlay() async throws {
        let box = try Sandbox()
        let game = try box.giveAppData()
        let source = box.root.appendingPathComponent("Textures")
        let payload = source.appendingPathComponent("atmosphere/contents/\(Fixtures.orbit)/romfs/Data/texture.bin")
        try box.write("asset", to: payload)
        try box.write("not imported", to: payload.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("exefs/main.nso"))
        try box.write("save", to: game.appendingPathComponent("save/checkpoint"))
        let store = GameModStore(appDataRoot: box.appData)
        try await store.install(source, for: Fixtures.orbit)
        let mods = game.appendingPathComponent("mods")
        let installed = mods.appendingPathComponent("Textures/romfs")
        #expect(try String(contentsOf: installed.appendingPathComponent("Data/texture.bin"), encoding: .utf8) == "asset")
        #expect(FileManager.default.fileExists(atPath: payload.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: mods.appendingPathComponent("Textures").path) == ["romfs"])
        #expect(GameMods.overlay(in: mods, titleID: Fixtures.orbit) == installed.path)
        #expect(GameMods.overlay(in: box.appData.appendingPathComponent("\(Fixtures.chain)/mods"), titleID: Fixtures.chain) == nil)
        #expect(try String(contentsOf: game.appendingPathComponent("save/checkpoint"), encoding: .utf8) == "save")
    }

    @Test func disableAndEnableRestoresLaunchOrderWithoutTouchingManualMods() async throws {
        let box = try Sandbox()
        let game = try box.giveAppData()
        let mods = game.appendingPathComponent("mods")
        let source = box.root.appendingPathComponent("Mod 2")
        try box.write("first", to: source.appendingPathComponent("Data/texture.bin"))
        try box.write("second", to: mods.appendingPathComponent("Mod 10/romfs/Data/texture.bin"))
        let store = GameModStore(appDataRoot: box.appData)
        try await store.install(source, for: Fixtures.orbit)
        let entry = try #require(GameCatalogue.scan(root: box.games).first { $0.id == Fixtures.orbit })
        let manifest = try #require(entry.manifest)
        let framework = try #require(entry.frameworkURL)
        let launched = LaunchableGame(titleID: Fixtures.orbit, name: entry.title, manifest: manifest,
                                      directory: entry.directory, frameworkURL: framework,
                                      dataURL: game, appFolder: game, environment: [:])
        func overlay() -> String? {
            EngineLaunchPlan.make(game: launched, appResources: box.root, documents: box.appData.deletingLastPathComponent(),
                                  envFileText: nil).environment["DM_ROMFS_OVERLAY"]
        }
        let first = mods.path + "/Mod 2/romfs", second = mods.path + "/Mod 10/romfs"
        #expect(overlay() == first + ":" + second)
        let installed = try await store.mods(for: Fixtures.orbit)
        let mod = try #require(installed.first)
        try await store.setEnabled(false, mod: mod, for: Fixtures.orbit)
        #expect(overlay() == second)
        let reopened = GameModStore(appDataRoot: box.appData)
        let persisted = try await reopened.mods(for: Fixtures.orbit)
        let disabled = try #require(persisted.first { !$0.enabled })
        #expect(disabled.name == "Mod 2")
        await #expect(throws: GameModStore.Failure.collision) { try await reopened.install(source, for: Fixtures.orbit) }

        let conflict = mods.appendingPathComponent("Mod 2/romfs/Data/texture.bin")
        try box.write("manual", to: conflict)
        await #expect(throws: GameModStore.Failure.collision) { try await reopened.setEnabled(true, mod: disabled, for: Fixtures.orbit) }
        #expect(try String(contentsOf: conflict, encoding: .utf8) == "manual")
        try FileManager.default.removeItem(at: mods.appendingPathComponent("Mod 2"))
        try await reopened.setEnabled(true, mod: disabled, for: Fixtures.orbit)
        #expect(overlay() == first + ":" + second)
    }

    @Test(arguments: ["symlink", "hardlink", "fifo", "code", "renamed-code", "byte-limit", "entry-limit", "depth-limit"])
    func rejectedPayloadNeverPublishesOrLeavesStaging(kind: String) async throws {
        let box = try Sandbox()
        let src = box.root.appendingPathComponent("Synthetic")
        let mods = try box.giveAppData().appendingPathComponent("mods")
        try box.write("original", to: mods.appendingPathComponent("Keep/romfs/data"))
        try box.write("assets", to: src.appendingPathComponent("romfs/data"))
        let path = src.appendingPathComponent("romfs/extra")
        let outside = box.root.appendingPathComponent("outside")
        try box.write("untouched", to: outside)
        var limits = GameModStore.Limits()
        let rejection: GameModStore.Failure
        switch kind {
        case "symlink":
            try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside)
            rejection = .unsafe
        case "hardlink":
            try FileManager.default.linkItem(at: outside, to: path)
            rejection = .unsafe
        case "fifo":
            try #require(mkfifo(path.path, 0o600) == 0)
            rejection = .unsafe
        case "code":
            try box.write("code", to: path.appendingPathExtension("ips"))
            rejection = .unsupported
        case "renamed-code":
            try Data([0x7f, 0x45, 0x4c, 0x46]).write(to: path)
            rejection = .unsupported
        case "byte-limit":
            limits.bytes = 5
            rejection = .tooLarge
        case "entry-limit":
            limits.entries = 1
            rejection = .tooLarge
        default:
            limits.depth = 1
            try box.write("deep", to: path.appendingPathComponent("nested"))
            rejection = .tooLarge
        }
        let store = GameModStore(appDataRoot: box.appData, limits: limits)
        await #expect(throws: rejection) { try await store.install(src, for: Fixtures.orbit) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: mods.path) == ["Keep"])
        #expect(try String(contentsOf: outside, encoding: .utf8) == "untouched")
    }

    @Test func foreignTitlesCodeOnlyAndUnsafeDestinationAreRejected() async throws {
        let box = try Sandbox()
        let fm = FileManager.default
        let game = try box.giveAppData()
        let src = box.root.appendingPathComponent("Wrong")
        try box.write("assets", to: src.appendingPathComponent("contents/\(Fixtures.chain)/romfs/data"))
        let code = box.root.appendingPathComponent("Code")
        try box.write("code", to: code.appendingPathComponent("exefs/main.nso"))
        let store = GameModStore(appDataRoot: box.appData)
        await #expect(throws: GameModStore.Failure.wrongTitle) { try await store.install(src, for: Fixtures.orbit) }
        await #expect(throws: GameModStore.Failure.unsupported) { try await store.install(code, for: Fixtures.orbit) }
        await #expect(throws: GameModStore.Failure.unsafe) { try await store.install(src, for: "../bad-title-id!") }
        let colon = box.root.appendingPathComponent("Bad:Name")
        try box.write("asset", to: colon.appendingPathComponent("romfs/texture"))
        await #expect(throws: GameModStore.Failure.unsafe) { try await store.install(colon, for: Fixtures.orbit) }
        let good = box.root.appendingPathComponent("Good")
        try box.write("asset", to: good.appendingPathComponent("romfs/texture"))
        let outside = box.root.appendingPathComponent("External")
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        let mods = game.appendingPathComponent("mods")
        try fm.removeItem(at: mods)
        try fm.createSymbolicLink(at: mods, withDestinationURL: outside)
        await #expect(throws: GameModStore.Failure.unsafe) { try await store.install(good, for: Fixtures.orbit) }
        #expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
}
