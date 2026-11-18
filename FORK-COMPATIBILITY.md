# Apple builds and mods in this fork

This branch is based on NX2Apple **1.5.0-rc6** (`7541e9e2`) with its pinned nxnative engine (`94a0944755da1a443f42651bf7ee49ab24ed5ee5`). It carries the Skyrim 1.1.404 fixes in NX2Apple’s engine patch queue. The earlier `fix/skyrim-1.1.404` branch is the separate NX2Apple 1.4.0 backport. The two branches do not share a tested framework or shader-cache contract.

Use this branch’s paired launcher and engine to rebuild a game when you need a new engine repair. Existing game data and saves are not patches and should not be deleted to switch versions. Keep the same app identity for in-place iPhone and iPad updates. A source build or an engine compile check is not a physical-device gameplay test.

The dry bump to nxnative `c379a903f47dd6d8cbdc4b2b36e67e7bb8ebc250` found conflicts in the stock release candidate queue as well as in the Skyrim port. Do not treat this branch as compatible with arbitrary nxnative `main` snapshots or replace its pinned engine without resolving and retesting the queue.

## Add a mod or data-only fix

1. Extract the mod before importing it. Choose a Switch-compatible folder with `romfs/`, game-relative loose files, or the matching `atmosphere/contents/<title ID>/romfs/` or `contents/<title ID>/romfs/` layout.
2. On **macOS**, open the game’s **Mods** section and use **Import mod folder…**, then turn on the imported mod. On **iOS/iPadOS**, use the game’s **Mods → Manage asset mods… → Import folder from Files…**. The mobile importer initially enables the new copy. Check the switch before playing.
3. Close the game before changing mods and relaunch after a change. If more than one enabled mod replaces a file, the first match in name order wins. Test one mod at a time on a separate or backed-up save.

Imports stay per title and do not overwrite a same-name import, the original source folder, the base game image or saves. Disable an import to keep it without applying its files. Windows DLLs, SKSE, ENB, ReShade, executable or IPS patches, cheat files, outer archives and mods that require a separate loader are not handled by this importer. Skyrim plugin or archive activation still requires the game’s own compatible configuration. Engine fixes are maintained as reviewed source patches in `patches/`, not as downloadable code executed by the mod importer.
