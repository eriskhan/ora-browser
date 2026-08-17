import Foundation

extension Tab {
    func updateHistory(
        transition: BrowserHistoryTransition,
        referringURL: URL?
    ) {
        guard let historyManager else { return }
        Task { @MainActor in
            historyManager.record(
                title: self.title,
                url: self.url,
                faviconURL: self.favicon,
                faviconLocalFile: self.faviconLocalFile,
                container: self.container,
                transition: transition,
                referringURL: referringURL,
                isPrivate: self.isPrivate
            )
        }
    }
}
