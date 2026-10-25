import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let variants: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")
]

func point(_ x: CGFloat, _ y: CGFloat, _ size: CGFloat) -> NSPoint {
    NSPoint(x: x * size, y: y * size)
}

for (pixels, filename) in variants {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("Could not allocate icon bitmap") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let size = CGFloat(pixels)
    NSColor(calibratedRed: 0.14, green: 0.22, blue: 0.24, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                 xRadius: size * 0.23, yRadius: size * 0.23).fill()

    let paper = NSColor(calibratedRed: 0.96, green: 0.945, blue: 0.90, alpha: 1)
    let accent = NSColor(calibratedRed: 0.39, green: 0.69, blue: 0.63, alpha: 1)
    let left = NSBezierPath()
    left.move(to: point(0.49, 0.57, size))
    left.curve(to: point(0.20, 0.76, size), controlPoint1: point(0.39, 0.62, size), controlPoint2: point(0.28, 0.76, size))
    left.line(to: point(0.20, 0.34, size))
    left.curve(to: point(0.49, 0.43, size), controlPoint1: point(0.30, 0.29, size), controlPoint2: point(0.41, 0.42, size))
    left.close()
    paper.setFill()
    left.fill()

    let right = NSBezierPath()
    right.move(to: point(0.51, 0.57, size))
    right.curve(to: point(0.80, 0.76, size), controlPoint1: point(0.61, 0.62, size), controlPoint2: point(0.72, 0.76, size))
    right.line(to: point(0.80, 0.34, size))
    right.curve(to: point(0.51, 0.43, size), controlPoint1: point(0.70, 0.29, size), controlPoint2: point(0.59, 0.42, size))
    right.close()
    paper.setFill()
    right.fill()

    let spine = NSBezierPath()
    spine.lineWidth = max(1, size * 0.018)
    spine.lineCapStyle = .round
    spine.move(to: point(0.5, 0.445, size))
    spine.line(to: point(0.5, 0.575, size))
    NSColor(calibratedRed: 0.14, green: 0.22, blue: 0.24, alpha: 1).setStroke()
    spine.stroke()

    let pageLines = NSBezierPath()
    pageLines.lineWidth = max(1, size * 0.012)
    pageLines.lineCapStyle = .round
    pageLines.move(to: point(0.265, 0.64, size)); pageLines.line(to: point(0.425, 0.53, size))
    pageLines.move(to: point(0.265, 0.56, size)); pageLines.line(to: point(0.425, 0.49, size))
    pageLines.move(to: point(0.575, 0.53, size)); pageLines.line(to: point(0.735, 0.64, size))
    pageLines.move(to: point(0.575, 0.49, size)); pageLines.line(to: point(0.735, 0.56, size))
    accent.setStroke()
    pageLines.stroke()

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode icon")
    }
    try png.write(to: output.appendingPathComponent(filename))
}
