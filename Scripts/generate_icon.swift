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
    // A broad open book with its outer page corners lifting up from the spine.
    // The larger, unruled silhouette stays recognizable at Dock and menu sizes.
    let left = NSBezierPath()
    left.move(to: point(0.485, 0.76, size))
    left.curve(to: point(0.045, 0.90, size), controlPoint1: point(0.35, 0.88, size), controlPoint2: point(0.17, 0.93, size))
    left.line(to: point(0.045, 0.15, size))
    left.curve(to: point(0.485, 0.25, size), controlPoint1: point(0.18, 0.21, size), controlPoint2: point(0.36, 0.22, size))
    left.close()
    paper.setFill()
    left.fill()

    let right = NSBezierPath()
    right.move(to: point(0.515, 0.76, size))
    right.curve(to: point(0.955, 0.90, size), controlPoint1: point(0.65, 0.88, size), controlPoint2: point(0.83, 0.93, size))
    right.line(to: point(0.955, 0.15, size))
    right.curve(to: point(0.515, 0.25, size), controlPoint1: point(0.82, 0.21, size), controlPoint2: point(0.64, 0.22, size))
    right.close()
    paper.setFill()
    right.fill()

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode icon")
    }
    try png.write(to: output.appendingPathComponent(filename))
    if pixels == 1024 {
        try png.write(to: output.deletingLastPathComponent().appendingPathComponent("AppIcon.png"))
    }
}
