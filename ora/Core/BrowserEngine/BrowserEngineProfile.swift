import Foundation
@preconcurrency import WebKit

final class BrowserEngineProfile {
    let identifier: UUID
    let isPrivate: Bool
    let dataStore: WKWebsiteDataStore

    init(identifier: UUID, isPrivate: Bool) {
        self.identifier = identifier
        self.isPrivate = isPrivate
        if isPrivate {
            dataStore = WKWebsiteDataStore.nonPersistent()
        } else {
            dataStore = WKWebsiteDataStore(forIdentifier: identifier)
        }
    }

    func clearData(
        ofTypes types: Set<BrowserWebsiteDataType>,
        modifiedSince: Date = .distantPast,
        forHost host: String? = nil,
        completion: (() -> Void)? = nil
    ) {
        let mappedTypes = mapWebsiteDataTypes(types)
        guard let host, !host.isEmpty else {
            dataStore.removeData(ofTypes: mappedTypes, modifiedSince: modifiedSince) {
                completion?()
            }
            return
        }

        dataStore.fetchDataRecords(ofTypes: mappedTypes) { records in
            let targetRecords = records.filter { record in
                let recordHost = record.displayName.lowercased()
                let requestedHost = host.lowercased()
                return recordHost == requestedHost || recordHost.hasSuffix(".\(requestedHost)")
            }
            guard !targetRecords.isEmpty else {
                completion?()
                return
            }

            self.dataStore.removeData(ofTypes: mappedTypes, for: targetRecords) {
                completion?()
            }
        }
    }

    private func mapWebsiteDataTypes(_ types: Set<BrowserWebsiteDataType>) -> Set<String> {
        if types.contains(.all) {
            return WKWebsiteDataStore.allWebsiteDataTypes()
        }

        var mapped: Set<String> = []
        if types.contains(.cookies) {
            mapped.insert(WKWebsiteDataTypeCookies)
        }
        if types.contains(.cache) {
            mapped.formUnion([
                WKWebsiteDataTypeDiskCache,
                WKWebsiteDataTypeMemoryCache,
                WKWebsiteDataTypeFetchCache
            ])
        }
        if types.contains(.localStorage) {
            mapped.insert(WKWebsiteDataTypeLocalStorage)
            mapped.insert(WKWebsiteDataTypeSessionStorage)
        }
        if types.contains(.indexedDB) {
            mapped.insert(WKWebsiteDataTypeIndexedDBDatabases)
        }
        if types.contains(.serviceWorkers) {
            mapped.insert(WKWebsiteDataTypeServiceWorkerRegistrations)
        }
        return mapped
    }
}
