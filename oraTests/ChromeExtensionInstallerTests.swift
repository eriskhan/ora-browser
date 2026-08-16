import Foundation
@testable import Ora
import Testing

struct ChromeExtensionInstallerTests {
    private let extensionID = "abcdefghijklmnopabcdefghijklmnop"

    @Test func parsesRawExtensionIdentifier() throws {
        #expect(try ChromeExtensionInstaller.extensionIdentifier(from: extensionID) == extensionID)
    }

    @Test func parsesChromeWebStoreURL() throws {
        let url = "https://chromewebstore.google.com/detail/example-extension/\(extensionID)"
        #expect(try ChromeExtensionInstaller.extensionIdentifier(from: url) == extensionID)
    }

    @Test func rejectsInvalidExtensionIdentifier() {
        #expect(throws: ChromeExtensionInstaller.InstallerError.self) {
            try ChromeExtensionInstaller.extensionIdentifier(from: "not-a-chrome-extension")
        }
    }

    @Test func extractsZIPPayloadFromCRX3() throws {
        let zipPayload = Data([0x50, 0x4B, 0x03, 0x04, 0x01, 0x02])
        var package = Data("Cr24".utf8)
        package.append(littleEndian(3))
        package.append(littleEndian(3))
        package.append(contentsOf: [0xAA, 0xBB, 0xCC])
        package.append(zipPayload)

        #expect(try ChromeExtensionInstaller.extractZIP(from: package) == zipPayload)
    }

    @Test func extractsZIPPayloadFromCRX2() throws {
        let zipPayload = Data([0x50, 0x4B, 0x03, 0x04, 0x05, 0x06])
        var package = Data("Cr24".utf8)
        package.append(littleEndian(2))
        package.append(littleEndian(2))
        package.append(littleEndian(3))
        package.append(contentsOf: [0x01, 0x02])
        package.append(contentsOf: [0x03, 0x04, 0x05])
        package.append(zipPayload)

        #expect(try ChromeExtensionInstaller.extractZIP(from: package) == zipPayload)
    }

    private func littleEndian(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }
}
