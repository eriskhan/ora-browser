import Combine
import Foundation
@preconcurrency import WebKit

@MainActor
final class WebExtensionManager: ObservableObject {
    enum ManagerError: LocalizedError {
        case unsupportedLocalResource
        case extensionNotFound

        var errorDescription: String? {
            switch self {
            case .unsupportedLocalResource:
                return "Choose an unpacked extension folder, ZIP archive, or CRX package."
            case .extensionNotFound:
                return "The extension is no longer installed."
            }
        }
    }

    private struct ContextKey: Hashable {
        let spaceID: UUID
        let extensionID: UUID
    }

    static let shared = WebExtensionManager()

    @Published private(set) var installedExtensions: [InstalledWebExtension] = []
    @Published private(set) var loadErrors: [UUID: String] = [:]

    private let registryDefaultsKey = "webExtensions.registry.v1"
    private let fileManager = FileManager.default
    private var controllers: [UUID: WKWebExtensionController] = [:]
    private var extensionObjects: [UUID: WKWebExtension] = [:]
    private var contexts: [ContextKey: WKWebExtensionContext] = [:]

    private init() {
        restoreRegistry()
    }

    func attach(controller: WKWebExtensionController, spaceID: UUID) async {
        if let existing = controllers[spaceID], existing === controller {
            return
        }

        controllers[spaceID] = controller
        controller.delegate = WebExtensionPermissionPrompter.shared
        for installedExtension in installedExtensions where installedExtension.isEnabled(in: spaceID) {
            do {
                try await load(installedExtension, in: spaceID, controller: controller)
            } catch {
                loadErrors[installedExtension.id] = error.localizedDescription
            }
        }
    }

    @discardableResult
    func installFromChromeWebStore(_ input: String) async throws -> InstalledWebExtension {
        let chromeExtensionID = try ChromeExtensionInstaller.extensionIdentifier(from: input)
        let zipData = try await ChromeExtensionInstaller.downloadZIP(for: chromeExtensionID)
        let installID = UUID()
        let installDirectory = try makeInstallDirectory(for: installID)
        let archiveURL = installDirectory.appendingPathComponent("extension.zip")

        do {
            try zipData.write(to: archiveURL, options: .atomic)
            return try await registerInstalledExtension(
                installID: installID,
                resourceURL: archiveURL,
                source: .chromeWebStore,
                chromeExtensionID: chromeExtensionID
            )
        } catch {
            try? fileManager.removeItem(at: installDirectory)
            throw error
        }
    }

    @discardableResult
    func installLocalResource(at sourceURL: URL) async throws -> InstalledWebExtension {
        let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let installID = UUID()
        let installDirectory = try makeInstallDirectory(for: installID)
        let resourceURL = try copyLocalResource(sourceURL, into: installDirectory)

        do {
            return try await registerInstalledExtension(
                installID: installID,
                resourceURL: resourceURL,
                source: .local,
                chromeExtensionID: nil
            )
        } catch {
            try? fileManager.removeItem(at: installDirectory)
            throw error
        }
    }

    func removeExtension(_ extensionID: UUID) {
        guard let installedExtension = installedExtensions.first(where: { $0.id == extensionID }) else {
            return
        }

        let contextKeys = contexts.keys.filter { $0.extensionID == extensionID }
        for key in contextKeys {
            guard let context = contexts.removeValue(forKey: key) else { continue }
            if let controller = controllers[key.spaceID] {
                try? controller.unload(context)
            }
        }

        extensionObjects[extensionID] = nil
        loadErrors[extensionID] = nil
        installedExtensions.removeAll { $0.id == extensionID }
        persistRegistry()

        let installDirectory = extensionsDirectory.appendingPathComponent(installedExtension.id.uuidString)
        try? fileManager.removeItem(at: installDirectory)
    }

    func setEnabled(_ enabled: Bool, extensionID: UUID, in spaceID: UUID) async throws {
        guard let index = installedExtensions.firstIndex(where: { $0.id == extensionID }) else {
            throw ManagerError.extensionNotFound
        }

        if enabled {
            installedExtensions[index].disabledSpaceIDs.remove(spaceID)
        } else {
            installedExtensions[index].disabledSpaceIDs.insert(spaceID)
        }
        persistRegistry()

        let key = ContextKey(spaceID: spaceID, extensionID: extensionID)
        if enabled {
            if let controller = controllers[spaceID] {
                try await load(installedExtensions[index], in: spaceID, controller: controller)
            }
        } else if let context = contexts.removeValue(forKey: key), let controller = controllers[spaceID] {
            try controller.unload(context)
        }
    }

