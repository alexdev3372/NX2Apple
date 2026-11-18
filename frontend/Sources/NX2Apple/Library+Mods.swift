import Foundation
import NXCore

extension LibraryGame {
    func modDirectory(library: String) -> ModDirectory {
        let root = library.isEmpty
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NS Port Builder")
            : URL(fileURLWithPath: library)
        return ModDirectory(root: root, titleID: titleID)
    }
}

extension ModDirectory.Failure {
    var labelKey: String {
        switch self {
        case .invalidLocation: return "launch.modInvalidLocation"
        case .unsupportedLayout: return "launch.modUnsupported"
        case .unsafeItem: return "launch.modUnsafe"
        case .tooLarge: return "launch.modTooLarge"
        case .duplicate: return "launch.modDuplicate"
        case .stale: return "launch.modStale"
        case .persistence: return "launch.modPersistence"
        case .gameRunning: return "launch.modGameRunning"
        }
    }
}

func modErrorMessage(_ error: Error, t: (String) -> String) -> String {
    if let error = error as? ModDirectory.Failure { return t(error.labelKey) }
    return String(format: t("launch.modIOError"), error.localizedDescription)
}