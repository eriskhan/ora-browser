import AppKit
import CryptoKit
import Foundation
import SwiftData
@preconcurrency import WebKit

@MainActor
enum MozillaDownloadsAPI {
    private final class Transfer {
        let download: Download
        weak var manager: DownloadManager?
        var task: URLSessionDownloadTask?
        let destinationURL: URL
        let overwriteExisting: Bool
        var paused = false
        var cancelledByUser = false
        var mimeType: String?

        init(
            download: Download,
            manager: DownloadManager,
            destinationURL: URL,
            overwriteExisting: Bool
        ) {
            self.download = download
            self.manager = manager
            self.destinationURL = destinationURL
            self.overwriteExisting = overwriteExisting
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static var transfers: [UUID: Transfer] = [:]
    private static var progressTimers: [UUID: Timer] = [:]

    static func handle(
        method: String,
        arguments: [Any],
        context: WKWebExtensionContext,
        manager extensionManager: ExtensionManager
    ) async throws -> Any {
        try MozillaNativeAPIRouter.require("downloads", context: context, manager: extensionManager)
        let environment = try environment(for: context)

        switch method {
        case "download":
            return try await download(arguments: arguments, environment: environment)
        case "search":
            return try search(arguments: arguments, manager: environment.downloadManager)
        case "pause":
            return try pause(arguments: arguments, manager: environment.downloadManager)
        case "resume":
            return try resume(arguments: arguments, manager: environment.downloadManager)
        case "cancel":
            return try cancel(arguments: arguments, manager: environment.downloadManager)
        case "open":
            try MozillaNativeAPIRouter.require("downloads.open", context: context, manager: extensionManager)
            return try open(arguments: arguments, manager: environment.downloadManager)
        case "show":
            return try show(arguments: arguments, manager: environment.downloadManager)
        case "showDefaultFolder":
            NSWorkspace.shared.open(environment.downloadManager.getDownloadsDirectory())
            return NSNull()
        case "erase":
            return try erase(arguments: arguments, manager: environment.downloadManager)
        case "removeFile":
            return try removeFile(arguments: arguments, manager: environment.downloadManager)
        case "getFileIcon":
            return try fileIcon(arguments: arguments, manager: environment.downloadManager)
        case "acceptDanger":
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "Ora only reports downloads as safe; there is no dangerous download to accept."
            )
        default:
            throw MozillaNativeAPIBridge.BridgeError.unsupportedMethod("downloads", method)
        }
    }

    static func didCreate(_ download: Download) {
        MozillaNativeAPIBridge.shared.emit(
            namespace: "downloads",
            event: "onCreated",
            arguments: [downloadItem(download)]
        )
    }

    static func didChangeProgress(
        _ download: Download,
        previousBytes: Int64,
        previousTotalBytes: Int64
    ) {
        var delta: [String: Any] = ["id": numericID(download.id)]
        if previousBytes != download.downloadedBytes {
            delta["bytesReceived"] = change(previous: previousBytes, current: download.downloadedBytes)
        }
        if previousTotalBytes != download.fileSize {
            delta["totalBytes"] = change(previous: previousTotalBytes, current: download.fileSize)
            delta["fileSize"] = change(previous: previousTotalBytes, current: download.fileSize)
        }
        guard delta.count > 1 else { return }
        emitChanged(delta)
    }

    static func didChangeState(
        _ download: Download,
        previousStatus: DownloadStatus
    ) {
        var delta: [String: Any] = ["id": numericID(download.id)]
        let previousState = state(for: previousStatus)
        let currentState = state(for: download.status)
        if previousState != currentState {
            delta["state"] = change(previous: previousState, current: currentState)
        }
        if previousStatus != .completed, download.status == .completed {
            delta["exists"] = change(previous: false, current: true)
            if let completedAt = download.completedAt {
                delta["endTime"] = change(
                    previous: NSNull(),
                    current: isoFormatter.string(from: completedAt)
                )
            }
        }
        if download.status == .failed || download.status == .cancelled {
            delta["error"] = change(
                previous: NSNull(),
                current: interruptReason(for: download)
            )
        }
        emitChanged(delta)
    }

    static func didChangeURL(_ download: Download, previousURL: URL) {
        guard previousURL != download.originalURL else { return }
        emitChanged([
            "id": numericID(download.id),
            "url": change(
                previous: previousURL.absoluteString,
                current: download.originalURL.absoluteString
            )
        ])
    }

