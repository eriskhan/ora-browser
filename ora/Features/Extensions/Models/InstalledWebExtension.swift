import Foundation

struct InstalledWebExtension: Codable, Hashable, Identifiable {
    let id: UUID
    var runtimeIdentifier: String
    var name: String
    var version: String
    var manifestVersion: Double
    var resourceRelativePath: String
    var installedAt: Date
    var isEnabled: Bool
    var permissionDecisionMade: Bool
    var grantedPermissions: Set<String>
    var grantedMatchPatterns: Set<String>

    init(
        id: UUID,
        runtimeIdentifier: String,
        name: String,
        version: String,
        manifestVersion: Double,
        resourceRelativePath: String,
        installedAt: Date = Date(),
        isEnabled: Bool = true,
        permissionDecisionMade: Bool = false,
        grantedPermissions: Set<String> = [],
        grantedMatchPatterns: Set<String> = []
    ) {
        self.id = id
        self.runtimeIdentifier = runtimeIdentifier
        self.name = name
        self.version = version
        self.manifestVersion = manifestVersion
        self.resourceRelativePath = resourceRelativePath
        self.installedAt = installedAt
        self.isEnabled = isEnabled
        self.permissionDecisionMade = permissionDecisionMade
        self.grantedPermissions = grantedPermissions
        self.grantedMatchPatterns = grantedMatchPatterns
    }
}
