import Foundation

// Keep the established app domain so an in-place 0.1.x upgrade retains its settings.
// New installations begin without saved preferences and use the local-server default.
var watchrPreferences: UserDefaults {
    UserDefaults(suiteName: "com.kylbutlr.statuswatchr")!
}
