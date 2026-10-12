import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics

/// Non-destructive software adjustments. All math happens in gamma-encoded sRGB so that levels
/// computed from the rendered histogram map 1:1 onto filter parameters.
enum ImageProcessor {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let gray = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!

    static let context = CIContext(options: [
        .workingColorSpace: sRGB,
        .outputColorSpace: sRGB,
        .cacheIntermediates: false,
    ])

    /// Renders the adjusted image. `maxDimension` downsamples first (for on-screen previews).
    static func render(_ image: CGImage, mode: ColorMode, dpi: Int, adjustments adj: ImageAdjustments,
                       maxDimension: CGFloat? = nil) -> CGImage? {
        var ci = CIImage(cgImage: image)
        var scale: CGFloat = 1
        if let maxDimension {
            let longest = max(ci.extent.width, ci.extent.height)
            if longest > maxDimension {
                scale = maxDimension / longest
                let f = CIFilter.lanczosScaleTransform()
                f.inputImage = ci; f.scale = Float(scale); f.aspectRatio = 1
                ci = f.outputImage ?? ci
            }
        }
        ci = apply(adj, to: ci, mode: mode, effectiveDPI: Double(dpi) * Double(scale))
        let extent = ci.extent.integral
        if mode == .color {
            return context.createCGImage(ci, from: extent, format: .RGBA8, colorSpace: sRGB)
        }
        return context.createCGImage(ci, from: extent, format: .L8, colorSpace: gray)
    }

    static func apply(_ adj: ImageAdjustments, to input: CIImage, mode: ColorMode, effectiveDPI: Double) -> CIImage {
        var ci = input

        if adj.autoCrop, let crop = contentBounds(of: ci) {
            ci = ci.cropped(to: crop)
        }

        switch adj.negative {
        case .off: break
        case .color:
            let s = stats(ci)
            ci = levels(ci, low: s.low, high: s.high, invert: true)
        case .blackWhite:
            ci = desaturate(ci)
            let s = stats(ci)
            let lo = s.lumaLow, hi = s.lumaHigh
            ci = levels(ci, low: [lo, lo, lo], high: [hi, hi, hi], invert: true)
        }

        if adj.autoLevels {
            // One stretch for all channels (keeps colour balance), from luminance percentiles.
            let s = stats(ci)
            ci = levels(ci, low: [s.lumaLow, s.lumaLow, s.lumaLow], high: [s.lumaHigh, s.lumaHigh, s.lumaHigh], invert: false)
        }

        if adj.brightness != 0 || adj.contrast != 0 || adj.saturation != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = ci
            f.brightness = Float(adj.brightness * 0.25)
            f.contrast = Float(1 + adj.contrast * 0.5)
            f.saturation = Float(max(0, 1 + adj.saturation))
            ci = f.outputImage ?? ci
        }

        if adj.descreen {
            // Halftone screens are ~85–175 lpi; blur just enough to merge the dots at this resolution.
            let radius = max(0.5, effectiveDPI / 300 * 0.9)
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = ci.clampedToExtent(); blur.radius = Float(radius)
            if let out = blur.outputImage?.cropped(to: ci.extent) { ci = out }
        }

        if adj.sharpen > 0 {
            let f = CIFilter.unsharpMask()
            f.inputImage = ci.clampedToExtent()
            f.radius = Float(max(0.8, effectiveDPI / 300 * 1.5))
            f.intensity = Float(adj.sharpen * 1.2)
            if let out = f.outputImage?.cropped(to: ci.extent) { ci = out }
        }

        switch mode {
        case .color: break
        case .gray: ci = desaturate(ci)
        case .blackWhite:
            ci = desaturate(ci)
            let t = CIFilter.colorThreshold()
            t.inputImage = ci; t.threshold = Float(adj.threshold)
            ci = t.outputImage ?? ci
        }

