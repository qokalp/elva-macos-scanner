import Foundation
import CoreGraphics

enum ColorMode: String, CaseIterable, Identifiable, Codable {
    case color, gray, blackWhite
    var id: String { rawValue }
    var label: String {
        switch self {
        case .color: return L("Color")
        case .gray: return L("Grayscale")
        case .blackWhite: return L("Black & White")
        }
    }
}

/// Scan area in inches, origin at the top-left corner of the glass.
struct ScanArea: Codable, Equatable, Hashable {
    var x: Double, y: Double, width: Double, height: Double

    var minX: Double { x }
    var minY: Double { y }
    var maxX: Double { x + width }
    var maxY: Double { y + height }

    func clamped(toWidth bedW: Double, height bedH: Double) -> ScanArea {
        let minSide = 0.25
        var a = self
        a.width = min(max(a.width, minSide), bedW)
        a.height = min(max(a.height, minSide), bedH)
        a.x = min(max(a.x, 0), bedW - a.width)
        a.y = min(max(a.y, 0), bedH - a.height)
        return a
    }

    static func union(_ areas: [ScanArea]) -> ScanArea? {
        guard let first = areas.first else { return nil }
        var x0 = first.minX, y0 = first.minY, x1 = first.maxX, y1 = first.maxY
        for a in areas.dropFirst() {
            x0 = min(x0, a.minX); y0 = min(y0, a.minY); x1 = max(x1, a.maxX); y1 = max(y1, a.maxY)
        }
        return ScanArea(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

enum PaperPreset: String, CaseIterable, Identifiable, Codable {
    case fullBed, a4, letter, a5, a6, photo4x6, photo5x7, photo3_5x5, businessCard, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fullBed: return L("Entire Glass")
        case .a4: return "A4 (210 × 297 mm)"
        case .letter: return L("US Letter (8.5 × 11 in)")
        case .a5: return "A5 (148 × 210 mm)"
        case .a6: return "A6 (105 × 148 mm)"
        case .photo4x6: return L("Photo 10 × 15 cm")
        case .photo5x7: return L("Photo 13 × 18 cm")
        case .photo3_5x5: return L("Photo 9 × 13 cm")
        case .businessCard: return L("Business Card")
        case .custom: return L("Custom Selection")
        }
    }
    /// Size in inches, or nil for presets that depend on the scanner.
    var size: (Double, Double)? {
        switch self {
        case .fullBed, .custom: return nil
        case .a4: return (210 / 25.4, 297 / 25.4)
        case .letter: return (8.5, 11)
        case .a5: return (148 / 25.4, 210 / 25.4)
        case .a6: return (105 / 25.4, 148 / 25.4)
        case .photo4x6: return (4, 6)
        case .photo5x7: return (5, 7)
        case .photo3_5x5: return (3.5, 5)
        case .businessCard: return (3.5, 2)
        }
    }
}

enum NegativeMode: String, CaseIterable, Identifiable, Codable {
    case off, blackWhite, color
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return L("Off")
        case .blackWhite: return L("B&W Negative")
        case .color: return L("Color Negative")
        }
    }
}

enum CalibrationPolicy: String, CaseIterable, Identifiable, Codable {
    case everyScan, oncePerSession, never
    var id: String { rawValue }
    var label: String {
        switch self {
        case .everyScan: return L("Every Scan")
        case .oncePerSession: return L("Once per Session")
        case .never: return L("Never")
        }
    }
}

enum OutputFormat: String, CaseIterable, Identifiable, Codable {
    case pdf, jpeg, png, tiff, heic
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pdf: return "PDF"
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .tiff: return "TIFF"
        case .heic: return "HEIC"
        }
    }
    var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .jpeg: return "jpg"
        case .png: return "png"
        case .tiff: return "tiff"
        case .heic: return "heic"
        }
    }
    var isLossy: Bool { self == .jpeg || self == .heic || self == .pdf }
    static let documentFormats: [OutputFormat] = [.pdf, .tiff]
    static let photoFormats: [OutputFormat] = [.jpeg, .heic, .png, .tiff]
}

enum ScanSource: String, CaseIterable, Identifiable, Codable {
    case flatbed, feeder
    var id: String { rawValue }
    var label: String { self == .flatbed ? L("Flatbed") : L("Document Feeder") }
}

enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system, english, turkish
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return L("System")
        case .english: return "English"
        case .turkish: return "Türkçe"
        }
    }
}

/// What the user is scanning. Choosing a mode sets sensible scan settings, image adjustments and
/// save defaults, and shows tips for that kind of original.
enum ScanMode: String, CaseIterable, Identifiable, Codable {
    case photo, document, bwDocument, magazine, colorNegative, bwNegative
    var id: String { rawValue }

    var title: String {
        switch self {
        case .photo: return L("Photo")
        case .document: return L("Document")
        case .bwDocument: return L("B&W Document")
        case .magazine: return L("Magazine")
        case .colorNegative: return L("Color Negative")
        case .bwNegative: return L("B&W Negative")
        }
    }

    var icon: String {
        switch self {
        case .photo: return "photo"
        case .document: return "doc.text"
        case .bwDocument: return "doc.plaintext"
        case .magazine: return "newspaper"
        case .colorNegative: return "film"
        case .bwNegative: return "film.stack"
        }
    }

    /// Pages from these modes are saved as a single document by default.
    var isDocument: Bool { self == .document || self == .bwDocument || self == .magazine }

