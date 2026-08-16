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
    var permissionDecisionSpaceIDs: Set<String>
    var grantedPermissionsBySpace: [String: Set<String>]
    var grantedMatchPatternsBySpace: [String: Set<String>]

    init(
        id: UUID,
        runtimeIdentifier: String,
        chromeExtensionID: String?,
        name: String,
        version: String,
        manifestVersion: Double,
        resourceRelativePath: String,
        source: Source,
        installedAt: Date,
        disabledSpaceIDs: Set<UUID> = [],
        permissionDecisionSpaceIDs: Set<String> = [],
        grantedPermissionsBySpace: [String: Set<String>] = [:],
        grantedMatchPatternsBySpace: [String: Set<String>] = [:]
    ) {
        self.id = id
        self.runtimeIdentifier = runtimeIdentifier
        self.chromeExtensionID = chromeExtensionID
        self.name = name
        self.version = version
        self.manifestVersion = manifestVersion
        self.resourceRelativePath = resourceRelativePath
        self.source = source
        self.installedAt = installedAt
        self.disabledSpaceIDs = disabledSpaceIDs
        self.permissionDecisionSpaceIDs = permissionDecisionSpaceIDs
        self.grantedPermissionsBySpace = grantedPermissionsBySpace
        self.grantedMatchPatternsBySpace = grantedMatchPatternsBySpace
    }

    func isEnabled(in spaceID: UUID) -> Bool {
        !disabledSpaceIDs.contains(spaceID)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case runtimeIdentifier
        case chromeExtensionID
        case name
        case version
        case manifestVersion
        case resourceRelativePath
        case source
        case installedAt
        case disabledSpaceIDs
        case permissionDecisionSpaceIDs
        case grantedPermissionsBySpace
        case grantedMatchPatternsBySpace
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        runtimeIdentifier = try container.decode(String.self, forKey: .runtimeIdentifier)
        chromeExtensionID = try container.decodeIfPresent(String.self, forKey: .chromeExtensionID)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        manifestVersion = try container.decode(Double.self, forKey: .manifestVersion)
        resourceRelativePath = try container.decode(String.self, forKey: .resourceRelativePath)
        source = try container.decode(Source.self, forKey: .source)
        installedAt = try container.decode(Date.self, forKey: .installedAt)
        disabledSpaceIDs = try container.decodeIfPresent(Set<UUID>.self, forKey: .disabledSpaceIDs) ?? []
        permissionDecisionSpaceIDs = try container.decodeIfPresent(Set<String>.self, forKey: .permissionDecisionSpaceIDs) ?? []
        grantedPermissionsBySpace = try container.decodeIfPresent(
            [String: Set<String>].self,
            forKey: .grantedPermissionsBySpace
        ) ?? [:]
        grantedMatchPatternsBySpace = try container.decodeIfPresent(
            [String: Set<String>].self,
            forKey: .grantedMatchPatternsBySpace
        ) ?? [:]
    }
}
