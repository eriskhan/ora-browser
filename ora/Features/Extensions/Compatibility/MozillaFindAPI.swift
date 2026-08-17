import Foundation
@preconcurrency import WebKit

@MainActor
enum MozillaFindAPI {
    static func handle(
        method: String,
        arguments: [Any],
        context: WKWebExtensionContext,
        manager: ExtensionManager
    ) async throws -> Any {
        try MozillaNativeAPIRouter.require("find", context: context, manager: manager)
        let page = try activePage(context: context)

        switch method {
        case "find":
            return try await find(arguments: arguments, page: page)
        case "highlightResults":
            return try await highlight(arguments: arguments, page: page)
        case "removeHighlighting":
            _ = try await evaluate(removeHighlightingScript, page: page)
            return NSNull()
        default:
            throw MozillaNativeAPIBridge.BridgeError.unsupportedMethod("find", method)
        }
    }

    private static func find(arguments: [Any], page: BrowserPage) async throws -> Any {
        guard let phrase = arguments.first as? String else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "browser.find.find requires a search phrase."
            )
        }
        let options = arguments.dropFirst().first as? [String: Any] ?? [:]
        try rejectExplicitTab(options)
        guard !phrase.isEmpty else {
            _ = try await evaluate(removeHighlightingScript, page: page)
            return ["count": 0]
        }

        let phraseLiteral = jsonLiteral(phrase)
        let caseSensitive = options["caseSensitive"] as? Bool ?? false
        let entireWord = options["entireWord"] as? Bool ?? false
        let includeRangeData = options["includeRangeData"] as? Bool ?? false
        let includeRectData = options["includeRectData"] as? Bool ?? false
        let matchDiacritics = options["matchDiacritics"] as? Bool ?? false

        let script = #"""
        (() => {
            const phrase = __PHRASE__;
            const caseSensitive = __CASE_SENSITIVE__;
            const entireWord = __ENTIRE_WORD__;
            const includeRangeData = __RANGE_DATA__;
            const includeRectData = __RECT_DATA__;
            const matchDiacritics = __MATCH_DIACRITICS__;

            function removeHighlights() {
                try { CSS.highlights && CSS.highlights.delete("ora-extension-find"); } catch (_error) {}
                document.getElementById("ora-extension-find-style")?.remove();
                const markers = Array.from(document.querySelectorAll("mark[data-ora-extension-find]"));
                for (const marker of markers) marker.replaceWith(document.createTextNode(marker.textContent || ""));
                if (markers.length) document.normalize();
            }

            function fold(value) {
                let result = "";
                const map = [];
                for (let index = 0; index < value.length; index++) {
                    let piece = value[index];
                    if (!matchDiacritics) piece = piece.normalize("NFD").replace(/\p{M}/gu, "");
                    if (!caseSensitive) piece = piece.toLocaleLowerCase();
                    for (let offset = 0; offset < piece.length; offset++) {
                        result += piece[offset];
                        map.push(index);
                    }
                }
                return { result, map };
            }

            function isWordCharacter(character) {
                return Boolean(character && /[\p{L}\p{N}_]/u.test(character));
            }

            removeHighlights();
            const foldedPhrase = fold(phrase).result;
            const ranges = [];
            const rangeData = [];
            const rectData = [];
            const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
            let node;
            let textNodePos = -1;

            while ((node = walker.nextNode())) {
                textNodePos++;
                const parent = node.parentElement;
                if (!parent || ["SCRIPT", "STYLE", "NOSCRIPT", "TEXTAREA"].includes(parent.tagName)) continue;
                const text = node.nodeValue || "";
                if (!text) continue;
                const folded = fold(text);
                let searchFrom = 0;

                while (searchFrom <= folded.result.length - foldedPhrase.length) {
                    const foldedIndex = folded.result.indexOf(foldedPhrase, searchFrom);
                    if (foldedIndex < 0) break;
                    const foldedEnd = foldedIndex + foldedPhrase.length;
                    const startOffset = folded.map[foldedIndex] ?? foldedIndex;
                    const lastOriginal = folded.map[Math.max(foldedIndex, foldedEnd - 1)] ?? startOffset;
                    const endOffset = Math.min(text.length, lastOriginal + 1);
                    searchFrom = Math.max(foldedIndex + 1, foldedEnd);

                    if (entireWord) {
                        const before = startOffset > 0 ? text[startOffset - 1] : "";
                        const after = endOffset < text.length ? text[endOffset] : "";
                        if (isWordCharacter(before) || isWordCharacter(after)) continue;
                    }

                    const range = document.createRange();
                    range.setStart(node, startOffset);
                    range.setEnd(node, endOffset);
                    if (range.getClientRects().length === 0) continue;
                    ranges.push(range);

                    if (includeRangeData) {
                        rangeData.push({
                            framePos: 0,
                            startTextNodePos: textNodePos,
                            endTextNodePos: textNodePos,
                            startOffset,
                            endOffset
                        });
                    }
                    if (includeRectData) {
                        const rects = Array.from(range.getClientRects());
                        rectData.push({
                            text: range.toString(),
                            rectsAndTexts: {
                                rectList: rects.map((rect) => ({
                                    top: Math.round(rect.top),
                                    left: Math.round(rect.left),
                                    bottom: Math.round(rect.bottom),
                                    right: Math.round(rect.right)
                                })),
                                textList: rects.map(() => range.toString())
                            }
                        });
                    }
                }
            }

            globalThis.__oraExtensionFindState = { ranges };
            const result = { count: ranges.length };
            if (includeRangeData) result.rangeData = rangeData;
            if (includeRectData) result.rectData = rectData;
            return result;
        })();
        """#
            .replacingOccurrences(of: "__PHRASE__", with: phraseLiteral)
            .replacingOccurrences(of: "__CASE_SENSITIVE__", with: jsBoolean(caseSensitive))
            .replacingOccurrences(of: "__ENTIRE_WORD__", with: jsBoolean(entireWord))
            .replacingOccurrences(of: "__RANGE_DATA__", with: jsBoolean(includeRangeData))
            .replacingOccurrences(of: "__RECT_DATA__", with: jsBoolean(includeRectData))
            .replacingOccurrences(of: "__MATCH_DIACRITICS__", with: jsBoolean(matchDiacritics))

        return try await evaluate(script, page: page)
    }

    private static func highlight(arguments: [Any], page: BrowserPage) async throws -> Any {
        let options = arguments.first as? [String: Any] ?? [:]
        try rejectExplicitTab(options)
        let rangeIndex = integer(options["rangeIndex"])
        let noScroll = options["noScroll"] as? Bool ?? true
        let rangeLiteral = rangeIndex.map(String.init) ?? "null"

        let script = #"""
        (() => {
            const state = globalThis.__oraExtensionFindState;
            if (!state || !Array.isArray(state.ranges)) return;
            const rangeIndex = __RANGE_INDEX__;
            const ranges = rangeIndex === null
                ? state.ranges
                : (state.ranges[rangeIndex] ? [state.ranges[rangeIndex]] : []);
            if (!ranges.length) return;

            try { CSS.highlights && CSS.highlights.delete("ora-extension-find"); } catch (_error) {}
            document.getElementById("ora-extension-find-style")?.remove();
            const oldMarkers = Array.from(document.querySelectorAll("mark[data-ora-extension-find]"));
            for (const marker of oldMarkers) marker.replaceWith(document.createTextNode(marker.textContent || ""));
            if (oldMarkers.length) document.normalize();

            if (globalThis.Highlight && CSS.highlights) {
                const highlight = new Highlight(...ranges);
                CSS.highlights.set("ora-extension-find", highlight);
                const style = document.createElement("style");
                style.id = "ora-extension-find-style";
                style.textContent = "::highlight(ora-extension-find){background:#ffcc00;color:#000}";
                (document.head || document.documentElement).appendChild(style);
            } else {
                for (const range of [...ranges].reverse()) {
                    if (range.startContainer !== range.endContainer) continue;
                    const marker = document.createElement("mark");
                    marker.dataset.oraExtensionFind = "true";
                    marker.style.background = "#ffcc00";
                    marker.style.color = "#000";
                    try { range.surroundContents(marker); } catch (_error) {}
                }
            }

            if (!__NO_SCROLL__) {
                const first = ranges[0];
                const element = first.startContainer.parentElement;
                if (element) element.scrollIntoView({ block: "center", inline: "nearest" });
            }
        })();
        """#
            .replacingOccurrences(of: "__RANGE_INDEX__", with: rangeLiteral)
            .replacingOccurrences(of: "__NO_SCROLL__", with: jsBoolean(noScroll))

        _ = try await evaluate(script, page: page)
        return NSNull()
    }

    private static let removeHighlightingScript = #"""
    (() => {
        try { CSS.highlights && CSS.highlights.delete("ora-extension-find"); } catch (_error) {}
        document.getElementById("ora-extension-find-style")?.remove();
        const markers = Array.from(document.querySelectorAll("mark[data-ora-extension-find]"));
        for (const marker of markers) marker.replaceWith(document.createTextNode(marker.textContent || ""));
        if (markers.length) document.normalize();
    })();
    """#

    private static func activePage(context: WKWebExtensionContext) throws -> BrowserPage {
        let windows = [context.focusedWindow].compactMap { $0 as? OraWebExtensionWindow } +
            context.openWindows.compactMap { $0 as? OraWebExtensionWindow }
        for window in windows {
            if let page = window.tabManager?.activeTab?.browserPage,
               let scheme = page.currentURL?.scheme?.lowercased(),
               scheme == "http" || scheme == "https"
            {
                return page
            }
        }
        throw MozillaNativeAPIBridge.BridgeError.unavailableBrowserWindow
    }

    private static func rejectExplicitTab(_ options: [String: Any]) throws {
        guard options["tabId"] == nil else {
            throw MozillaNativeAPIBridge.BridgeError.invalidArguments(
                "Ora currently supports browser.find only in the active tab."
            )
        }
    }

    private static func evaluate(_ script: String, page: BrowserPage) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            page.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result ?? NSNull())
                }
            }
        }
    }

    private static func jsonLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        return string
    }

    private static func jsBoolean(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        return value as? Int
    }
}
