import AppKit
import Foundation

extension OraChromeExtensionAPIHost {
    func handleDownloads(method: String, args: [Any], spaceID: UUID) async throws -> Any? {
        switch method {
        case "download":
            let options = dictionaryArgument(args)
            guard let rawURL = options["url"] as? String, let url = URL(string: rawURL) else {
                throw BridgeError.invalidArguments("downloads.download requires a valid URL.")
            }

            let identifier = nextDownloadID
            nextDownloadID += 1
            let destination = downloadDestination(
                requestedFilename: options["filename"] as? String,
                sourceURL: url
            )
            let record = BridgeDownload(
                id: identifier,
                spaceID: spaceID,
                url: url,
                filename: destination.path
            )
            record.destinationURL = destination
            downloads[identifier] = record

            var request = URLRequest(url: url)
            if let method = options["method"] as? String {
                request.httpMethod = method
            }
            if let body = options["body"] as? String {
                request.httpBody = Data(body.utf8)
            }
            if let headers = options["headers"] as? [[String: Any]] {
                for header in headers {
                    if let name = header["name"] as? String, let value = header["value"] as? String {
                        request.setValue(value, forHTTPHeaderField: name)
                    }
                }
            }

            let task = URLSession.shared.downloadTask(with: request) { [weak self] temporaryURL, _, error in
                Task { @MainActor in
                    self?.completeBridgeDownload(identifier: identifier, temporaryURL: temporaryURL, error: error)
                }
            }
            record.task = task
            emit(namespace: "downloads", event: "onCreated", args: [record.dictionary()], spaceID: spaceID)
            task.resume()
            return identifier

        case "search":
            let query = dictionaryArgument(args)
            return matchingDownloads(query: query, spaceID: spaceID).map { $0.dictionary() }

        case "pause":
            let record = try bridgeDownload(args: args, spaceID: spaceID)
            guard record.state == "in_progress", !record.paused else { return nil }
            record.task?.suspend()
            record.paused = true
            emitDownloadChange(record, property: "paused", previous: false, current: true)
            return nil

        case "resume":
            let record = try bridgeDownload(args: args, spaceID: spaceID)
            guard record.state == "in_progress", record.paused else { return nil }
            record.task?.resume()
            record.paused = false
            emitDownloadChange(record, property: "paused", previous: true, current: false)
            return nil

        case "cancel":
            let record = try bridgeDownload(args: args, spaceID: spaceID)
            record.task?.cancel()
            record.state = "interrupted"
            record.error = "USER_CANCELED"
            record.endedAt = Date()
            emitDownloadChange(record, property: "state", previous: "in_progress", current: "interrupted")
            return nil

        case "erase":
            let query = dictionaryArgument(args)
            let matches = matchingDownloads(query: query, spaceID: spaceID)
            let identifiers = matches.map(\.id)
            for identifier in identifiers {
                downloads[identifier] = nil
                emit(namespace: "downloads", event: "onErased", args: [identifier], spaceID: spaceID)
            }
            return identifiers

        case "removeFile":
            let record = try bridgeDownload(args: args, spaceID: spaceID)
            if let destination = record.destinationURL, FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
                emitDownloadChange(record, property: "exists", previous: true, current: false)
            }
            return nil

        case "open":
            let record = try bridgeDownload(args: args, spaceID: spaceID)
            guard let destination = record.destinationURL else { return nil }
            NSWorkspace.shared.open(destination)
            return nil

        case "show":
            let record = try bridgeDownload(args: args, spaceID: spaceID)
            if let destination = record.destinationURL {
                NSWorkspace.shared.selectFile(destination.path, inFileViewerRootedAtPath: "")
            }
            return true

        case "showDefaultFolder":
            NSWorkspace.shared.open(downloadsDirectory)
            return nil

        case "getFileIcon":
            let record = try bridgeDownload(args: args, spaceID: spaceID)
            guard let destination = record.destinationURL else { return NSNull() }
            let icon = NSWorkspace.shared.icon(forFile: destination.path)
            guard let data = icon.tiffRepresentation else { return NSNull() }
            return "data:image/tiff;base64," + data.base64EncodedString()

        case "acceptDanger", "setShelfEnabled":
            _ = try? bridgeDownload(args: args, spaceID: spaceID)
            return nil

        case "drag":
            throw BridgeError.unsupportedMethod("downloads", method)

        default:
            throw BridgeError.unsupportedMethod("downloads", method)
        }
    }

    private func bridgeDownload(args: [Any], spaceID: UUID) throws -> BridgeDownload {
        guard let identifier = numberArgument(args, at: 0)?.intValue,
              let record = downloads[identifier], record.spaceID == spaceID
        else {
            throw BridgeError.invalidArguments("The download ID does not exist in this Ora space.")
        }
        return record
    }

    private func matchingDownloads(query: [String: Any], spaceID: UUID) -> [BridgeDownload] {
        downloads.values.filter { record in
            guard record.spaceID == spaceID else { return false }
            if let identifier = (query["id"] as? NSNumber)?.intValue, identifier != record.id { return false }
            if let state = query["state"] as? String, state != record.state { return false }
            if let paused = query["paused"] as? Bool, paused != record.paused { return false }
            if let url = query["url"] as? String, url != record.url.absoluteString { return false }
            if let filename = query["filename"] as? String,
               !(record.destinationURL?.path ?? record.filename).contains(filename)
            {
                return false
            }
            if let terms = query["query"] as? [String], !terms.isEmpty {
                let haystack = (record.url.absoluteString + " " + record.filename).lowercased()
                if !terms.allSatisfy({ haystack.contains($0.lowercased()) }) { return false }
            }
            return true
        }.sorted { $0.startedAt > $1.startedAt }
    }

    private func completeBridgeDownload(identifier: Int, temporaryURL: URL?, error: Error?) {
        guard let record = downloads[identifier] else { return }
        let previousState = record.state
        record.endedAt = Date()

        if let error {
            record.state = "interrupted"
            record.error = (error as NSError).code == NSURLErrorCancelled ? "USER_CANCELED" : "NETWORK_FAILED"
        } else if let temporaryURL, let destination = record.destinationURL {
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: destination.path) {
                    let unique = uniqueDownloadURL(destination)
                    record.destinationURL = unique
                    record.filename = unique.path
                }
                try FileManager.default.moveItem(at: temporaryURL, to: record.destinationURL ?? destination)
                record.state = "complete"
            } catch {
                record.state = "interrupted"
                record.error = "FILE_FAILED"
            }
        } else {
            record.state = "interrupted"
            record.error = "NETWORK_FAILED"
        }

        emitDownloadChange(record, property: "state", previous: previousState, current: record.state)
    }

    private func emitDownloadChange(_ record: BridgeDownload, property: String, previous: Any, current: Any) {
        emit(
            namespace: "downloads",
            event: "onChanged",
            args: [[
                "id": record.id,
                property: ["previous": previous, "current": current]
            ]],
            spaceID: record.spaceID
        )
    }

    private var downloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private func downloadDestination(requestedFilename: String?, sourceURL: URL) -> URL {
        let fallback = sourceURL.lastPathComponent.isEmpty ? "download" : sourceURL.lastPathComponent
        let requested = requestedFilename?.isEmpty == false ? requestedFilename! : fallback
        let safeComponents = requested
            .split(separator: "/")
            .filter { $0 != "." && $0 != ".." }
            .map(String.init)
        let relative = safeComponents.isEmpty ? fallback : safeComponents.joined(separator: "/")
        return uniqueDownloadURL(downloadsDirectory.appendingPathComponent(relative))
    }

    private func uniqueDownloadURL(_ original: URL) -> URL {
        guard FileManager.default.fileExists(atPath: original.path) else { return original }
        let directory = original.deletingLastPathComponent()
        let base = original.deletingPathExtension().lastPathComponent
        let pathExtension = original.pathExtension
        var counter = 1
        while true {
            let suffix = "\(base) (\(counter))" + (pathExtension.isEmpty ? "" : ".\(pathExtension)")
            let candidate = directory.appendingPathComponent(suffix)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }
}
