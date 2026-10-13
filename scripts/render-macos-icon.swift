#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: render-macos-icon.swift <output.png>\n".utf8))
    exit(64)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let pixelSize = 1_024
guard
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ),
    let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap)
else {
    FileHandle.standardError.write(Data("Unable to create icon graphics context.\n".utf8))
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext
defer { NSGraphicsContext.restoreGraphicsState() }

let context = graphicsContext.cgContext
context.setShouldAntialias(true)
context.clear(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))

let iconRect = CGRect(x: 92, y: 92, width: 840, height: 840)
let iconPath = NSBezierPath(roundedRect: iconRect, xRadius: 190, yRadius: 190)
let gradient = NSGradient(colors: [
    NSColor(red: 13 / 255, green: 13 / 255, blue: 13 / 255, alpha: 1),
    NSColor(red: 59 / 255, green: 65 / 255, blue: 69 / 255, alpha: 1),
    NSColor(red: 137 / 255, green: 159 / 255, blue: 152 / 255, alpha: 1),
], atLocations: [0, 0.48, 1], colorSpace: .deviceRGB)!
gradient.draw(in: iconPath, angle: 45)

func drawArc(_ points: (CGPoint, CGPoint, CGPoint, CGPoint), width: CGFloat, opacity: CGFloat = 1) {
    context.setStrokeColor(NSColor.white.withAlphaComponent(opacity).cgColor)
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.beginPath()
    context.move(to: points.0)
    context.addCurve(to: points.3, control1: points.1, control2: points.2)
    context.strokePath()
}

drawArc((CGPoint(x: 382, y: 652), CGPoint(x: 294, y: 576), CGPoint(x: 294, y: 448), CGPoint(x: 382, y: 372)), width: 58)
drawArc((CGPoint(x: 642, y: 652), CGPoint(x: 730, y: 576), CGPoint(x: 730, y: 448), CGPoint(x: 642, y: 372)), width: 58)
drawArc((CGPoint(x: 292, y: 732), CGPoint(x: 142, y: 610), CGPoint(x: 142, y: 414), CGPoint(x: 292, y: 292)), width: 38, opacity: 0.82)
drawArc((CGPoint(x: 732, y: 732), CGPoint(x: 882, y: 610), CGPoint(x: 882, y: 414), CGPoint(x: 732, y: 292)), width: 38, opacity: 0.82)

context.setFillColor(NSColor.white.cgColor)
context.fillEllipse(in: CGRect(x: 455, y: 455, width: 114, height: 114))

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Unable to encode icon PNG.\n".utf8))
    exit(1)
}

try png.write(to: outputURL, options: .atomic)
