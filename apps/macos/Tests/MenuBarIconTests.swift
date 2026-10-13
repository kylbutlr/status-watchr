import AppKit
import XCTest
@testable import StatusWatchr

final class MenuBarIconTests: XCTestCase {
    @MainActor
    func testMatchesNeighborMenuBarSymbolSize() throws {
        for name in ["pause.circle", "bolt.circle.fill", "checkmark.circle.fill"] {
            let reference = try XCTUnwrap(NSImage(systemSymbolName: name, accessibilityDescription: nil))
            XCTAssertEqual(MenuBarIcon.image(for: .stopped).size, reference.size)
            XCTAssertEqual(MenuBarIcon.image(for: .paused).size, reference.size)
            XCTAssertEqual(MenuBarIcon.image(for: .connected).size, reference.size)
        }
    }
    @MainActor
    private func bitmap(_ state: ConnectorController.State) throws -> NSBitmapImageRep {
        let image = MenuBarIcon.image(for: state)
        // Normalize to the design grid for the existing foreground pixel assertions.
        let normalized = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
        return try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(normalized.tiffRepresentation)))
    }

    @MainActor
    func testAllStatesAreAccessibleAdaptiveTemplates() throws {
        for state: ConnectorController.State in [.stopped, .starting, .paused, .connected, .needsYou, .failed("private error")] {
            let image = MenuBarIcon.image(for: state)
            XCTAssertTrue(image.isTemplate)
            XCTAssertEqual(image.size, NSImage(systemSymbolName: "circle", accessibilityDescription: nil)!.size)
            XCTAssertEqual(image.accessibilityDescription, "Status Watchr: \(state.label)")
            XCTAssertNotNil(image.tiffRepresentation)
        }
    }

    @MainActor
    func testStoppedHasOutlineAndTransparentInteriorWhileActiveIsFilled() throws {
        let stopped = try bitmap(.stopped), paused = try bitmap(.paused), active = try bitmap(.connected)
        // Above the bars: solid interior for active, transparent interior for stopped.
        XCTAssertLessThan(try XCTUnwrap(stopped.colorAt(x: 9, y: 3)).alphaComponent, 0.15)
        XCTAssertLessThan(try XCTUnwrap(paused.colorAt(x: 9, y: 3)).alphaComponent, 0.15)
        XCTAssertGreaterThan(try XCTUnwrap(active.colorAt(x: 9, y: 3)).alphaComponent, 0.85)
        // The top of the stopped circle must still exist.
        XCTAssertGreaterThan(try XCTUnwrap(stopped.colorAt(x: 9, y: 1)).alphaComponent, 0.25)
        XCTAssertLessThan(try XCTUnwrap(active.colorAt(x: 0, y: 0)).alphaComponent, 0.1)
    }

    @MainActor
    func testBarsShareBaselineButOnlyActiveBarsRise() throws {
        let stopped = try bitmap(.stopped), active = try bitmap(.connected)
        // Bitmap coordinates are top-down. All three low stopped bars are visible.
        for x in [5, 9, 12] {
            XCTAssertGreaterThan(try XCTUnwrap(stopped.colorAt(x: x, y: 12)).alphaComponent, 0.3)
            XCTAssertLessThan(try XCTUnwrap(stopped.colorAt(x: x, y: 10)).alphaComponent, 0.1)
            XCTAssertLessThan(try XCTUnwrap(active.colorAt(x: x, y: 12)).alphaComponent, 0.3)
        }
        // Rising right bar is cut out above the short left bar.
        XCTAssertGreaterThan(try XCTUnwrap(active.colorAt(x: 5, y: 7)).alphaComponent, 0.85)
        XCTAssertLessThan(try XCTUnwrap(active.colorAt(x: 12, y: 7)).alphaComponent, 0.15)
    }

    @MainActor
    func testAttentionMarkHasThickStemAndSeparateDot() throws {
        let attention = try bitmap(.needsYou)
        for x in [8, 9] {
            XCTAssertGreaterThan(try XCTUnwrap(attention.colorAt(x: x, y: 6)).alphaComponent, 0.6)
            XCTAssertGreaterThan(try XCTUnwrap(attention.colorAt(x: x, y: 13)).alphaComponent, 0.6)
        }
        XCTAssertLessThan(try XCTUnwrap(attention.colorAt(x: 5, y: 6)).alphaComponent, 0.1)
    }

    @MainActor
    func testFailureCrossReachesCircleInterior() throws {
        let failed = try bitmap(.failed("private error"))
        for (x, y) in [(5, 5), (12, 5), (5, 12), (12, 12)] {
            XCTAssertGreaterThan(try XCTUnwrap(failed.colorAt(x: x, y: y)).alphaComponent, 0.4)
        }
        XCTAssertLessThan(try XCTUnwrap(failed.colorAt(x: 5, y: 9)).alphaComponent, 0.2)
    }

    @MainActor
    func testRenderSelectedIconsWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["WATCHR_ICON_RENDER"] else { return }
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1040, pixelsHigh: 360, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = NSSize(width: 520, height: 180)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.1, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 520, height: 180).fill()
        for (index, state) in [ConnectorController.State.connected, .needsYou, .stopped].enumerated() {
            let image = MenuBarIcon.image(for: state)
            let tinted = NSImage(size: image.size)
            tinted.lockFocus()
            image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.white.setFill()
            NSRect(origin: .zero, size: image.size).fill(using: .sourceIn)
            tinted.unlockFocus()
            let x = CGFloat(25 + index * 170)
            tinted.draw(in: NSRect(x: x, y: 72, width: 64, height: 64))
            tinted.draw(in: NSRect(x: x + 95, y: 95, width: image.size.width, height: image.size.height))
            (state.label as NSString).draw(at: NSPoint(x: x - 10, y: 36), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white])
        }
        NSGraphicsContext.restoreGraphicsState()
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
    }
}
