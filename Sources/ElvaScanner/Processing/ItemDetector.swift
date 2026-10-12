import Foundation
import CoreGraphics

/// Finds the items lying on the glass (photos, cards, documents) in a low-resolution preview.
///
/// The scanner lid is a bright, neutral background. Pixels that are clearly darker or more
/// colourful than it are marked as foreground, the mask is coarsened into ~1.5 mm cells and
/// dilated so that light areas inside a photo don't split it, and each connected blob becomes an
/// item. Blobs smaller than ~1.5 cm are treated as dust.
enum ItemDetector {
    /// Returns item rectangles in inches (origin top-left of the glass), sorted in reading order.
    static func detect(in image: CGImage, bedWidth: Double, bedHeight: Double) -> [ScanArea] {
        let w = image.width, h = image.height
        guard w > 16, h > 16 else { return [] }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))   // row 0 = top of the glass

        let inchPerPx = bedWidth / Double(w)
        func luma(_ i: Int) -> Int { (Int(px[i]) * 54 + Int(px[i + 1]) * 183 + Int(px[i + 2]) * 19) >> 8 }
        func chroma(_ i: Int) -> Int {
            let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
            return max(r, g, b) - min(r, g, b)
        }

        // Background level from the border (the lid around the items).
        let edge = 3
        var border: [Int] = []
        for x in stride(from: edge, to: w - edge, by: 2) {
            border.append(luma(4 * (edge * w + x))); border.append(luma(4 * ((h - 1 - edge) * w + x)))
        }
        for y in stride(from: edge, to: h - edge, by: 2) {
            border.append(luma(4 * (y * w + edge))); border.append(luma(4 * (y * w + w - 1 - edge)))
        }
        border.sort()
        let background = border[border.count * 3 / 4]
        let lumaCut = background - 18

        // Coarse grid of ~1.5 mm cells.
        let cellPx = max(2, Int((0.06 / inchPerPx).rounded()))
        let gw = (w + cellPx - 1) / cellPx, gh = (h + cellPx - 1) / cellPx
        var grid = [Bool](repeating: false, count: gw * gh)
        for gy in 0..<gh {
            for gx in 0..<gw {
                var hits = 0, total = 0
                for y in (gy * cellPx)..<min(h, (gy + 1) * cellPx) where y >= edge && y < h - edge {
                    for x in (gx * cellPx)..<min(w, (gx + 1) * cellPx) where x >= edge && x < w - edge {
                        let i = 4 * (y * w + x)
                        total += 1
                        if luma(i) < lumaCut || chroma(i) > 28 { hits += 1 }
                    }
                }
                grid[gy * gw + gx] = total > 0 && hits * 4 >= total
            }
        }

        // Dilate by ~3 mm so pale regions inside a photo don't break it apart.
        let r = 2
        var dilated = grid
        for gy in 0..<gh {
            for gx in 0..<gw where grid[gy * gw + gx] {
                for dy in -r...r {
                    for dx in -r...r {
                        let x = gx + dx, y = gy + dy
                        if x >= 0, y >= 0, x < gw, y < gh { dilated[y * gw + x] = true }
                    }
                }
            }
        }

        // Connected components → bounding boxes (in grid cells).
        var label = [Int](repeating: 0, count: gw * gh)
        var boxes: [(x0: Int, y0: Int, x1: Int, y1: Int)] = []
        for start in 0..<(gw * gh) where dilated[start] && label[start] == 0 {
            let id = boxes.count + 1
            var stack = [start]
            label[start] = id
            var b = (x0: Int.max, y0: Int.max, x1: Int.min, y1: Int.min)
            while let c = stack.popLast() {
                let cx = c % gw, cy = c / gw
                b = (min(b.x0, cx), min(b.y0, cy), max(b.x1, cx), max(b.y1, cy))
                for (nx, ny) in [(cx - 1, cy), (cx + 1, cy), (cx, cy - 1), (cx, cy + 1)]
                where nx >= 0 && ny >= 0 && nx < gw && ny < gh {
                    let n = ny * gw + nx
                    if dilated[n] && label[n] == 0 { label[n] = id; stack.append(n) }
                }
            }
            boxes.append(b)
        }

        let cellInch = Double(cellPx) * inchPerPx
        let minSide = 0.6
        var items: [ScanArea] = boxes.compactMap { b in
            // Undo the dilation, then add a small safety margin.
            let margin = 0.04
            var x0 = Double(b.x0 + r) * cellInch - margin
            var y0 = Double(b.y0 + r) * cellInch - margin
            var x1 = Double(b.x1 - r + 1) * cellInch + margin
            var y1 = Double(b.y1 - r + 1) * cellInch + margin
            // Items pushed into a corner touch the glass edge, which is not analysed; snap to it.
            let snap = 0.16
            if x0 < snap { x0 = 0 }
            if y0 < snap { y0 = 0 }
            if x1 > bedWidth - snap { x1 = bedWidth }
            if y1 > bedHeight - snap { y1 = bedHeight }
            guard x1 - x0 >= minSide, y1 - y0 >= minSide else { return nil }
            let a = ScanArea(x: max(0, x0), y: max(0, y0), width: x1 - x0, height: y1 - y0)
            return a.clamped(toWidth: bedWidth, height: bedHeight)
        }
        items = mergeOverlapping(items)
        // Reading order: rows top→bottom, then left→right.
        return items.sorted { a, b in
            abs(a.y - b.y) < 0.5 ? a.x < b.x : a.y < b.y
        }
    }

    private static func mergeOverlapping(_ input: [ScanArea]) -> [ScanArea] {
        var items = input
        var merged = true
        while merged {
            merged = false
            outer: for i in items.indices {
                for j in items.indices where j > i {
                    let a = items[i], b = items[j]
                    if a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY {
                        items[i] = ScanArea.union([a, b])!
                        items.remove(at: j)
                        merged = true
                        break outer
                    }
                }
            }
        }
        return items
    }
}
