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
    var originalPermissions: Set<String>
    var grantedPermissions: Set<String>
    var grantedMatchPatterns: Set<String>
    var compatibilityRevision: Int

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
        originalPermissions: Set<String> = [],
        grantedPermissions: Set<String> = [],
        grantedMatchPatterns: Set<String> = [],
        compatibilityRevision: Int = 0
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
        self.originalPermissions = originalPermissions
        self.grantedPermissions = grantedPermissions
        self.grantedMatchPatterns = grantedMatchPatterns
        self.compatibilityRevision = compatibilityRevision
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case runtimeIdentifier
        case name
        case version
        case manifestVersion
        case resourceRelativePath
        case installedAt
        case isEnabled
        case permissionDecisionMade
        case originalPermissions
        case grantedPermissions
        case grantedMatchPatterns
        case compatibilityRevision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        runtimeIdentifier = try container.decode(String.self, forKey: .runtimeIdentifier)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        manifestVersion = try container.decode(Double.self, forKey: .manifestVersion)
        resourceRelativePath = try container.decode(String.self, forKey: .resourceRelativePath)
        installedAt = try container.decodeIfPresent(Date.self, forKey: .installedAt) ?? Date.distantPast
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        permissionDecisionMade = try container.decodeIfPresent(Bool.self, forKey: .permissionDecisionMade) ?? false
        originalPermissions = try container.decodeIfPresent(Set<String>.self, forKey: .originalPermissions) ?? []
        grantedPermissions = try container.decodeIfPresent(Set<String>.self, forKey: .grantedPermissions) ?? []
        grantedMatchPatterns = try container.decodeIfPresent(Set<String>.self, forKey: .grantedMatchPatterns) ?? []
        compatibilityRevision = try container.decodeIfPresent(Int.self, forKey: .compatibilityRevision) ?? 0
    }
}
