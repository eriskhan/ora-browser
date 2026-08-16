import Foundation

struct ChromeExtensionInstaller {
    enum InstallerError: LocalizedError {
        case invalidExtensionIdentifier
        case invalidPackage
        case unsupportedCRXVersion(UInt32)
        case downloadFailed(Int)

        var errorDescription: String? {
            switch self {
            case .invalidExtensionIdentifier:
                return "Enter a Chrome Web Store URL or a 32-character extension ID."
            case .invalidPackage:
                return "The downloaded Chrome extension package is invalid."
            case let .unsupportedCRXVersion(version):
                return "CRX version \(version) is not supported."
            case let .downloadFailed(statusCode):
                return "Chrome Web Store download failed with HTTP \(statusCode)."
            }
        }
    }

    static func extensionIdentifier(from input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if isValidExtensionIdentifier(trimmed) {
            return trimmed
        }

        guard let url = URL(string: trimmed) else {
            throw InstallerError.invalidExtensionIdentifier
        }

        if let queryID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "id" })?
            .value,
            isValidExtensionIdentifier(queryID)
        {
            return queryID
        }

        if let pathID = url.pathComponents.reversed().first(where: isValidExtensionIdentifier) {
            return pathID
        }

        throw InstallerError.invalidExtensionIdentifier
    }

    static func downloadZIP(for extensionIdentifier: String) async throws -> Data {
        let identifier = try self.extensionIdentifier(from: extensionIdentifier)
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        components.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: "134.0.0.0"),
            URLQueryItem(name: "acceptformat", value: "crx2,crx3"),
            URLQueryItem(name: "x", value: "id=\(identifier)&installsource=ondemand&uc")
        ]

        guard let url = components.url else {
            throw InstallerError.invalidExtensionIdentifier
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let httpResponse = response as? HTTPURLResponse,
           !(200 ... 299).contains(httpResponse.statusCode)
        {
            throw InstallerError.downloadFailed(httpResponse.statusCode)
        }

        return try extractZIP(from: data)
    }

    static func extractZIP(from packageData: Data) throws -> Data {
        guard packageData.count >= 4 else {
            throw InstallerError.invalidPackage
        }

        if packageData.starts(with: [0x50, 0x4B]) {
            return packageData
        }

        guard packageData.starts(with: [0x43, 0x72, 0x32, 0x34]), packageData.count >= 12 else {
            throw InstallerError.invalidPackage
        }

        let version = try readUInt32LE(packageData, at: 4)
        let zipOffset: Int

        switch version {
        case 2:
            guard packageData.count >= 16 else {
                throw InstallerError.invalidPackage
            }
            let publicKeyLength = Int(try readUInt32LE(packageData, at: 8))
            let signatureLength = Int(try readUInt32LE(packageData, at: 12))
            zipOffset = 16 + publicKeyLength + signatureLength
        case 3:
            let headerLength = Int(try readUInt32LE(packageData, at: 8))
            zipOffset = 12 + headerLength
        default:
            throw InstallerError.unsupportedCRXVersion(version)
        }

        guard zipOffset >= 0, zipOffset < packageData.count else {
            throw InstallerError.invalidPackage
        }

        let zipData = Data(packageData[zipOffset...])
        guard zipData.starts(with: [0x50, 0x4B]) else {
            throw InstallerError.invalidPackage
        }
        return zipData
    }

    private static func isValidExtensionIdentifier(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { character in
            guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
                return false
            }
            return scalar.value >= 97 && scalar.value <= 112
        }
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else {
            throw InstallerError.invalidPackage
        }

        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
