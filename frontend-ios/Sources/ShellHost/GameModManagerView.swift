import ShellUI
import SwiftUI

struct GameModManagerView: View {
    let game: GameTile
    let model: ShellHostModel
    @Environment(\.dismiss) private var dismiss
    @State private var mods: [GameModStore.Mod]?
    @State private var working = false
    @State private var failure: GameModStore.Failure?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(verbatim: game.title).font(.headline).accessibilityIdentifier("mods.game")
                    Button {
                        perform { try await model.importMod(for: game.id) }
                    } label: {
                        Label(hostText("Import folder from Files…"), systemImage: "folder.badge.plus")
                    }
                    .accessibilityIdentifier("mods.import")
                    .disabled(working || mods == nil)
                    if working || mods == nil { ProgressView() }
                } footer: {
                    Text(hostText("Unzip the mod in Files first. Choose a Switch RomFS asset folder, not a code patch or plugin."))
                }
                Section {
                    if let mods, mods.isEmpty {
                        Text(hostText("No asset mods installed.")).foregroundStyle(.secondary)
                            .accessibilityIdentifier("mods.empty")
                    }
                    ForEach(mods ?? []) { mod in
                        Toggle(isOn: Binding(get: { mod.enabled }, set: { enabled in
                            perform { try await model.modStore.setEnabled(enabled, mod: mod, for: game.id) }
                        })) {
                            Text(verbatim: mod.name)
                        }
                        .accessibilityIdentifier("mods.enabled." + mod.name)
                        .disabled(working)
                    }
                } footer: {
                    Text(hostText("Changes apply the next time you play. If enabled mods replace the same file, the first by name wins."))
                }
            }
            .navigationTitle(hostText("Asset mods"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(hostText("Done")) { dismiss() }
                        .accessibilityIdentifier("mods.done").disabled(working)
                }
            }
            .task { await reload() }
            .alert(hostText("Asset mods"), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button(hostText("OK")) { failure = nil }
            } message: { Text(failure?.message ?? "") }
        }
        .interactiveDismissDisabled(working)
        .preferredColorScheme(.dark)
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true
        Task {
            defer { working = false }
            do {
                try await operation()
                await reload()
            } catch {
                await reload()
                failure = error as? GameModStore.Failure ?? .io
            }
        }
    }

    private func reload() async {
        do { mods = try await model.modStore.mods(for: game.id) }
        catch {
            mods = []
            failure = error as? GameModStore.Failure ?? .io
        }
    }
}

private extension GameModStore.Failure {
    var message: String {
        switch self {
        case .unsupported: hostText("Choose an extracted folder with RomFS assets for this game. Code patches and plugins are not supported.")
        case .wrongTitle: hostText("The folder does not target only this game.")
        case .unsafe: hostText("This folder has an unsafe name, link or file type.")
        case .tooLarge: hostText("The folder is too large or too deeply nested to import.")
        case .collision: hostText("A mod with that name already exists. Rename the folder in Files and try again.")
        case .unavailable: hostText("The folder could not be opened. Check that it is available in Files and try again.")
        case .io: hostText("The mod could not be saved. Check the folder and available device storage, then try again.")
        }
    }
}
