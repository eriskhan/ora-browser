import Foundation
@preconcurrency import WebKit

extension OraChromeExtensionAPIHost {
    func handlePageCapture(method: String, args: [Any], spaceID: UUID) async throws -> Any? {
        guard method == "saveAsMHTML" else {
            throw BridgeError.unsupportedMethod("pageCapture", method)
        }
        let details = dictionaryArgument(args)
        guard let tab = try resolveOraTab(from: details["__oraTab"], spaceID: spaceID),
              let webView = tab.browserPage?.webExtensionWebView
        else {
            throw BridgeError.invalidArguments("pageCapture.saveAsMHTML could not resolve the requested Ora tab.")
        }

        let webArchiveData = try await withCheckedThrowingContinuation { continuation in
            webView.createWebArchiveData { result in
                continuation.resume(with: result)
            }
        }
        let mhtml = try WebArchiveMHTMLConverter.convert(webArchiveData)
        return [
            "__oraBlobBase64": mhtml.base64EncodedString(),
            "__oraBlobType": "multipart/related"
        ]
    }

    func resolveOraTab(from rawMetadata: Any?, spaceID: UUID) throws -> Tab? {
        let manager = try tabManager(for: spaceID)
        guard let container = manager.containers.first(where: { $0.id == spaceID }) else { return nil }
        let orderedTabs = container.tabs.sorted { $0.order < $1.order }
        guard let metadata = rawMetadata as? [String: Any] else {
            return manager.activeTab?.container.id == spaceID ? manager.activeTab : nil
        }

        let requestedURL = metadata["url"] as? String ?? metadata["pendingUrl"] as? String
        if let index = (metadata["index"] as? NSNumber)?.intValue,
           orderedTabs.indices.contains(index)
        {
            let indexedTab = orderedTabs[index]
            if requestedURL == nil || indexedTab.url.absoluteString == requestedURL {
                return indexedTab
            }
        }
        if (metadata["active"] as? Bool) == true,
           let active = manager.activeTab,
           active.container.id == spaceID,
           requestedURL == nil || active.url.absoluteString == requestedURL
        {
            return active
        }
        if let requestedURL {
            return orderedTabs.first(where: {
                $0.url.absoluteString == requestedURL || $0.browserPage?.currentURL?.absoluteString == requestedURL
            })
        }
        return nil
    }
}
