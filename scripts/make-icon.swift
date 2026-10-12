// Renders the app icon set: swift scripts/make-icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.52, blue: 0.98, alpha: 1),
                        NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.78, alpha: 1)])!
        .draw(in: shape, angle: -90)
    // Scan line
    let line = NSRect(x: rect.minX + rect.width * 0.12, y: rect.midY - s * 0.012,
                      width: rect.width * 0.76, height: s * 0.024)
    NSColor(calibratedRed: 0.6, green: 1, blue: 0.85, alpha: 0.95).setFill()
    NSBezierPath(roundedRect: line, xRadius: s * 0.012, yRadius: s * 0.012).fill()
    if let symbol = NSImage(systemSymbolName: "scanner", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: s * 0.36, weight: .regular)) {
        let tinted = NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let sz = tinted.size
        tinted.draw(in: NSRect(x: (s - sz.width) / 2, y: rect.minY + rect.height * 0.14, width: sz.width, height: sz.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
