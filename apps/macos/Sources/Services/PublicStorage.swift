import Foundation

// Public source builds never inherit the private pilot's connection preferences.
var watchrPreferences: UserDefaults {
    UserDefaults(suiteName: "com.kylbutlr.statuswatchr.public")!
}
