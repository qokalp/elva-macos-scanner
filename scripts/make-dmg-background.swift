// Draws the background of the DMG window: swift scripts/make-dmg-background.swift <out-dir>
// Writes background.png (660×460) and background@2x.png; make-dmg.sh merges them into one HiDPI TIFF.
// Icon positions must match scripts/dmg-settings.py (app at x=165, Applications at x=495, y=170).
// Layout fits in ~350 pt of visible height, because Finder on macOS 26 keeps its toolbar, path bar
// and status bar visible even when the DMG asks to hide them; the extra height covers windows without them.
import AppKit

let width: CGFloat = 660, height: CGFloat = 460
let iconY: CGFloat = 170              // icon centre, measured from the top (Finder coordinates)
let appX: CGFloat = 165, appsX: CGFloat = 495
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)   // drawing happens in points
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let bounds = NSRect(x: 0, y: 0, width: width, height: height)

    // Soft blue gradient, matching the app icon.
    NSGradient(colors: [NSColor(srgbRed: 0.97, green: 0.98, blue: 1.00, alpha: 1),
                        NSColor(srgbRed: 0.88, green: 0.92, blue: 0.99, alpha: 1)])!
        .draw(in: bounds, angle: -90)

    // Faint scan line across the window, echoing the icon.
    let lineY = height - iconY
    NSColor(srgbRed: 0.20, green: 0.52, blue: 0.98, alpha: 0.06).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: lineY - 34, width: width, height: 68)).fill()

    func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centreY: CGFloat) {
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                    .foregroundColor: color, .paragraphStyle: para]
        let str = NSAttributedString(string: s, attributes: attrs)
        let h = str.size().height
        str.draw(in: NSRect(x: 0, y: height - centreY - h / 2, width: width, height: h))
    }

    text("Elva Scanner", size: 24, weight: .semibold,
         color: NSColor(srgbRed: 0.10, green: 0.18, blue: 0.36, alpha: 1), centreY: 40)
    text("for macOS", size: 13, weight: .regular,
         color: NSColor(srgbRed: 0.30, green: 0.38, blue: 0.55, alpha: 1), centreY: 64)

    // Arrow from the app to the Applications folder.
    let blue = NSColor(srgbRed: 0.16, green: 0.45, blue: 0.95, alpha: 0.85)
    let startX = appX + 82, endX = appsX - 82
    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: startX, y: lineY))
    shaft.line(to: NSPoint(x: endX - 16, y: lineY))
    shaft.lineWidth = 5
    shaft.lineCapStyle = .round
    shaft.setLineDash([2, 11], count: 2, phase: 0)
    blue.setStroke()
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: endX, y: lineY))
    head.line(to: NSPoint(x: endX - 20, y: lineY + 13))
    head.line(to: NSPoint(x: endX - 20, y: lineY - 13))
    head.close()
    blue.setFill()
    head.fill()

    let grey = NSColor(srgbRed: 0.28, green: 0.33, blue: 0.43, alpha: 1)
    text("Drag Elva Scanner to your Applications folder", size: 13.5, weight: .medium, color: grey, centreY: 292)
    text("Elva Scanner'ı Uygulamalar klasörüne sürükleyin", size: 13.5, weight: .regular,
         color: grey.withAlphaComponent(0.8), centreY: 314)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try render(scale: 1).write(to: out.appendingPathComponent("background.png"))
try render(scale: 2).write(to: out.appendingPathComponent("background@2x.png"))
