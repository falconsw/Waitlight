// Draws Waitlight's app icon: a red waiting light inside a ring that counts the wait.
//   swift Scripts/make-icon.swift   → Sources/Assets.xcassets/AppIcon.appiconset + docs/icon.png
import AppKit

let iconset = URL(fileURLWithPath: "Sources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024
    let space = CGColorSpaceCreateDeviceRGB()

    // macOS icon grid: an 824pt square with a 100pt margin.
    let rect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(colors: [NSColor(red: 0.12, green: 0.14, blue: 0.19, alpha: 1),
                        NSColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1)])!
        .draw(in: squircle, angle: -90)
    NSColor.white.withAlphaComponent(0.06).setStroke()
    squircle.lineWidth = 3 * s
    squircle.stroke()

    let center = CGPoint(x: 512 * s, y: 512 * s)

    // The light's glow, kept inside the icon's shape.
    ctx.saveGState()
    squircle.addClip()
    let glow = CGGradient(colorsSpace: space,
                          colors: [NSColor(red: 1.0, green: 0.27, blue: 0.27, alpha: 0.55).cgColor,
                                   NSColor(red: 1.0, green: 0.27, blue: 0.27, alpha: 0).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: center, startRadius: 90 * s, endCenter: center, endRadius: 330 * s, options: [])
    ctx.restoreGState()

    // The ring: a dim track, and an amber arc from the top, the wait so far.
    let radius = 270 * s
    ctx.setLineCap(.round)
    ctx.setLineWidth(64 * s)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
    ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    let start = CGFloat.pi / 2
    let end = start - 0.38 * .pi * 2
    // Drawn as short round-capped pieces so the colour can run along the arc.
    let pieces = 80
    for i in 0..<pieces {
        let t = CGFloat(i) / CGFloat(pieces - 1)
        let angle = start + (end - start) * t
        let next = start + (end - start) * min(1, t + 1 / CGFloat(pieces - 1))
        ctx.setStrokeColor(NSColor(red: 1.0, green: 0.78 - 0.24 * t, blue: 0.24 - 0.04 * t, alpha: 1).cgColor)
        ctx.addArc(center: center, radius: radius, startAngle: angle, endAngle: next, clockwise: true)
        ctx.strokePath()
    }

    // The light itself.
    let dot = CGRect(x: center.x - 118 * s, y: center.y - 118 * s, width: 236 * s, height: 236 * s)
    ctx.saveGState()
    ctx.addEllipse(in: dot)
    ctx.clip()
    let red = CGGradient(colorsSpace: space,
                         colors: [NSColor(red: 1.0, green: 0.42, blue: 0.38, alpha: 1).cgColor,
                                  NSColor(red: 0.93, green: 0.20, blue: 0.24, alpha: 1).cgColor] as CFArray,
                         locations: [0, 1])!
    ctx.drawLinearGradient(red, start: CGPoint(x: dot.minX, y: dot.maxY), end: CGPoint(x: dot.maxX, y: dot.minY), options: [])
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ size: CGFloat, to url: URL) {
    try! draw(size).representation(using: .png, properties: [:])!.write(to: url)
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    write(CGFloat(points * scale), to: iconset.appendingPathComponent(name))
}
write(512, to: URL(fileURLWithPath: "docs/icon.png"))
