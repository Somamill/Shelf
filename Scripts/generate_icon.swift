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
    // A small, friendly open book. The outer page corners lift up from the spine.
    let left = NSBezierPath()
    left.move(to: point(0.485, 0.64, size))
    left.curve(to: point(0.17, 0.72, size), controlPoint1: point(0.36, 0.72, size), controlPoint2: point(0.23, 0.75, size))
    left.curve(to: point(0.17, 0.32, size), controlPoint1: point(0.14, 0.60, size), controlPoint2: point(0.14, 0.42, size))
    left.curve(to: point(0.485, 0.36, size), controlPoint1: point(0.26, 0.35, size), controlPoint2: point(0.39, 0.34, size))
    left.close()
    paper.setFill()
    left.fill()

    let right = NSBezierPath()
    right.move(to: point(0.515, 0.64, size))
    right.curve(to: point(0.83, 0.72, size), controlPoint1: point(0.64, 0.72, size), controlPoint2: point(0.77, 0.75, size))
    right.curve(to: point(0.83, 0.32, size), controlPoint1: point(0.86, 0.60, size), controlPoint2: point(0.86, 0.42, size))
    right.curve(to: point(0.515, 0.36, size), controlPoint1: point(0.74, 0.35, size), controlPoint2: point(0.61, 0.34, size))
    right.close()
    paper.setFill()
    right.fill()

    // A subtle warm center seam makes the silhouette feel softer at small sizes.
    NSColor(calibratedRed: 0.78, green: 0.72, blue: 0.58, alpha: 0.72).setStroke()
    let seam=NSBezierPath()
    seam.lineWidth=max(1,size*0.012)
    seam.move(to:point(0.5,0.34,size));seam.curve(to:point(0.5,0.68,size),controlPoint1:point(0.49,0.48,size),controlPoint2:point(0.51,0.58,size));seam.stroke()

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode icon")
    }
    try png.write(to: output.appendingPathComponent(filename))
    if pixels == 1024 {
        try png.write(to: output.deletingLastPathComponent().appendingPathComponent("AppIcon.png"))
    }
}
