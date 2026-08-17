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

    func record(
        title: String,
        url: URL,
        faviconURL: URL? = nil,
        faviconLocalFile: URL? = nil,
        container: TabContainer
    ) {
        let urlString = url.absoluteString
        let containerId = container.id

        // Keep history entries scoped to a space so visits from different spaces
        // do not overwrite each other or become unreachable from space filters.
        let descriptor = FetchDescriptor<History>(
            predicate: #Predicate { history in
                history.urlString == urlString && history.container?.id == containerId
            },
            sortBy: [.init(\.lastAccessedAt, order: .reverse)]
        )

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.visitCount += 1
            existing.lastAccessedAt = Date() // update last visited time
        } else {
            let now = Date()
            let defaultFaviconURL = FaviconService.shared.faviconURL(for: url.host ?? "")
            let resolvedFaviconURL = faviconURL ?? defaultFaviconURL ?? url
            modelContext.insert(History(
                url: url,
                title: title,
                faviconURL: resolvedFaviconURL,
                faviconLocalFile: faviconLocalFile,
                createdAt: now,
                lastAccessedAt: now,
                visitCount: 1,
                container: container
            ))
        }

        try? modelContext.save()
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

            for history in histories {
                modelContext.delete(history)
            }

            try modelContext.save()
        } catch {
            logger.error("Failed to clear history for container \(container.id): \(error.localizedDescription)")
        }
    }
}
