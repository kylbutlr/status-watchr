import AppKit
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: StatusItemController?
    private var updater: SPUStandardUpdaterController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let enabled = Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
            && Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String != "REPLACE_WITH_STATUS_WATCHR_SPARKLE_PUBLIC_KEY"
        let updater = SPUStandardUpdaterController(startingUpdater: enabled, updaterDelegate: nil, userDriverDelegate: nil)
        self.updater = updater
        menuBar = StatusItemController(controller: ConnectorController(), updatesEnabled: enabled) {
            updater.checkForUpdates(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) { ConnectionTelemetry.recorder.flush(cleanShutdown: true) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
enum StatusWatchrApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        // AppKit owns the menu item and popover. No placeholder SwiftUI scene
        // should become a blank Settings window when this app is opened.
        withExtendedLifetime(delegate) { application.run() }
    }
}
