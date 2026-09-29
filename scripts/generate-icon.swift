import AppKit
import Foundation

// Vector source for the shipped app icon. Run: swift scripts/generate-icon.swift <iconset-directory>
let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let background = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 192, yRadius: 192)
        NSGradient(starting: NSColor(srgbRed: 0.18, green: 0.48, blue: 0.91, alpha: 1), ending: NSColor(srgbRed: 0.23, green: 0.25, blue: 0.66, alpha: 1))!.draw(in: background, angle: -90)
        // Three proportional storage blocks, with a generous optical inset.
        NSColor.white.withAlphaComponent(0.97).setFill()
        NSBezierPath(roundedRect: NSRect(x: 244, y: 244, width: 228, height: 536), xRadius: 38, yRadius: 38).fill()
        NSColor.white.withAlphaComponent(0.80).setFill()
        NSBezierPath(roundedRect: NSRect(x: 500, y: 484, width: 280, height: 296), xRadius: 38, yRadius: 38).fill()
        NSColor.white.withAlphaComponent(0.58).setFill()
        NSBezierPath(roundedRect: NSRect(x: 500, y: 244, width: 280, height: 212), xRadius: 38, yRadius: 38).fill()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
    }
}
