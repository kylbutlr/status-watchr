import AppKit
import SwiftUI
import XCTest
@testable import StatusWatchr

final class CompactMenuTests: XCTestCase {
    func testMenuBarOnlyEntryPointDoesNotRegisterAnEmptySettingsWindow() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/StatusWatchrApp.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertFalse(text.contains("Settings {"))
        XCTAssertFalse(text.contains("WindowGroup {"))
    }
    @MainActor
    func testClickRouting() {
        XCTAssertFalse(StatusItemController.showsContextMenu(type: .leftMouseUp, modifiers: []))
        XCTAssertFalse(StatusItemController.showsContextMenu(type: nil, modifiers: []))
        XCTAssertTrue(StatusItemController.showsContextMenu(type: .rightMouseUp, modifiers: []))
        XCTAssertTrue(StatusItemController.showsContextMenu(type: .leftMouseUp, modifiers: .control))
    }

    @MainActor
    func testContextActionsAndUpdaterAvailability() {
        let target = NSObject()
        for enabled in [true, false] {
            let menu = StatusItemController.makeMenu(target: target, updatesEnabled: enabled)
            let items = menu.items.filter { !$0.isSeparatorItem }
            XCTAssertEqual(items.map(\.title), ["Open dashboard", "Troubleshooting", "Export diagnostics…", "Check for updates…", "Quit Status Watchr"])
            XCTAssertEqual(items[3].isEnabled, enabled)
            XCTAssertFalse(menu.autoenablesItems)
            for item in items {
                XCTAssertTrue(item.target === target)
                XCTAssertNotNil(item.action)
            }
        }
    }

    @MainActor
    func testExportIsValidJSONWithPrivatePermissionsAndRetention() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let history = DiagnosticHistory(directory: directory, now: now)
        history.record(.attention, category: .approvalHook, now: now)
        let destination = directory.appendingPathComponent("export.json")
        try history.export(to: destination, now: now)
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["category"] as? String, "approvalHook")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int, 0o600)
        try history.export(to: destination, now: now.addingTimeInterval(8 * 86_400))
        let expired = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [Any])
        XCTAssertTrue(expired.isEmpty)
        XCTAssertThrowsError(try history.export(to: directory.appendingPathComponent("missing/export.json")))
    }

    @MainActor
    func testRenderCompactPanelWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["WATCHR_PANEL_RENDER"] else {
            throw XCTSkip("Native render artifact is opt-in.")
        }
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = ConnectorController(diagnostics: DiagnosticHistory(directory: directory), previewOnly: true)
        let view = NSHostingView(rootView: MenuBarView(controller: controller)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.appearance = NSAppearance(named: .darkAqua)
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        XCTAssertLessThan(view.frame.height, 600)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
    }
}
