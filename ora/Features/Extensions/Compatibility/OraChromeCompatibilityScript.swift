enum OraChromeCompatibilityScript {
    static var source: String {
        [
            OraChromeAPIBridgeScript.source,
            OraChromeTabGroupBridgeScript.source,
            OraChromeUserScriptsBridgeScript.source,
            OraChromeDeclarativeContentBridgeScript.source
        ].joined(separator: "\n")
    }
}