    var tips: [String] {
        let backlight = L("tip.backlight")
        switch self {
        case .photo: return [L("tip.photo.split"), L("tip.photo.dpi"), L("tip.photo.dust")]
        case .document: return [L("tip.doc.dpi"), L("tip.doc.lid"), L("tip.doc.batch")]
        case .bwDocument: return [L("tip.bw.use"), L("tip.bw.threshold"), L("tip.doc.batch")]
        case .magazine: return [L("tip.mag.moire"), L("tip.mag.dpi")]
        case .colorNegative: return [backlight, L("tip.neg.dpi"), L("tip.neg.flat"), L("tip.neg.tune")]
        case .bwNegative: return [backlight, L("tip.neg.dpi"), L("tip.neg.flat")]
        }
    }

    func apply(to s: inout ScanSettings, resolutions: [Int]) {
        var adj = ImageAdjustments()
        let dpi: Int
        switch self {
        case .photo:
            s.colorMode = .color; dpi = 600; adj.sharpen = 0.15
        case .document:
            s.colorMode = .color; dpi = 300; adj.autoLevels = true; adj.sharpen = 0.2
        case .bwDocument:
            s.colorMode = .blackWhite; dpi = 300; adj.autoLevels = true
        case .magazine:
            s.colorMode = .color; dpi = 300; adj.descreen = true; adj.autoLevels = true
        case .colorNegative:
            s.colorMode = .color; dpi = 1200; adj.negative = .color
        case .bwNegative:
            s.colorMode = .gray; dpi = 1200; adj.negative = .blackWhite
        }
        s.dpi = resolutions.contains(dpi) ? dpi : (resolutions.filter { $0 <= dpi }.max() ?? resolutions.first ?? 300)
        s.adjustments = adj
        s.mode = self
    }
}

/// Per-page image adjustments, applied non-destructively in software.
struct ImageAdjustments: Codable, Equatable {
    var autoLevels = false
    var brightness = 0.0        // -1 … 1
    var contrast = 0.0          // -1 … 1
    var saturation = 0.0        // -1 … 1
    var sharpen = 0.0           // 0 … 1
    var descreen = false        // suppress halftone moiré from printed matter
    var negative = NegativeMode.off
    var threshold = 0.5         // black & white cut-off
    var autoCrop = false        // crop the page to its content
    var rotation = 0            // degrees clockwise: 0, 90, 180, 270
}

struct ScanSettings: Codable, Equatable {
    var mode = ScanMode.document
    var colorMode = ColorMode.color
    var dpi = 300
    var preset = PaperPreset.fullBed
    /// One or more areas on the glass. Each area becomes its own page.
    var regions = [ScanArea(x: 0, y: 0, width: 8.5, height: 11.69)]
    var multiRegion = false
    var source = ScanSource.flatbed
    var duplex = false
    var gamma = 2.2
    var autoCropAfterPreview = true
    var checkForUpdates = true
    var calibration = CalibrationPolicy.oncePerSession
    var adjustments = ImageAdjustments()
    var language = AppLanguage.system

    // Save defaults (shown only when saving)
    var documentFormat = OutputFormat.pdf
    var photoFormat = OutputFormat.jpeg
    var quality = 0.85
    var searchablePDF = true
    var fileNamePrefix = ""
    var clearAfterSave = false

    // Batch
    var batchAutoContinue = false
    var batchInterval = 8.0

    static let storageKey = "ScanSettings.v2"

    init() {}

    /// Tolerant decoding: settings saved by an older version keep their values, new keys get defaults.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ value: inout T) {
            if let v = try? c.decodeIfPresent(T.self, forKey: key) { value = v }
        }
        get(.mode, &mode); get(.colorMode, &colorMode); get(.dpi, &dpi); get(.preset, &preset)
        get(.regions, &regions); get(.multiRegion, &multiRegion); get(.source, &source); get(.duplex, &duplex)
        get(.gamma, &gamma); get(.autoCropAfterPreview, &autoCropAfterPreview); get(.checkForUpdates, &checkForUpdates)
        get(.calibration, &calibration); get(.adjustments, &adjustments); get(.language, &language)
        get(.documentFormat, &documentFormat); get(.photoFormat, &photoFormat); get(.quality, &quality)
        get(.searchablePDF, &searchablePDF); get(.fileNamePrefix, &fileNamePrefix)
        get(.clearAfterSave, &clearAfterSave); get(.batchAutoContinue, &batchAutoContinue)
        get(.batchInterval, &batchInterval)
        if regions.isEmpty { regions = ScanSettings().regions }
    }

    static func load() -> ScanSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let s = try? JSONDecoder().decode(ScanSettings.self, from: data) else { return ScanSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// The areas that the next scan will capture.
    var activeRegions: [ScanArea] { multiRegion ? regions : Array(regions.prefix(1)) }

    /// Estimated uncompressed size of the next scan in bytes.
    func estimatedBytes() -> Int {
        let px = activeRegions.reduce(0.0) { $0 + Double(dpi) * $1.width * Double(dpi) * $1.height }
        return Int(px * (colorMode == .color ? 3 : 1))
    }
}

func resolutionLabel(_ dpi: Int) -> String {
    switch dpi {
    case ..<100: return "\(dpi) dpi – " + L("Preview")
    case ..<200: return "\(dpi) dpi – " + L("Screen")
    case ..<400: return "\(dpi) dpi – " + L("Documents")
    case ..<800: return "\(dpi) dpi – " + L("Photos")
    case ..<1600: return "\(dpi) dpi – " + L("Film & enlargements")
    default: return "\(dpi) dpi – " + L("Maximum detail")
    }
}
