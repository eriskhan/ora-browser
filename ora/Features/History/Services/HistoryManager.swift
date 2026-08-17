import CryptoKit
import Foundation
import os.log
import SwiftData

private let logger = Logger(subsystem: "com.orabrowser.ora", category: "HistoryManager")

@MainActor
class HistoryManager: ObservableObject {
    let modelContainer: ModelContainer
    let modelContext: ModelContext

    init(modelContainer: ModelContainer, modelContext: ModelContext) {
        self.modelContainer = modelContainer
        self.modelContext = modelContext
    }

    @discardableResult
    func record(
        title: String,
        url: URL,
        faviconURL: URL? = nil,
        faviconLocalFile: URL? = nil,
        container: TabContainer,
        transition: BrowserHistoryTransition = .typed,
        referringURL: URL? = nil,
        isPrivate: Bool = false
    ) -> HistoryVisitRecord? {
        let urlString = url.absoluteString
        let containerId = container.id
        let now = Date()

        let descriptor = FetchDescriptor<History>(
            predicate: #Predicate { history in
                history.urlString == urlString && history.container?.id == containerId
            },
            sortBy: [.init(\.lastAccessedAt, order: .reverse)]
        )
        let referringVisitID = referringURL.flatMap { latestVisitID(for: $0, containerID: containerId) }
        let previousTitle = (try? modelContext.fetch(descriptor).first)?.title
        let visit: HistoryVisitRecord
        let visitCount: Int

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.title = title
            if let faviconURL {
                existing.faviconURL = faviconURL
            }
            if let faviconLocalFile {
                existing.faviconLocalFile = faviconLocalFile
            }
            visit = existing.appendVisit(
                at: now,
                transition: transition.rawValue,
                referringVisitID: referringVisitID
            )
            visitCount = existing.visitCount
        } else {
            let defaultFaviconURL = FaviconService.shared.faviconURL(for: url.host ?? "")
            let resolvedFaviconURL = faviconURL ?? defaultFaviconURL ?? url
            visit = HistoryVisitRecord(
                id: UUID(),
                visitedAt: now,
                transition: transition.rawValue,
                referringVisitID: referringVisitID
            )
            modelContext.insert(History(
                url: url,
                title: title,
                faviconURL: resolvedFaviconURL,
                faviconLocalFile: faviconLocalFile,
                createdAt: now,
                lastAccessedAt: now,
                visitCount: 1,
                container: container,
                initialVisit: visit
            ))
            visitCount = 1
        }

        do {
            try modelContext.save()
        } catch {
            logger.error("Failed to save history visit: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        guard !isPrivate else { return visit }
        let item: [String: Any] = [
            "id": stableHistoryIdentifier(for: urlString),
            "url": urlString,
            "title": title,
            "lastVisitTime": now.timeIntervalSince1970 * 1_000,
            "visitCount": visitCount
        ]
        MozillaNativeAPIBridge.shared.emit(namespace: "history", event: "onVisited", arguments: [item])
        if let previousTitle, previousTitle != title {
            MozillaNativeAPIBridge.shared.emit(
                namespace: "history",
                event: "onTitleChanged",
                arguments: [["id": item["id"]!, "url": urlString, "title": title]]
            )
        }
        return visit
    }

    func search(_ text: String, activeContainerId: UUID) -> [History] {
        let trimmedText = text.trimmingCharacters(in: .whitespaces)
        let descriptor = FetchDescriptor<History>(
            predicate: #Predicate { $0.container?.id == activeContainerId },
            sortBy: [SortDescriptor(\.lastAccessedAt, order: .reverse)]
        )

        do {
            let histories = try modelContext.fetch(descriptor)

            guard !trimmedText.isEmpty else {
                return histories
            }

            return histories.filter { history in
                history.urlString.localizedStandardContains(trimmedText) ||
                    history.title.localizedStandardContains(trimmedText)
            }
        } catch {
            logger.error("Error fetching history: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    func clearContainerHistory(_ container: TabContainer) {
        let containerId = container.id
        let descriptor = FetchDescriptor<History>(
            predicate: #Predicate { $0.container?.id == containerId }
        )

        do {
            let histories = try modelContext.fetch(descriptor)
            let urls = histories.map(\.urlString)

            for history in histories {
                modelContext.delete(history)
            }

            try modelContext.save()
            if !urls.isEmpty {
                MozillaNativeAPIBridge.shared.emit(
                    namespace: "history",
                    event: "onVisitRemoved",
                    arguments: [["allHistory": false, "urls": Array(Set(urls))]]
                )
            }
        } catch {
            logger.error("Failed to clear history for container \(container.id): \(error.localizedDescription)")
        }
    }

    private func latestVisitID(for url: URL, containerID: UUID) -> UUID? {
        let urlString = url.absoluteString
        let descriptor = FetchDescriptor<History>(
            predicate: #Predicate { history in
                history.urlString == urlString && history.container?.id == containerID
            },
            sortBy: [SortDescriptor(\.lastAccessedAt, order: .reverse)]
        )
        guard let history = try? modelContext.fetch(descriptor).first else { return nil }
        return history.visitRecords.max(by: { $0.visitedAt < $1.visitedAt })?.id
    }

    private func stableHistoryIdentifier(for url: String) -> String {
        let digest = SHA256.hash(data: Data(url.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