    func context(extensionID: UUID, in spaceID: UUID) -> WKWebExtensionContext? {
        contexts[ContextKey(spaceID: spaceID, extensionID: extensionID)]
    }

    func loadedExtensions(in spaceID: UUID) -> [(InstalledWebExtension, WKWebExtensionContext)] {
        installedExtensions.compactMap { installedExtension in
            guard let context = context(extensionID: installedExtension.id, in: spaceID) else {
                return nil
            }
            return (installedExtension, context)
        }
    }

    func recordGrantedPermissions(
        _ permissions: Set<WKWebExtension.Permission>,
        for context: WKWebExtensionContext
    ) {
        guard let key = contextKey(for: context),
              let index = installedExtensions.firstIndex(where: { $0.id == key.extensionID })
        else {
            return
        }

        let spaceKey = key.spaceID.uuidString
        var stored = installedExtensions[index].grantedPermissionsBySpace[spaceKey] ?? []
        stored.formUnion(permissions.map(\.rawValue))
        installedExtensions[index].grantedPermissionsBySpace[spaceKey] = stored
        persistRegistry()
    }

    func recordGrantedMatchPatterns(
        _ matchPatterns: Set<WKWebExtension.MatchPattern>,
        for context: WKWebExtensionContext
    ) {
        guard let key = contextKey(for: context),
              let index = installedExtensions.firstIndex(where: { $0.id == key.extensionID })
        else {
            return
        }

        let spaceKey = key.spaceID.uuidString
        var stored = installedExtensions[index].grantedMatchPatternsBySpace[spaceKey] ?? []
        stored.formUnion(matchPatterns.map(\.string))
        installedExtensions[index].grantedMatchPatternsBySpace[spaceKey] = stored
        persistRegistry()
    }

    private func registerInstalledExtension(
        installID: UUID,
        resourceURL: URL,
        source: InstalledWebExtension.Source,
        chromeExtensionID: String?
    ) async throws -> InstalledWebExtension {
        let extensionObject = try await WKWebExtension(resourceBaseURL: resourceURL)
        let runtimeIdentifier = chromeExtensionID ?? installID.uuidString.lowercased()
        let relativePath = resourceURL.path.replacingOccurrences(
            of: extensionsDirectory.path + "/",
            with: ""
        )
        let installedExtension = InstalledWebExtension(
            id: installID,
            runtimeIdentifier: runtimeIdentifier,
            chromeExtensionID: chromeExtensionID,
            name: extensionObject.displayName ?? "Unnamed Extension",
            version: extensionObject.displayVersion ?? extensionObject.version ?? "Unknown",
            manifestVersion: extensionObject.manifestVersion,
            resourceRelativePath: relativePath,
            source: source,
            installedAt: Date()
        )

        extensionObjects[installID] = extensionObject
        installedExtensions.append(installedExtension)
        installedExtensions.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persistRegistry()

        for (spaceID, controller) in controllers where installedExtension.isEnabled(in: spaceID) {
            do {
                try await load(installedExtension, in: spaceID, controller: controller)
            } catch {
                loadErrors[installID] = error.localizedDescription
            }
        }

        return installedExtension
    }

    private func load(
        _ installedExtension: InstalledWebExtension,
        in spaceID: UUID,
        controller: WKWebExtensionController
    ) async throws {
        let key = ContextKey(spaceID: spaceID, extensionID: installedExtension.id)
        if contexts[key] != nil {
            return
        }

        let extensionObject = try await extensionObject(for: installedExtension)
        authorizeInitialAccessIfNeeded(for: installedExtension.id, webExtension: extensionObject, spaceID: spaceID)

        guard let currentExtension = installedExtensions.first(where: { $0.id == installedExtension.id }) else {
            throw ManagerError.extensionNotFound
        }

        let context = WKWebExtensionContext(for: extensionObject)
        context.uniqueIdentifier = currentExtension.runtimeIdentifier
        context.isInspectable = true
        restorePermissions(for: currentExtension, spaceID: spaceID, into: context)
        try controller.load(context)
        contexts[key] = context
        loadErrors[currentExtension.id] = nil
    }

