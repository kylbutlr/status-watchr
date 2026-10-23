import Foundation

// Keep the established app domain so an in-place 0.1.x upgrade retains its settings.
// New installations begin without saved preferences and use the local-server default.
var watchrPreferences: UserDefaults {
    let domain = "com.kylbutlr.statuswatchr"
    // Foundation rejects a suite named after the current app. The standard
    // store already uses that domain in the installed bundle.
    if Bundle.main.bundleIdentifier == domain { return .standard }
    return UserDefaults(suiteName: domain) ?? .standard
}