        switch ((adj.rotation % 360) + 360) % 360 {
        case 90: ci = ci.oriented(.right)
        case 180: ci = ci.oriented(.down)
        case 270: ci = ci.oriented(.left)
        default: break
        }
        // Move the origin back to (0, 0) after crops/rotations.
        return ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
    }

    static func desaturate(_ ci: CIImage) -> CIImage {
        let f = CIFilter.colorControls()
        f.inputImage = ci; f.saturation = 0; f.brightness = 0; f.contrast = 1
        return f.outputImage ?? ci
    }

    /// out = (in − low) / (high − low), or (high − in) / (high − low) when inverting. Values 0…1.
    static func levels(_ ci: CIImage, low: [Double], high: [Double], invert: Bool) -> CIImage {
        func scaleAndBias(_ i: Int) -> (CGFloat, CGFloat) {
            let range = max(high[i] - low[i], 0.02)
            return invert ? (CGFloat(-1 / range), CGFloat(high[i] / range))
                          : (CGFloat(1 / range), CGFloat(-low[i] / range))
        }
        let (r, rb) = scaleAndBias(0), (g, gb) = scaleAndBias(1), (b, bb) = scaleAndBias(2)
        let f = CIFilter.colorMatrix()
        f.inputImage = ci
        f.rVector = CIVector(x: r, y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 0, y: g, z: 0, w: 0)
        f.bVector = CIVector(x: 0, y: 0, z: b, w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        f.biasVector = CIVector(x: rb, y: gb, z: bb, w: 0)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = f.outputImage
        return clamp.outputImage ?? ci
    }

    struct Stats {
        var low: [Double]; var high: [Double]
        var lumaLow: Double; var lumaHigh: Double
    }

    /// Per-channel 0.5 % / 99.5 % percentiles from a ≤256 px rendition.
    static func stats(_ ci: CIImage, lowPct: Double = 0.005, highPct: Double = 0.995) -> Stats {
        let (pixels, w, h) = thumbnailPixels(ci, maxSide: 256)
        let count = w * h
        guard count > 0 else { return Stats(low: [0, 0, 0], high: [1, 1, 1], lumaLow: 0, lumaHigh: 1) }
        var hist = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 4)
        for i in 0..<count {
            let r = Int(pixels[4 * i]), g = Int(pixels[4 * i + 1]), b = Int(pixels[4 * i + 2])
            hist[0][r] += 1; hist[1][g] += 1; hist[2][b] += 1
            hist[3][(r * 54 + g * 183 + b * 19) >> 8] += 1
        }
        func percentile(_ h: [Int], _ p: Double) -> Double {
            let target = Int(Double(count) * p)
            var acc = 0
            for v in 0..<256 { acc += h[v]; if acc > target { return Double(v) / 255 } }
            return 1
        }
        return Stats(low: (0..<3).map { percentile(hist[$0], lowPct) },
                     high: (0..<3).map { percentile(hist[$0], highPct) },
                     lumaLow: percentile(hist[3], lowPct), lumaHigh: percentile(hist[3], highPct))
    }

    /// RGBA8 pixels of a downscaled rendition, top row first, with its exact size.
    static func thumbnailPixels(_ ci: CIImage, maxSide: CGFloat) -> ([UInt8], Int, Int) {
        let longest = max(ci.extent.width, ci.extent.height)
        guard longest > 0 else { return ([], 0, 0) }
        let s = min(1, maxSide / longest)
        let small = ci.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let w = max(1, Int(small.extent.width)), h = max(1, Int(small.extent.height))
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &buf, rowBytes: w * 4,
                       bounds: CGRect(x: small.extent.minX, y: small.extent.minY, width: CGFloat(w), height: CGFloat(h)),
                       format: .RGBA8, colorSpace: sRGB)
        return (buf, w, h)
    }

    /// Bounding box of everything that differs from the (white) scanner lid, with a small margin.
    /// Returns nil when nothing stands out (e.g. a white page on a white lid).
    static func contentBounds(of ci: CIImage) -> CGRect? {
        let (px, w, h) = thumbnailPixels(ci, maxSide: 512)
        guard w > 8, h > 8, px.count >= w * h * 4 else { return nil }
        let s = CGFloat(w) / ci.extent.width

        // Background = the brightest common level along the border.
        var border: [Int] = []
        for x in 0..<w { border.append(luma(px, x, 0, w)); border.append(luma(px, x, h - 1, w)) }
        for y in 0..<h { border.append(luma(px, 0, y, w)); border.append(luma(px, w - 1, y, w)) }
        border.sort()
        let background = border[border.count * 3 / 4]
        let cut = background - 24

        var rowHits = [Int](repeating: 0, count: h), colHits = [Int](repeating: 0, count: w)
        // Skip a 2 px frame: the very edge of the glass reads dark on many scanners.
        let e = 2
        for y in e..<(h - e) { for x in e..<(w - e) where luma(px, x, y, w) < cut { rowHits[y] += 1; colHits[x] += 1 } }
        let minRow = max(2, w / 100), minCol = max(2, h / 100)
        guard let top = rowHits.firstIndex(where: { $0 >= minRow }),
              let bottom = rowHits.lastIndex(where: { $0 >= minRow }),
              let left = colHits.firstIndex(where: { $0 >= minCol }),
              let right = colHits.lastIndex(where: { $0 >= minCol }),
              right > left, bottom > top else { return nil }
        // Thumbnail rows run top→bottom; Core Image's y axis runs bottom→top.
        let margin = 1
        let x0 = CGFloat(max(0, left - margin)) / s
        let x1 = CGFloat(min(w, right + 1 + margin)) / s
        let yTop = CGFloat(max(0, top - margin)) / s
        let yBottom = CGFloat(min(h, bottom + 1 + margin)) / s
        let rect = CGRect(x: ci.extent.minX + x0, y: ci.extent.maxY - yBottom,
                          width: x1 - x0, height: yBottom - yTop).intersection(ci.extent)
        // Ignore "crops" that keep almost everything.
        if rect.width * rect.height > ci.extent.width * ci.extent.height * 0.97 { return nil }
        return rect
    }

    private static func luma(_ px: [UInt8], _ x: Int, _ y: Int, _ w: Int) -> Int {
        let i = 4 * (y * w + x)
        return (Int(px[i]) * 54 + Int(px[i + 1]) * 183 + Int(px[i + 2]) * 19) >> 8
    }
}
