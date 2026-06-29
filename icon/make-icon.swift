import AppKit

// Generates the Usage app icon at every iconset size into the directory passed as the first
// argument (default: ./Usage.iconset). Pure CoreGraphics so it's reproducible and dependency-free.
//
// The mark: a soft coral squircle with three clean white meter bars of descending length — the app's
// usage motif, pared down to its simplest form. Reads clearly at every size.

let base: CGFloat = 1024

func draw(s: CGFloat) {
    func P(_ v: CGFloat) -> CGFloat { v * s }
    func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    let center = NSPoint(x: P(512), y: P(512))
    let body = NSRect(x: P(100), y: P(100), width: P(824), height: P(824))
    let squircle = NSBezierPath(roundedRect: body, xRadius: P(186), yRadius: P(186))

    // Squircle base + soft drop shadow.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -P(16))
    shadow.shadowBlurRadius = P(34)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.set()
    col(255, 130, 108).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Coral gradient fill.
    if let bg = NSGradient(colors: [col(255, 148, 112), col(255, 99, 105)]) {
        bg.draw(in: squircle, angle: -90)
    }

    // Three white meter bars, centered, descending in length — a pared-down usage meter.
    NSColor.white.setFill()
    let barHeight = P(80)
    let barRadius = barHeight / 2
    let maxWidth = P(432)
    let centerSpacing = P(132)   // gap + height between adjacent bar centers
    let widthFractions: [CGFloat] = [1.0, 0.66, 0.42]
    for (index, fraction) in widthFractions.enumerated() {
        let width = maxWidth * fraction
        let centerY = center.y + CGFloat(1 - index) * centerSpacing
        let rect = NSRect(
            x: center.x - width / 2, y: centerY - barHeight / 2, width: width, height: barHeight)
        NSBezierPath(roundedRect: rect, xRadius: barRadius, yRadius: barRadius).fill()
    }
}

func render(px: Int) -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("Could not create bitmap rep") }
    rep.size = NSSize(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    guard let g = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("Could not create context") }
    NSGraphicsContext.current = g
    draw(s: CGFloat(px) / base)
    g.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode PNG")
    }
    return data
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Usage.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let specs: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (px, name) in specs {
    try! render(px: px).write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
print("Wrote \(specs.count) PNGs to \(outDir)")