    private func authorizeInitialAccessIfNeeded(
        for extensionID: UUID,
        webExtension: WKWebExtension,
        spaceID: UUID
    ) {
        guard let index = installedExtensions.firstIndex(where: { $0.id == extensionID }) else { return }
        let spaceKey = spaceID.uuidString
        guard !installedExtensions[index].permissionDecisionSpaceIDs.contains(spaceKey) else { return }

        let decision = WebExtensionPermissionPrompter.shared.requestInitialAccess(for: webExtension)
        installedExtensions[index].permissionDecisionSpaceIDs.insert(spaceKey)
        installedExtensions[index].grantedPermissionsBySpace[spaceKey] = Set(decision.permissions.map(\.rawValue))
        installedExtensions[index].grantedMatchPatternsBySpace[spaceKey] = Set(decision.matchPatterns.map(\.string))
        persistRegistry()
    }

    private func restorePermissions(
        for installedExtension: InstalledWebExtension,
        spaceID: UUID,
        into context: WKWebExtensionContext
    ) {
        let spaceKey = spaceID.uuidString
        let permissionValues = installedExtension.grantedPermissionsBySpace[spaceKey] ?? []
        context.grantedPermissions = Dictionary(
            uniqueKeysWithValues: permissionValues.map {
                (WKWebExtension.Permission(rawValue: $0), Date.distantFuture)
            }
        )

        var patterns: [WKWebExtension.MatchPattern: Date] = [:]
        for rawPattern in installedExtension.grantedMatchPatternsBySpace[spaceKey] ?? [] {
            if let pattern = try? WKWebExtension.MatchPattern(string: rawPattern) {
                patterns[pattern] = .distantFuture
            }
        }
        context.grantedPermissionMatchPatterns = patterns
    }

    private func contextKey(for context: WKWebExtensionContext) -> ContextKey? {
        contexts.first(where: { $0.value === context })?.key
    }

    private func extensionObject(for installedExtension: InstalledWebExtension) async throws -> WKWebExtension {
        if let cached = extensionObjects[installedExtension.id] {
            return cached
        }

        let resourceURL = extensionsDirectory.appendingPathComponent(installedExtension.resourceRelativePath)
        let extensionObject = try await WKWebExtension(resourceBaseURL: resourceURL)
        extensionObjects[installedExtension.id] = extensionObject
        return extensionObject
    }

    private func copyLocalResource(_ sourceURL: URL, into installDirectory: URL) throws -> URL {
        let resourceValues = try sourceURL.resourceValues(forKeys: [.isDirectoryKey])
        if resourceValues.isDirectory == true {
            let destination = installDirectory.appendingPathComponent("resource", isDirectory: true)
            try fileManager.copyItem(at: sourceURL, to: destination)
            return destination
        }

        switch sourceURL.pathExtension.lowercased() {
        case "zip":
            let destination = installDirectory.appendingPathComponent("extension.zip")
            try fileManager.copyItem(at: sourceURL, to: destination)
            return destination
        case "crx":
            let packageData = try Data(contentsOf: sourceURL)
            let zipData = try ChromeExtensionInstaller.extractZIP(from: packageData)
            let destination = installDirectory.appendingPathComponent("extension.zip")
            try zipData.write(to: destination, options: .atomic)
            return destination
        default:
            throw ManagerError.unsupportedLocalResource
        }
    }

    private func makeInstallDirectory(for installID: UUID) throws -> URL {
        let directory = extensionsDirectory.appendingPathComponent(installID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private var extensionsDirectory: URL {
        let applicationSupport: URL
        do {
            applicationSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
        }

        let directory = applicationSupport
            .appendingPathComponent("Ora", isDirectory: true)
            .appendingPathComponent("Extensions", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func restoreRegistry() {
        guard let data = UserDefaults.standard.data(forKey: registryDefaultsKey),
              let decoded = try? JSONDecoder().decode([InstalledWebExtension].self, from: data)
        else {
            return
        }
        installedExtensions = decoded
    }

    private func persistRegistry() {
        guard let data = try? JSONEncoder().encode(installedExtensions) else {
            return
        }
        UserDefaults.standard.set(data, forKey: registryDefaultsKey)
    }
}
