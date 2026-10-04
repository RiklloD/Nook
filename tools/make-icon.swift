// Draws Nook's app icon into Resources/AppIcon.icns: run `swift tools/make-icon.swift`.
import AppKit

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    // macOS icon grid: 824pt tile centered in 1024 with a soft shadow.
    let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSGradient(colors: [NSColor(red: 0.20, green: 0.21, blue: 0.27, alpha: 1), NSColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1)])!
        .draw(in: tilePath, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tilePath.addClip()
    // Soft glow under the island.
    NSGradient(colors: [NSColor(red: 0.55, green: 0.35, blue: 1, alpha: 0.45), .clear])!
        .draw(fromCenter: CGPoint(x: 512 * s, y: 600 * s), radius: 0, toCenter: CGPoint(x: 512 * s, y: 600 * s), radius: 360 * s, options: [])
    // The island: notch with concave ears hanging from the top edge.
    let w: CGFloat = 600 * s, h: CGFloat = 190 * s, ear: CGFloat = 34 * s, r: CGFloat = 80 * s
    let top = tile.maxY, x0 = 512 * s - w / 2
    let island = NSBezierPath()
    island.move(to: CGPoint(x: x0 - ear, y: top))
    island.curve(to: CGPoint(x: x0, y: top - ear), controlPoint1: CGPoint(x: x0 - ear / 2, y: top), controlPoint2: CGPoint(x: x0, y: top - ear / 2))
    island.line(to: CGPoint(x: x0, y: top - h + r))
    island.curve(to: CGPoint(x: x0 + r, y: top - h), controlPoint1: CGPoint(x: x0, y: top - h + r / 2), controlPoint2: CGPoint(x: x0 + r / 2, y: top - h))
    island.line(to: CGPoint(x: x0 + w - r, y: top - h))
    island.curve(to: CGPoint(x: x0 + w, y: top - h + r), controlPoint1: CGPoint(x: x0 + w - r / 2, y: top - h), controlPoint2: CGPoint(x: x0 + w, y: top - h + r / 2))
    island.line(to: CGPoint(x: x0 + w, y: top - ear))
    island.curve(to: CGPoint(x: x0 + w + ear, y: top), controlPoint1: CGPoint(x: x0 + w, y: top - ear / 2), controlPoint2: CGPoint(x: x0 + w + ear / 2, y: top))
    island.close()
    NSColor.black.setFill()
    island.fill()
    // Artwork tile on the left wing.
    let art = NSBezierPath(roundedRect: CGRect(x: x0 + 70 * s, y: top - 150 * s, width: 96 * s, height: 96 * s), xRadius: 24 * s, yRadius: 24 * s)
    NSGradient(colors: [NSColor(red: 1, green: 0.42, blue: 0.45, alpha: 1), NSColor(red: 0.55, green: 0.3, blue: 1, alpha: 1)])!.draw(in: art, angle: -45)
    // Equalizer on the right wing.
    let heights: [CGFloat] = [60, 96, 44, 78]
    for (i, bh) in heights.enumerated() {
        let bar = NSBezierPath(roundedRect: CGRect(x: x0 + w - 190 * s + CGFloat(i) * 30 * s, y: top - 150 * s, width: 18 * s, height: bh * s),
                               xRadius: 9 * s, yRadius: 9 * s)
        NSColor(red: 0.85, green: 0.65, blue: 1, alpha: 1).setFill()
        bar.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Nook.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(CGFloat(base * scale)).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! process.run()
process.waitUntilExit()
try! draw(512).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/nook-icon.png"))
print("Resources/AppIcon.icns")
