import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Vision

struct ExportPage {
    let image: CGImage
    let dpi: Int
}

enum Exporter {
    /// Writes the pages and returns the files created.
    /// `asDocument`: one multi-page file (PDF/TIFF). Otherwise one file per page, numbered when
    /// there is more than one. Existing files are never overwritten.
    static func export(_ pages: [ExportPage], format: OutputFormat, asDocument: Bool, quality: Double,
                       searchable: Bool, to url: URL,
                       progress: @escaping (Double) -> Void = { _ in }) throws -> [URL] {
        guard !pages.isEmpty else { return [] }
        if asDocument && format == .pdf {
            try writePDF(pages, quality: quality, searchable: searchable, to: url, progress: progress)
            return [url]
        }
        if asDocument && format == .tiff {
            try writeImages(pages, type: .tiff, quality: nil, to: url)
            return [url]
        }
        let type: UTType = switch format {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        case .pdf: .pdf
        }
        if pages.count == 1 {
            if format == .pdf {
                try writePDF(pages, quality: quality, searchable: searchable, to: url, progress: progress)
            } else {
                try writeImages(pages, type: type, quality: format.isLossy ? quality : nil, to: url)
            }
            return [url]
        }
        let base = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        var out: [URL] = []
        for (i, page) in pages.enumerated() {
            let u = uniqueURL(dir.appendingPathComponent(String(format: "%@ %03d", base, i + 1))
                .appendingPathExtension(format.fileExtension))
            if format == .pdf {
                try writePDF([page], quality: quality, searchable: searchable, to: u, progress: { _ in })
            } else {
                try writeImages([page], type: type, quality: format.isLossy ? quality : nil, to: u)
            }
            out.append(u)
            progress(Double(i + 1) / Double(pages.count))
        }
        return out
    }

    static func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) (\(n))")
                .appendingPathExtension(url.pathExtension)
            n += 1
        }
        return candidate
    }

    // MARK: Raster formats

    static func writeImages(_ pages: [ExportPage], type: UTType, quality: Double?, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, pages.count, nil) else {
            throw ScanError.message("Cannot create \(url.lastPathComponent).")
        }
        for page in pages {
            var props: [CFString: Any] = [
                kCGImagePropertyDPIWidth: page.dpi,
                kCGImagePropertyDPIHeight: page.dpi,
            ]
            if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
            if type == .tiff {
                props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5]  // LZW
            }
            CGImageDestinationAddImage(dest, page.image, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw ScanError.message("Cannot write \(url.lastPathComponent).") }
    }

    // MARK: PDF

    static func writePDF(_ pages: [ExportPage], quality: Double, searchable: Bool, to url: URL,
                         progress: @escaping (Double) -> Void) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let info: [CFString: Any] = [kCGPDFContextCreator: "Elva Scanner"]
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary) else {
            throw ScanError.message("Cannot create \(url.lastPathComponent).")
        }
        for (i, page) in pages.enumerated() {
            let w = CGFloat(page.image.width) * 72 / CGFloat(page.dpi)
            let h = CGFloat(page.image.height) * 72 / CGFloat(page.dpi)
            var box = CGRect(x: 0, y: 0, width: w, height: h)
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
            ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)

            // Embed as JPEG (DCT) to keep files small; 1-bit-looking B&W pages stay lossless.
            let embedded = isBilevel(page.image) ? page.image : (jpegImage(page.image, quality: quality) ?? page.image)
            ctx.interpolationQuality = .high
            ctx.draw(embedded, in: box)

            if searchable { drawInvisibleText(recognizeText(page.image), in: ctx, pageSize: box.size) }
            ctx.endPDFPage()
            progress(Double(i + 1) / Double(pages.count))
        }
        ctx.closePDF()
    }

    static func isBilevel(_ image: CGImage) -> Bool {
        image.colorSpace?.model == .monochrome && image.bitsPerPixel == 8 && image.width * image.height > 0
            && sampleIsBilevel(image)
    }

    private static func sampleIsBilevel(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data as Data? else { return false }
        var seen = Set<UInt8>()
        let step = max(1, data.count / 4096)
        for i in stride(from: 0, to: data.count, by: step) {
            seen.insert(data[i]); if seen.count > 2 { return false }
        }
        return true
    }

    static func jpegImage(_ image: CGImage, quality: Double) -> CGImage? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest), let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: OCR

    struct TextLine { let text: String; let box: CGRect }   // box normalised, origin bottom-left

    static func recognizeText(_ image: CGImage) -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        return (request.results ?? []).compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            return TextLine(text: candidate.string, box: obs.boundingBox)
        }
    }

    /// Draws recognised text invisibly over the image so the PDF can be searched and copied from.
    static func drawInvisibleText(_ lines: [TextLine], in ctx: CGContext, pageSize: CGSize) {
        guard !lines.isEmpty else { return }
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for line in lines {
            let rect = CGRect(x: line.box.minX * pageSize.width, y: line.box.minY * pageSize.height,
                              width: line.box.width * pageSize.width, height: line.box.height * pageSize.height)
            guard rect.width > 1, rect.height > 1 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, rect.height * 0.85, nil)
            let attr = NSAttributedString(string: line.text, attributes: [.init(kCTFontAttributeName as String): font])
            let ctLine = CTLineCreateWithAttributedString(attr)
            let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            guard width > 0 else { continue }
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: rect.minX, y: rect.minY + rect.height * 0.2)
            ctx.scaleBy(x: rect.width / CGFloat(width), y: 1)
            ctx.textPosition = .zero
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }
}
