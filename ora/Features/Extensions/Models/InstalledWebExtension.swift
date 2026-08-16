import Foundation

struct InstalledWebExtension: Codable, Equatable, Identifiable {
    enum Source: String, Codable {
        case chromeWebStore
        case local
    }

    let id: UUID
    let runtimeIdentifier: String
    let chromeExtensionID: String?
    let name: String
    let version: String
    let manifestVersion: Double
    let resourceRelativePath: String
    let source: Source
    let installedAt: Date
    var disabledSpaceIDs: Set<UUID>

    func isEnabled(in spaceID: UUID) -> Bool {
        !disabledSpaceIDs.contains(spaceID)
    }
}
