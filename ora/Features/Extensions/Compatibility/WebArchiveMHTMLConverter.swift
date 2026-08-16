import Foundation

struct WebArchiveMHTMLConverter {
    enum ConversionError: LocalizedError {
        case invalidWebArchive
        case missingMainResource

        var errorDescription: String? {
            switch self {
            case .invalidWebArchive:
                return "WebKit returned an invalid web archive."
            case .missingMainResource:
                return "The WebKit archive does not contain a main resource."
            }
        }
    }

    private struct Resource {
        let data: Data
        let url: String
        let mimeType: String
        let encoding: String?
    }

    static func convert(_ webArchiveData: Data) throws -> Data {
        guard let root = try PropertyListSerialization.propertyList(
            from: webArchiveData,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw ConversionError.invalidWebArchive
        }

        let resources = collectResources(from: root)
        guard let main = resources.first else {
            throw ConversionError.missingMainResource
        }

        let boundary = "----=_OraWebExtension_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var output = Data()
        append("MIME-Version: 1.0\r\n", to: &output)
        append("Content-Type: multipart/related; type=\"\(main.mimeType)\"; boundary=\"\(boundary)\"\r\n", to: &output)
        append("Snapshot-Content-Location: \(sanitizeHeader(main.url))\r\n\r\n", to: &output)

        for resource in resources {
            append("--\(boundary)\r\n", to: &output)
            let charset = resource.encoding.flatMap(normalizedCharset)
            append(
                "Content-Type: \(resource.mimeType)\(charset.map { "; charset=\"\($0)\"" } ?? "")\r\n",
                to: &output
            )
            append("Content-Transfer-Encoding: base64\r\n", to: &output)
            append("Content-Location: \(sanitizeHeader(resource.url))\r\n\r\n", to: &output)
            appendBase64(resource.data, to: &output)
            append("\r\n", to: &output)
        }

        append("--\(boundary)--\r\n", to: &output)
        return output
    }

    private static func collectResources(from archive: [String: Any]) -> [Resource] {
        var resources: [Resource] = []
        if let main = archive["WebMainResource"] as? [String: Any], let resource = resource(from: main) {
            resources.append(resource)
        }
        if let subresources = archive["WebSubresources"] as? [[String: Any]] {
            resources.append(contentsOf: subresources.compactMap(resource(from:)))
        }
        if let subframes = archive["WebSubframeArchives"] as? [[String: Any]] {
            for subframe in subframes {
                resources.append(contentsOf: collectResources(from: subframe))
            }
        }
        return deduplicated(resources)
    }

    private static func resource(from dictionary: [String: Any]) -> Resource? {
        guard let data = dictionary["WebResourceData"] as? Data else { return nil }
        let url = dictionary["WebResourceURL"] as? String ?? "about:blank"
        let mimeType = dictionary["WebResourceMIMEType"] as? String ?? "application/octet-stream"
        let encoding = dictionary["WebResourceTextEncodingName"] as? String
        return Resource(data: data, url: url, mimeType: mimeType, encoding: encoding)
    }

    private static func deduplicated(_ resources: [Resource]) -> [Resource] {
        var seen: Set<String> = []
        return resources.filter { resource in
            let key = resource.url + "\u{0}" + resource.mimeType
            return seen.insert(key).inserted
        }
    }

    private static func normalizedCharset(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.replacingOccurrences(of: "\"", with: "")
    }

    private static func sanitizeHeader(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
    }

    private static func appendBase64(_ data: Data, to output: inout Data) {
        let encoded = data.base64EncodedString()
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: 76, limitedBy: encoded.endIndex) ?? encoded.endIndex
            append(String(encoded[index ..< end]) + "\r\n", to: &output)
            index = end
        }
    }

    private static func append(_ string: String, to data: inout Data) {
        data.append(contentsOf: string.utf8)
    }
}
