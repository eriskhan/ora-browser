import Foundation
import SwiftData

struct HistoryVisitRecord: Codable, Hashable {
    let id: UUID
    let visitedAt: Date
    let transition: String
    let referringVisitID: UUID?
}

/// SwiftData model for a browsing history entry
@Model
final class History {
    @Attribute(.unique) var id: UUID // Unique identifier
    var url: URL
    var urlString: String
    var title: String
    var faviconURL: URL
    var faviconLocalFile: URL?
    var createdAt: Date
    var visitCount: Int
    var lastAccessedAt: Date
    var visitRecordsData: Data = Data()

    @Relationship(inverse: \TabContainer.history) var container: TabContainer?

    var visitRecords: [HistoryVisitRecord] {
        get {
            guard !visitRecordsData.isEmpty,
                  let records = try? JSONDecoder().decode([HistoryVisitRecord].self, from: visitRecordsData)
            else {
                return []
            }
            return records
        }
        set {
            visitRecordsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        faviconURL: URL,
        faviconLocalFile: URL? = nil,
        createdAt: Date,
        lastAccessedAt: Date,
        visitCount: Int,
        container: TabContainer? = nil,
        initialVisit: HistoryVisitRecord? = nil
    ) {
        self.id = id
        self.url = url
        self.urlString = url.absoluteString
        self.title = title
        self.faviconURL = faviconURL
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
        self.visitCount = visitCount
        self.faviconLocalFile = faviconLocalFile
        self.container = container
        if let initialVisit {
            self.visitRecordsData = (try? JSONEncoder().encode([initialVisit])) ?? Data()
        } else {
            self.visitRecordsData = Data()
        }
    }

    @discardableResult
    func appendVisit(
        at date: Date,
        transition: String,
        referringVisitID: UUID?
    ) -> HistoryVisitRecord {
        let record = HistoryVisitRecord(
            id: UUID(),
            visitedAt: date,
            transition: transition,
            referringVisitID: referringVisitID
        )
        var records = visitRecords
        records.append(record)
        visitRecords = records
        visitCount += 1
        lastAccessedAt = date
        return record
    }
}
