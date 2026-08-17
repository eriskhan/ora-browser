enum OraChromeCompatibilityScript {
    static var source: String {
        OraChromeAPIBridgeScript.source + "\n" + OraChromeTabGroupBridgeScript.source
    }
}
