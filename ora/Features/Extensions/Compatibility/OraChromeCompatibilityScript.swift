enum OraChromeCompatibilityScript {
    static var source: String {
        [
            OraChromeAPIBridgeScript.source,
            OraChromeTabGroupBridgeScript.source,
            OraChromeUserScriptsBridgeScript.source
        ].joined(separator: "\n")
    }
}
