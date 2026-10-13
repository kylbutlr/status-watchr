import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let controller: ConnectorController
    private let updatesEnabled: Bool
    private let checkForUpdates: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var stateSubscription: AnyCancellable?
    private var troubleshootingWindow: NSWindow?

    static func showsContextMenu(type: NSEvent.EventType?, modifiers: NSEvent.ModifierFlags) -> Bool {
        type == .rightMouseUp || modifiers.contains(.control)
    }

    init(controller: ConnectorController, updatesEnabled: Bool, checkForUpdates: @escaping () -> Void) {
        self.controller = controller
        self.updatesEnabled = updatesEnabled
        self.checkForUpdates = checkForUpdates
        super.init()
        popover.behavior = .transient
        let hosting = NSHostingController(rootView: MenuBarView(controller: controller))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.contentSize = hosting.view.fittingSize
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        stateSubscription = controller.$state.sink { [weak self] state in
            self?.statusItem.button?.image = MenuBarIcon.image(for: state)
            self?.statusItem.button?.toolTip = "Status Watchr: \(state.label). Right-click for actions."
            self?.statusItem.button?.setAccessibilityLabel("Status Watchr: \(state.label)")
        }
    }

    @objc private func clicked() {
        guard let button = statusItem.button else { return }
        if Self.showsContextMenu(type: NSApp.currentEvent?.type, modifiers: NSApp.currentEvent?.modifierFlags ?? []) {
            popover.performClose(nil)
            statusItem.menu = Self.makeMenu(target: self, updatesEnabled: updatesEnabled)
            button.performClick(nil)
            statusItem.menu = nil
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    static func makeMenu(target: AnyObject, updatesEnabled: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add("Open dashboard", #selector(openDashboard))
        menu.addItem(.separator())
        add("Troubleshooting", #selector(showTroubleshooting))
        add("Export diagnostics…", #selector(exportDiagnostics))
        add("Check for updates…", #selector(update), enabled: updatesEnabled)
        menu.addItem(.separator())
        add("Quit Status Watchr", #selector(quit))
        return menu
    }

    @objc private func openDashboard() {
        if let url = URL(string: controller.siteURL) { NSWorkspace.shared.open(url) }
    }
    @objc private func update() { checkForUpdates() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func exportDiagnostics() {
        controller.exportDiagnostics()
        if let message = controller.diagnosticMessage {
            let alert = NSAlert()
            alert.messageText = "Diagnostics export failed"
            alert.informativeText = message
            alert.runModal()
        }
    }
    @objc private func showTroubleshooting() {
        if troubleshootingWindow == nil {
            let hosting = NSHostingController(rootView: TroubleshootingView(controller: controller))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Status Watchr Troubleshooting"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            troubleshootingWindow = window
        }
        troubleshootingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct TroubleshootingView: View {
    @ObservedObject var controller: ConnectorController
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Codex hooks").font(.headline)
            Text(controller.hookReadiness.rawValue)
            Text(controller.lastHookAt == nil ? "No hook received this launch." : "Hook received this launch.")
            Text("Question detection remains unverified.").foregroundStyle(.secondary)
            Link("Hook trust guide", destination: URL(string: "https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks")!)
            Divider()
            Text("Last successful scan: \(controller.lastScanLabel)")
            if let degraded = controller.sourceDegradedLabel { Text(degraded).foregroundStyle(.red) }
            Text("Queued locally: \(controller.pendingEventCount)")
            Text("Scanned: \(controller.scannedThreadCount) local tasks")
            Text("Matched: \(controller.matchedThreadCount), sent: \(controller.sentEventCount) events")
        }
        .font(.callout)
        .padding(20)
        .frame(width: 360, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
