import XCTest
import SwiftUI
import AppKit
@testable import StatusWatchr

final class MonitoringButtonRenderTests: XCTestCase {
    @MainActor
    func testRenderButtonStylesWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["WATCHR_BUTTON_RENDER"] else {
            throw XCTSkip("Native render artifact is opt-in.")
        }
        _ = NSApplication.shared
        let view = NSHostingView(rootView: VStack(spacing: 20) {
            Text("Stopped: Start monitoring")
            HStack {
                Text("Status Watchr").font(.headline)
                Spacer()
                MonitoringToggleButton(isRunning: false) {}
            }
            Text("Running: Stop monitoring")
            HStack {
                Text("Status Watchr").font(.headline)
                Spacer()
                MonitoringToggleButton(isRunning: true) {}
            }
        }.padding(18).frame(width: 330).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = NSRect(x: 0, y: 0, width: 330, height: 240)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
    }
}