    static func didErase(_ download: Download) {
        MozillaNativeAPIBridge.shared.emit(
            namespace: "downloads",
            event: "onErased",
            arguments: [numericID(download.id)]
        )
    }

    private struct Environment {
        let tabManager: TabManager
        let downloadManager: DownloadManager
        let window: OraWebExtensionWindow
    }

    private static func environment(for context: WKWebExtensionContext) throws -> Environment {
        let windows = [context.focusedWindow].compactMap { $0 as? OraWebExtensionWindow } +
            context.openWindows.compactMap { $0 as? OraWebExtensionWindow }
        for window in windows {
            guard let tabManager = window.tabManager else { continue }
            if let manager = tabManager.activeTab?.downloadManager ??
                tabManager.containers.lazy.flatMap(\.tabs).compactMap(\.downloadManager).first
            {
                return Environment(tabManager: tabManager, downloadManager: manager, window: window)
            }
        }
        throw MozillaNativeAPIBridge.BridgeError.unavailableBrowserWindow
    }

    private static func download(
        arguments: [Any],
        environment: Environment
    ) async throws -> Int {
        guard let options = arguments.first as? [String: Any],
              let urlString = options["url"] as? String,
              let url = URL(string: urlString),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "browser.downloads.download requires an HTTP or HTTPS URL."
            )
        }
        if options["incognito"] as? Bool == true || environment.window.isPrivateWindow {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "Ora does not expose private-window downloads to extensions."
            )
        }

        var request = try request(url: url, options: options)
        if request.value(forHTTPHeaderField: "Cookie") == nil {
            let dataStore = try websiteDataStore(options: options, environment: environment)
            if let cookieHeader = await cookieHeader(for: url, dataStore: dataStore) {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }
        }

        let destination = try destinationURL(
            for: url,
            options: options,
            manager: environment.downloadManager
        )
        try FileManager.default.createDirectory(
            at: destination.url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let record = environment.downloadManager.startExternalDownload(
            originalURL: url,
            suggestedFilename: destination.url.lastPathComponent,
            destinationURL: destination.url
        )
        let transfer = Transfer(
            download: record,
            manager: environment.downloadManager,
            destinationURL: destination.url,
            overwriteExisting: destination.overwrite
        )
        transfers[record.id] = transfer

        let downloadID = record.id
        let destinationURL = destination.url
        let overwrite = destination.overwrite
        let allowHTTPErrors = options["allowHttpErrors"] as? Bool ?? false
        let task = session.downloadTask(with: request) { temporaryURL, response, error in
            var completionError = error
            if completionError == nil,
               let httpResponse = response as? HTTPURLResponse,
               !allowHTTPErrors,
               !(200..<400).contains(httpResponse.statusCode)
            {
                completionError = NSError(
                    domain: "Ora.WebExtension.Downloads",
                    code: httpResponse.statusCode,
                    userInfo: [
                        NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode)"
                    ]
                )
            }

            if completionError == nil, let temporaryURL {
                do {
                    if overwrite, FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        throw NSError(
                            domain: "Ora.WebExtension.Downloads",
                            code: 2,
                            userInfo: [
                                NSLocalizedDescriptionKey: "The destination file already exists."
                            ]
                        )
                    }
                    try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
                } catch {
                    completionError = error
                }
            }

            Task { @MainActor in
                finishTransfer(
                    downloadID,
                    response: response,
                    error: completionError
                )
            }
        }
        transfer.task = task
        startProgressTimer(for: transfer)
        task.resume()
        return numericID(record.id)
    }

    private static func request(url: URL, options: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: url)
        let method = (options["method"] as? String ?? "GET").uppercased()
        guard method == "GET" || method == "POST" else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "Ora supports GET and POST for browser.downloads.download."
            )
        }
        request.httpMethod = method
        if method == "POST", let body = options["body"] as? String {
            request.httpBody = Data(body.utf8)
        }

        if let headers = options["headers"] as? [[String: Any]] {
            for header in headers {
                guard let name = header["name"] as? String,
                      let value = header["value"] as? String,
                      !name.isEmpty
                else { continue }
                let lowercased = name.lowercased()
                guard lowercased != "host" && lowercased != "content-length" else {
                    throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                        "Ora does not allow overriding the Host or Content-Length download headers."
                    )
                }
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        return request
    }

    private struct Destination {
        let url: URL
        let overwrite: Bool
    }

    private static func destinationURL(
        for sourceURL: URL,
        options: [String: Any],
        manager: DownloadManager
    ) throws -> Destination {
        let fallback = sourceURL.lastPathComponent.isEmpty ? "download" : sourceURL.lastPathComponent
        let filename = options["filename"] as? String ?? fallback
        let baseDirectory = manager.getDownloadsDirectory().standardizedFileURL
        let requested = try safeDestination(filename: filename, baseDirectory: baseDirectory)
        let conflictAction = options["conflictAction"] as? String ?? "uniquify"
        let saveAs = options["saveAs"] as? Bool ?? false

        if saveAs || conflictAction == "prompt" {
            let panel = NSSavePanel()
            panel.directoryURL = requested.deletingLastPathComponent()
            panel.nameFieldStringValue = requested.lastPathComponent
            guard panel.runModal() == .OK, let selected = panel.url else {
                throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                    "The user canceled the download destination selection."
                )
            }
            return Destination(url: selected, overwrite: true)
        }

        switch conflictAction {
        case "uniquify":
            return Destination(url: manager.createUniqueFilename(for: requested), overwrite: false)
        case "overwrite":
            return Destination(url: requested, overwrite: true)
        default:
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "Unknown browser.downloads conflictAction: \(conflictAction)."
            )
        }
    }

    private static func safeDestination(filename: String, baseDirectory: URL) throws -> URL {
        guard !filename.isEmpty,
              !filename.hasPrefix("/"),
              !filename.hasPrefix("~"),
              !filename.contains("\0")
        else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "The download filename must be a relative path inside Downloads."
            )
        }
        let components = filename.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains("..") else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "The download filename cannot traverse outside Downloads."
            )
        }
        let destination = baseDirectory.appendingPathComponent(filename).standardizedFileURL
        let basePath = baseDirectory.path.hasSuffix("/") ? baseDirectory.path : baseDirectory.path + "/"
        guard destination.path.hasPrefix(basePath) else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "The download filename must remain inside Downloads."
            )
        }
        return destination
    }

    private static func websiteDataStore(
        options: [String: Any],
        environment: Environment
    ) throws -> WKWebsiteDataStore {
        let container: TabContainer
        if let cookieStoreID = options["cookieStoreId"] as? String {
            let containerID = try MozillaBrowsingDataAPI.containerID(
                from: cookieStoreID,
                tabManager: environment.tabManager
            )
            guard let selected = environment.tabManager.containers.first(where: { $0.id == containerID }) else {
                throw MozillaNativeAPIBridge.BridgeError.itemNotFound(
                    "The requested download cookieStoreId does not exist."
                )
            }
            container = selected
        } else if let active = environment.tabManager.activeContainer {
            container = active
        } else {
            throw MozillaNativeAPIBridge.BridgeError.unavailableBrowserWindow
        }

        if let page = container.tabs.compactMap(\.browserPage).first {
            return page.webExtensionWebView.configuration.websiteDataStore
        }
        return BrowserEngine.shared.makeProfile(identifier: container.id, isPrivate: false).dataStore
    }

    private static func cookieHeader(
        for url: URL,
        dataStore: WKWebsiteDataStore
    ) async -> String? {
        let cookies = await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
        let applicable = cookies.filter { cookieMatches($0, url: url) }
        return HTTPCookie.requestHeaderFields(with: applicable)["Cookie"]
    }

    private static func cookieMatches(_ cookie: HTTPCookie, url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let cookieDomain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let domainMatches = host == cookieDomain || host.hasSuffix(".\(cookieDomain)")
        guard domainMatches else { return false }
        if cookie.isSecure, url.scheme?.lowercased() != "https" {
            return false
        }
        let requestPath = url.path.isEmpty ? "/" : url.path
        return requestPath.hasPrefix(cookie.path)
    }

    private static func startProgressTimer(for transfer: Transfer) {
        let id = transfer.download.id
        progressTimers[id]?.invalidate()
        progressTimers[id] = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            Task { @MainActor in
                guard let transfer = transfers[id],
                      let task = transfer.task,
                      let manager = transfer.manager
                else { return }
                let received = task.countOfBytesReceived
                let expected = task.countOfBytesExpectedToReceive
                manager.updateDownloadProgress(
                    transfer.download,
                    downloadedBytes: max(0, received),
                    totalBytes: expected > 0 ? expected : transfer.download.fileSize
                )
            }
        }
    }

    private static func finishTransfer(
        _ downloadID: UUID,
        response: URLResponse?,
        error: Error?
    ) {
        guard let transfer = transfers[downloadID], let manager = transfer.manager else {
            cleanupTransfer(downloadID)
            return
        }
        transfer.mimeType = response?.mimeType
        if let finalURL = response?.url, finalURL != transfer.download.originalURL {
            let previousURL = transfer.download.originalURL
            transfer.download.originalURL = finalURL
            transfer.download.originalURLString = finalURL.absoluteString
            try? manager.modelContext.save()
            didChangeURL(transfer.download, previousURL: previousURL)
        }

        if transfer.cancelledByUser {
            manager.cancelDownload(transfer.download)
        } else if let error {
            manager.failDownload(transfer.download, error: error.localizedDescription)
        } else {
            let received = transfer.task?.countOfBytesReceived ?? transfer.download.downloadedBytes
            let expected = transfer.task?.countOfBytesExpectedToReceive ?? transfer.download.fileSize
            manager.updateDownloadProgress(
                transfer.download,
                downloadedBytes: max(0, received),
                totalBytes: expected > 0 ? expected : max(0, received)
            )
            manager.completeDownload(transfer.download, destinationURL: transfer.destinationURL)
        }
        cleanupTransfer(downloadID)
    }

    private static func cleanupTransfer(_ id: UUID) {
        progressTimers[id]?.invalidate()
        progressTimers[id] = nil
        transfers[id] = nil
    }

    private static func pause(arguments: [Any], manager: DownloadManager) throws -> Any {
        let transfer = try activeTransfer(arguments: arguments, manager: manager)
        guard !transfer.paused else { return NSNull() }
        transfer.task?.suspend()
        transfer.paused = true
        emitChanged([
            "id": numericID(transfer.download.id),
            "paused": change(previous: false, current: true)
        ])
        return NSNull()
    }

    private static func resume(arguments: [Any], manager: DownloadManager) throws -> Any {
        let transfer = try activeTransfer(arguments: arguments, manager: manager)
        guard transfer.paused else { return NSNull() }
        transfer.task?.resume()
        transfer.paused = false
        emitChanged([
            "id": numericID(transfer.download.id),
            "paused": change(previous: true, current: false)
        ])
        return NSNull()
    }

    private static func cancel(arguments: [Any], manager: DownloadManager) throws -> Any {
        let transfer = try activeTransfer(arguments: arguments, manager: manager)
        transfer.cancelledByUser = true
        transfer.task?.cancel()
        return NSNull()
    }

    private static func activeTransfer(
        arguments: [Any],
        manager: DownloadManager
    ) throws -> Transfer {
        let download = try downloadForID(arguments.first, manager: manager)
        guard let transfer = transfers[download.id], transfer.task?.state != .completed else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "The download is not an active extension-managed transfer."
            )
        }
        return transfer
    }

    private static func open(arguments: [Any], manager: DownloadManager) throws -> Any {
        let download = try downloadForID(arguments.first, manager: manager)
        guard let url = download.destinationURL,
              FileManager.default.fileExists(atPath: url.path)
        else {
            throw MozillaNativeAPIBridge.BridgeError.itemNotFound(
                "The downloaded file no longer exists."
            )
        }
        guard NSWorkspace.shared.open(url) else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "macOS could not open the downloaded file."
            )
        }
        return NSNull()
    }

    private static func show(arguments: [Any], manager: DownloadManager) throws -> Any {
        let download = try downloadForID(arguments.first, manager: manager)
        guard let url = download.destinationURL else {
            throw MozillaNativeAPIBridge.BridgeError.itemNotFound(
                "The download does not have a destination file yet."
            )
        }
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
        return NSNull()
    }

    private static func erase(arguments: [Any], manager: DownloadManager) throws -> [Int] {
        let matches = try matchingDownloads(
            query: arguments.first as? [String: Any] ?? [:],
            manager: manager
        ).filter { transfers[$0.id] == nil }
        for download in matches {
            manager.modelContext.delete(download)
        }
        try manager.modelContext.save()
        for download in matches {
            didErase(download)
        }
        manager.reloadDownloadsForExtensionAPI()
        return matches.map { numericID($0.id) }
    }

    private static func removeFile(arguments: [Any], manager: DownloadManager) throws -> Any {
        let download = try downloadForID(arguments.first, manager: manager)
        guard transfers[download.id] == nil,
              let url = download.destinationURL,
              FileManager.default.fileExists(atPath: url.path)
        else {
            throw MozillaNativeAPIBridge.BridgeError.itemNotFound(
                "The downloaded file does not exist or the transfer is still active."
            )
        }
        try FileManager.default.removeItem(at: url)
        emitChanged([
            "id": numericID(download.id),
            "exists": change(previous: true, current: false)
        ])
        return NSNull()
    }

    private static func fileIcon(arguments: [Any], manager: DownloadManager) throws -> String {
        let download = try downloadForID(arguments.first, manager: manager)
        let options = arguments.dropFirst().first as? [String: Any] ?? [:]
        let size = min(127, max(16, integer(options["size"]) ?? 32))
        let path = download.destinationURL?.path ?? download.fileName
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: size, height: size)
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "macOS could not render an icon for the download."
            )
        }
        return "data:image/png;base64,\(png.base64EncodedString())"
    }

    private static func search(arguments: [Any], manager: DownloadManager) throws -> [[String: Any]] {
        let query = arguments.first as? [String: Any] ?? [:]
        return try matchingDownloads(query: query, manager: manager).map(downloadItem)
    }

    private static func matchingDownloads(
        query: [String: Any],
        manager: DownloadManager
    ) throws -> [Download] {
        let descriptor = FetchDescriptor<Download>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        var downloads = try manager.modelContext.fetch(descriptor)
        try validateRegex(query["filenameRegex"] as? String)
        try validateRegex(query["urlRegex"] as? String)
        downloads = downloads.filter { matches($0, query: query) }
        downloads = sort(downloads, orderBy: query["orderBy"] as? [String] ?? ["-startTime"])
        if let limit = integer(query["limit"]), limit >= 0 {
            downloads = Array(downloads.prefix(limit))
        }
        return downloads
    }

    private static func matches(_ download: Download, query: [String: Any]) -> Bool {
        if let requestedID = integer(query["id"]), requestedID != numericID(download.id) {
            return false
        }
        if let url = query["url"] as? String, url != download.originalURLString {
            return false
        }
        if let filename = query["filename"] as? String,
           filename != effectiveFilename(download)
        {
            return false
        }
        if let state = query["state"] as? String, state != state(for: download.status) {
            return false
        }
        if let paused = query["paused"] as? Bool,
           paused != (transfers[download.id]?.paused ?? false)
        {
            return false
        }
        if let exists = query["exists"] as? Bool,
           exists != fileExists(download)
        {
            return false
        }
        if let greater = int64(query["totalBytesGreater"]), download.fileSize <= greater {
            return false
        }
        if let less = int64(query["totalBytesLess"]), download.fileSize >= less {
            return false
        }
        if let after = date(query["startedAfter"]), download.createdAt <= after {
            return false
        }
        if let before = date(query["startedBefore"]), download.createdAt >= before {
            return false
        }
        if let after = date(query["endedAfter"]),
           (download.completedAt == nil || download.completedAt! <= after)
        {
            return false
        }
        if let before = date(query["endedBefore"]),
           (download.completedAt == nil || download.completedAt! >= before)
        {
            return false
        }
        if let regex = query["filenameRegex"] as? String,
           effectiveFilename(download).range(of: regex, options: .regularExpression) == nil
        {
            return false
        }
        if let regex = query["urlRegex"] as? String,
           download.originalURLString.range(of: regex, options: .regularExpression) == nil
        {
            return false
        }
        if !matchesTerms(download, rawTerms: query["query"]) {
            return false
        }
        return true
    }

    private static func matchesTerms(_ download: Download, rawTerms: Any?) -> Bool {
        let terms: [String]
        if let array = rawTerms as? [String] {
            terms = array
        } else if let single = rawTerms as? String {
            terms = [single]
        } else {
            return true
        }
        let haystack = (download.originalURLString + " " + effectiveFilename(download)).lowercased()
        for term in terms where !term.isEmpty {
            if term.hasPrefix("-") {
                if haystack.contains(String(term.dropFirst()).lowercased()) {
                    return false
                }
            } else if !haystack.contains(term.lowercased()) {
                return false
            }
        }
        return true
    }

    private static func sort(_ downloads: [Download], orderBy: [String]) -> [Download] {
        downloads.sorted { lhs, rhs in
            for rawField in orderBy {
                let descending = rawField.hasPrefix("-")
                let field = descending ? String(rawField.dropFirst()) : rawField
                let comparison = compare(lhs, rhs, field: field)
                guard comparison != 0 else { continue }
                return descending ? comparison > 0 : comparison < 0
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private static func compare(_ lhs: Download, _ rhs: Download, field: String) -> Int {
        switch field {
        case "startTime":
            return lhs.createdAt.compare(rhs.createdAt).rawValue
        case "endTime":
            return (lhs.completedAt ?? .distantPast).compare(rhs.completedAt ?? .distantPast).rawValue
        case "filename":
            return effectiveFilename(lhs).localizedStandardCompare(effectiveFilename(rhs)).rawValue
        case "url":
            return lhs.originalURLString.localizedStandardCompare(rhs.originalURLString).rawValue
        case "totalBytes", "fileSize":
            return lhs.fileSize == rhs.fileSize ? 0 : (lhs.fileSize < rhs.fileSize ? -1 : 1)
        case "bytesReceived":
            return lhs.downloadedBytes == rhs.downloadedBytes ? 0 : (lhs.downloadedBytes < rhs.downloadedBytes ? -1 : 1)
        default:
            return 0
        }
    }

    private static func downloadForID(_ value: Any?, manager: DownloadManager) throws -> Download {
        guard let requestedID = integer(value) else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "A numeric browser.downloads ID is required."
            )
        }
        let descriptor = FetchDescriptor<Download>()
        guard let download = try manager.modelContext.fetch(descriptor)
            .first(where: { numericID($0.id) == requestedID })
        else {
            throw MozillaNativeAPIBridge.BridgeError.itemNotFound(
                "The requested download does not exist."
            )
        }
        return download
    }

    private static func downloadItem(_ download: Download) -> [String: Any] {
        let transfer = transfers[download.id]
        var item: [String: Any] = [
            "id": numericID(download.id),
            "url": download.originalURLString,
            "filename": effectiveFilename(download),
            "danger": "safe",
            "state": state(for: download.status),
            "paused": transfer?.paused ?? false,
            "canResume": transfer != nil && download.status == .downloading,
            "bytesReceived": download.downloadedBytes,
            "totalBytes": download.fileSize,
            "fileSize": download.fileSize,
            "exists": fileExists(download),
            "incognito": false,
            "startTime": isoFormatter.string(from: download.createdAt)
        ]
        if let completedAt = download.completedAt {
            item["endTime"] = isoFormatter.string(from: completedAt)
        }
        if download.status == .failed || download.status == .cancelled {
            item["error"] = interruptReason(for: download)
        }
        if let mime = transfer?.mimeType {
            item["mime"] = mime
        }
        return item
    }

    private static func effectiveFilename(_ download: Download) -> String {
        if let transfer = transfers[download.id] {
            return transfer.destinationURL.path
        }
        if let destination = download.destinationURL {
            return destination.path
        }
        return download.fileName
    }

    private static func fileExists(_ download: Download) -> Bool {
        guard let destination = download.destinationURL else { return false }
        return FileManager.default.fileExists(atPath: destination.path)
    }

    private static func state(for status: DownloadStatus) -> String {
        switch status {
        case .pending, .downloading:
            return "in_progress"
        case .completed:
            return "complete"
        case .failed, .cancelled:
            return "interrupted"
        }
    }

    private static func interruptReason(for download: Download) -> String {
        download.status == .cancelled ? "USER_CANCELED" : "NETWORK_FAILED"
    }

    private static func emitChanged(_ delta: [String: Any]) {
        MozillaNativeAPIBridge.shared.emit(
            namespace: "downloads",
            event: "onChanged",
            arguments: [delta]
        )
    }

    private static func change(previous: Any, current: Any) -> [String: Any] {
        ["previous": previous, "current": current]
    }

    private static func numericID(_ uuid: UUID) -> Int {
        let digest = SHA256.hash(data: Data(uuid.uuidString.utf8))
        let raw = digest.prefix(4).reduce(UInt32(0)) { value, byte in
            (value << 8) | UInt32(byte)
        } & 0x7FFF_FFFF
        return Int(raw == 0 ? 1 : raw)
    }

    private static func validateRegex(_ value: String?) throws {
        guard let value else { return }
        do {
            _ = try NSRegularExpression(pattern: value)
        } catch {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "Invalid browser.downloads regular expression: \(value)."
            )
        }
    }

    private static func date(_ value: Any?) -> Date? {
        if let date = value as? Date {
            return date
        }
        if let string = value as? String {
            return isoFormatter.date(from: string)
        }
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue / 1_000)
        }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        return value as? Int
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        return value as? Int64
    }
}
