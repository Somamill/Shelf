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
    NSColor(calibratedRed: 0.97, green: 0.97, blue: 0.955, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                 xRadius: size * 0.23, yRadius: size * 0.23).fill()

    let ink = NSColor(calibratedRed: 0.48, green: 0.48, blue: 0.49, alpha: 1)
    let line = max(1.0, size * 0.029)
    let left = NSBezierPath()
    left.lineWidth = line
    left.lineCapStyle = .round
    left.lineJoinStyle = .round
    left.move(to: point(0.485, 0.68, size))
    left.curve(to: point(0.22, 0.63, size), controlPoint1: point(0.38, 0.67, size), controlPoint2: point(0.29, 0.63, size))
    left.line(to: point(0.22, 0.34, size))
    left.curve(to: point(0.485, 0.40, size), controlPoint1: point(0.30, 0.38, size), controlPoint2: point(0.40, 0.39, size))
    ink.setStroke()
    left.stroke()

    let right = NSBezierPath()
    right.lineWidth = line
    right.lineCapStyle = .round
    right.lineJoinStyle = .round
    right.move(to: point(0.515, 0.68, size))
    right.curve(to: point(0.78, 0.63, size), controlPoint1: point(0.62, 0.67, size), controlPoint2: point(0.71, 0.63, size))
    right.line(to: point(0.78, 0.34, size))
    right.curve(to: point(0.515, 0.40, size), controlPoint1: point(0.70, 0.38, size), controlPoint2: point(0.60, 0.39, size))
    ink.setStroke()
    right.stroke()

    let spine = NSBezierPath()
    spine.lineWidth = max(1, size * 0.026)
    spine.lineCapStyle = .round
    spine.move(to: point(0.5, 0.405, size))
    spine.line(to: point(0.5, 0.675, size))
    ink.setStroke()
    spine.stroke()

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode icon")
    }
    try png.write(to: output.appendingPathComponent(filename))
}
