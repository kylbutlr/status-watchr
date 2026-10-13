import AppKit

/// A template mask lets macOS choose the correct tint for the menu-bar background.
/// Only the observing state is filled; all other states retain a transparent center.
@MainActor
enum MenuBarIcon {
    static func image(for state: ConnectorController.State) -> NSImage {
        let glyph: String?
        switch state {
        case .connected, .stopped, .paused: glyph = nil
        case .starting: glyph = "ellipsis"
        case .needsYou: glyph = "exclamationmark"
        case .failed: glyph = "xmark"
        }
        let filled = state == .connected
        // Match the default SF Symbol sizing used by App Switchr and Todo Trackr.
        let circle = NSImage(systemSymbolName: filled ? "circle.fill" : "circle", accessibilityDescription: nil)!
        let symbol = glyph.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) }
        let image = NSImage(size: circle.size, flipped: false) { _ in
            circle.draw(in: NSRect(origin: .zero, size: circle.size))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current?.cgContext.scaleBy(x: circle.size.width / 18, y: circle.size.height / 18)
            // SF Symbols include optical padding; keep the bars inside that outline.
            NSGraphicsContext.current?.cgContext.translateBy(x: 1.17, y: 1.17)
            NSGraphicsContext.current?.cgContext.scaleBy(x: 0.87, y: 0.87)
            NSColor.black.set()
            if glyph == nil {
                NSGraphicsContext.saveGraphicsState()
                if filled { NSGraphicsContext.current?.cgContext.setBlendMode(.clear) }
                for index in 0..<3 {
                    // Same baseline and spacing; stopped bars collapse to 1.53 points.
                    let height: CGFloat = filled ? [4.5, 7.2, 9.9][index] : 1.53
                    let rect = NSRect(x: 4.23 + CGFloat(index) * 3.42, y: 4.05, width: 2.52, height: height)
                    NSBezierPath(roundedRect: rect, xRadius: 0.45, yRadius: 0.45).fill()
                }
                NSGraphicsContext.restoreGraphicsState()
            } else if state == .needsYou {
                // Draw the attention mark explicitly: the SF Symbol's intrinsic
                // padding made it too small after fitting inside the circle.
                NSBezierPath(roundedRect: NSRect(x: 7.4, y: 7, width: 3.2, height: 7), xRadius: 1.2, yRadius: 1.2).fill()
                NSBezierPath(ovalIn: NSRect(x: 7.4, y: 3, width: 3.2, height: 3.2)).fill()
            } else if case .failed = state {
                // Reach the circle's inner edge at each diagonal. The SF Symbol
                // shrinks to an indistinct mark at menu-bar size.
                let cross = NSBezierPath()
                cross.lineWidth = 2.35
                cross.lineCapStyle = .round
                cross.move(to: NSPoint(x: 4.3, y: 4.3))
                cross.line(to: NSPoint(x: 13.7, y: 13.7))
                cross.move(to: NSPoint(x: 13.7, y: 4.3))
                cross.line(to: NSPoint(x: 4.3, y: 13.7))
                cross.stroke()
            } else if let symbol {
                let scale = min(8 / symbol.size.width, 10.5 / symbol.size.height)
                let size = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
                symbol.draw(in: NSRect(x: (18 - size.width) / 2, y: (18 - size.height) / 2, width: size.width, height: size.height),
                            from: .zero, operation: filled ? .destinationOut : .sourceOver, fraction: 1)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Status Watchr: \(state.label)"
        return image
    }
}
