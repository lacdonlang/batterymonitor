// Renders the BatteryMonitor app icon and the menu bar template glyph.
// Run: swift Scripts/render-app-icon.swift
//
// The app icon follows the macOS icon grid: a 1024pt canvas with an
// 824x824 continuous-corner tile, drop shadow, vertical brand gradient,
// a white battery glyph with a bolt cutout, and a top gloss highlight.
import AppKit

let appIconDir = "Resources/App/Assets.xcassets/AppIcon.appiconset"
let menuIconDir = "Resources/App/Assets.xcassets/MenuBarIcon.imageset"

// MARK: - Drawing helpers

func squirclePath(in rect: NSRect, cornerFraction: CGFloat = 0.225) -> NSBezierPath {
    // NSBezierPath rounded rect is close enough to Apple's squircle at icon sizes.
    NSBezierPath(roundedRect: rect, xRadius: rect.width * cornerFraction, yRadius: rect.width * cornerFraction)
}

func batteryGlyphPath(center: NSPoint, scale: CGFloat) -> (body: NSBezierPath, nub: NSBezierPath, bolt: NSBezierPath) {
    // Battery body sized on a 100x60 grid centered at `center`, scaled by `scale`.
    let bodyWidth: CGFloat = 100 * scale
    let bodyHeight: CGFloat = 62 * scale
    let bodyRect = NSRect(
        x: center.x - bodyWidth / 2 - 6 * scale,
        y: center.y - bodyHeight / 2,
        width: bodyWidth,
        height: bodyHeight
    )
    let body = NSBezierPath(roundedRect: bodyRect, xRadius: 14 * scale, yRadius: 14 * scale)

    let nubRect = NSRect(
        x: bodyRect.maxX + 4 * scale,
        y: center.y - 13 * scale,
        width: 9 * scale,
        height: 26 * scale
    )
    let nub = NSBezierPath(roundedRect: nubRect, xRadius: 4.5 * scale, yRadius: 4.5 * scale)

    // Lightning bolt inside the body, on a local 32x44 grid.
    let bolt = NSBezierPath()
    let bx = bodyRect.midX
    let by = bodyRect.midY
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: bx + x * scale, y: by + y * scale)
    }
    bolt.move(to: pt(6, 23))
    bolt.line(to: pt(-16, -4))
    bolt.line(to: pt(-3, -4))
    bolt.line(to: pt(-6, -23))
    bolt.line(to: pt(16, 4))
    bolt.line(to: pt(3, 4))
    bolt.close()
    return (body, nub, bolt)
}

// MARK: - App icon

func drawAppIcon(canvas: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: canvas, height: canvas))
    image.lockFocus()
    defer { image.unlockFocus() }

    let s = canvas / 1024
    let tileSize: CGFloat = 824 * s
    let tileRect = NSRect(
        x: (canvas - tileSize) / 2,
        y: (canvas - tileSize) / 2,
        width: tileSize,
        height: tileSize
    )
    let tile = squirclePath(in: tileRect)

    // Drop shadow behind the tile.
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.set()
    NSColor(calibratedRed: 0.13, green: 0.55, blue: 0.32, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Brand gradient: fresh green, light at the top.
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.36, green: 0.84, blue: 0.52, alpha: 1),
        ending: NSColor(calibratedRed: 0.05, green: 0.47, blue: 0.28, alpha: 1)
    )
    gradient?.draw(in: tile, angle: -90)

    // Soft radial glow behind the glyph so it pops.
    NSGraphicsContext.current?.saveGraphicsState()
    tile.addClip()
    let glow = NSGradient(
        starting: NSColor.white.withAlphaComponent(0.28),
        ending: NSColor.white.withAlphaComponent(0)
    )
    glow?.draw(
        fromCenter: NSPoint(x: tileRect.midX, y: tileRect.midY + 30 * s), radius: 0,
        toCenter: NSPoint(x: tileRect.midX, y: tileRect.midY + 30 * s), radius: tileSize * 0.55,
        options: []
    )
    NSGraphicsContext.current?.restoreGraphicsState()

    // Battery glyph: white body with the bolt punched out via even-odd fill,
    // so the tile gradient shows through the cutout.
    let glyphScale = 4.6 * s
    let (body, nub, bolt) = batteryGlyphPath(
        center: NSPoint(x: tileRect.midX, y: tileRect.midY),
        scale: glyphScale
    )
    let glyph = NSBezierPath()
    glyph.windingRule = .evenOdd
    glyph.append(body)
    glyph.append(bolt)
    glyph.append(nub)
    NSGraphicsContext.current?.saveGraphicsState()
    let glyphShadow = NSShadow()
    glyphShadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    glyphShadow.shadowBlurRadius = 12 * s
    glyphShadow.shadowOffset = NSSize(width: 0, height: -6 * s)
    glyphShadow.set()
    NSColor.white.setFill()
    glyph.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Gloss highlight: bright band across the upper half of the tile.
    NSGraphicsContext.current?.saveGraphicsState()
    tile.addClip()
    let glossRect = NSRect(
        x: tileRect.minX,
        y: tileRect.midY + tileSize * 0.02,
        width: tileSize,
        height: tileSize * 0.48
    )
    let gloss = NSBezierPath()
    gloss.move(to: NSPoint(x: glossRect.minX, y: glossRect.maxY))
    gloss.line(to: NSPoint(x: glossRect.maxX, y: glossRect.maxY))
    gloss.line(to: NSPoint(x: glossRect.maxX, y: glossRect.minY + tileSize * 0.10))
    gloss.curve(
        to: NSPoint(x: glossRect.minX, y: glossRect.minY),
        controlPoint1: NSPoint(x: glossRect.midX + tileSize * 0.18, y: glossRect.minY - tileSize * 0.055),
        controlPoint2: NSPoint(x: glossRect.midX - tileSize * 0.22, y: glossRect.minY - tileSize * 0.02)
    )
    gloss.close()
    let glossGradient = NSGradient(
        starting: NSColor.white.withAlphaComponent(0.32),
        ending: NSColor.white.withAlphaComponent(0.04)
    )
    glossGradient?.draw(in: gloss, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    return image
}

// MARK: - Menu bar template glyph

func drawMenuBarIcon(pointSize: CGFloat, scaleFactor: CGFloat) -> NSImage {
    let pixels = pointSize * scaleFactor
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    defer { image.unlockFocus() }

    let s = pixels / 190
    let (body, nub, bolt) = batteryGlyphPath(
        center: NSPoint(x: pixels / 2 - 1 * s, y: pixels / 2),
        scale: 1.5 * s
    )
    let glyph = NSBezierPath()
    glyph.windingRule = .evenOdd
    glyph.append(body)
    glyph.append(bolt)
    glyph.append(nub)
    NSColor.black.setFill()
    glyph.fill()
    return image
}

// MARK: - PNG output

func writePNG(_ image: NSImage, pixels: CGFloat, to path: String) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(pixels), pixelsHigh: Int(pixels),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

let master = drawAppIcon(canvas: 1024)
for (name, pixels) in [
    ("icon_16x16.png", CGFloat(16)), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
] {
    writePNG(master, pixels: pixels, to: "\(appIconDir)/\(name)")
}

writePNG(drawMenuBarIcon(pointSize: 18, scaleFactor: 1), pixels: 18, to: "\(menuIconDir)/menubar_18.png")
writePNG(drawMenuBarIcon(pointSize: 18, scaleFactor: 2), pixels: 36, to: "\(menuIconDir)/menubar_18@2x.png")
print("done")
