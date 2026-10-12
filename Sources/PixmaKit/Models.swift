import Foundation

public enum PixmaError: LocalizedError, Equatable {
    case network(String)
    case timeout(String)
    case protocolError(String)
    case busy
    case cancelled
    case scannerRejected(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .network(let m): return "Network error: \(m)"
        case .timeout(let m): return "Timed out: \(m)"
        case .protocolError(let m): return "Scanner protocol error: \(m)"
        case .busy: return "The scanner is busy (printing, copying, or in use by another computer). Try again in a moment."
        case .cancelled: return "Scan cancelled."
        case .scannerRejected(let m): return "The scanner refused the request: \(m)"
        case .unsupported(let m): return m
        }
    }
}

/// Static capabilities of a PIXMA model. Values are from the model's spec sheet, cross-checked with
/// the SANE `pixma` backend's device table (units of 1/75 inch for the bed size).
public struct PixmaModel: Sendable, Hashable {
    public let name: String
    /// Model token as it appears at the start of the `MDL:` field, e.g. "MG7100" in "MG7100 series".
    public let match: String
    /// USB product ID (identifies the model family; used for a few protocol quirks).
    public let pid: Int
    /// PIXMA protocol generation: 3+ use the "_3" scan commands, 4+ also wrap jobs in an XML dialog.
    public let generation: Int
    /// Lowest resolution the scanner accepts (0 = 75 dpi).
    public let minDPI: Int
    public let maxDPI: Int
    public let bedWidth75: Int
    public let bedHeight75: Int
    public let hasADF: Bool
    /// When non-zero, lines above this resolution arrive as interleaved sub-images
    /// (resolution / interleaveUnit of them) and must be reordered.
    public let interleaveUnit: Int

    public init(name: String, match: String, pid: Int, generation: Int, minDPI: Int, maxDPI: Int,
                bedWidth75: Int, bedHeight75: Int, hasADF: Bool, interleaveUnit: Int) {
        self.name = name; self.match = match; self.pid = pid; self.generation = generation
        self.minDPI = minDPI; self.maxDPI = maxDPI; self.bedWidth75 = bedWidth75; self.bedHeight75 = bedHeight75
        self.hasADF = hasADF; self.interleaveUnit = interleaveUnit
    }

    /// Models tested against real hardware with this project.
    public static let verifiedModels: Set<String> = ["MG7100"]
    public var verified: Bool { Self.verifiedModels.contains(match) }

    public var bedWidthInches: Double { Double(bedWidth75) / 75 }
    public var bedHeightInches: Double { Double(bedHeight75) / 75 }

    /// Resolutions the scanner accepts: 75 × 2ⁿ, from its minimum up to the optical maximum.
    public var supportedDPIs: [Int] {
        var r: [Int] = []
        var d = 75
        while d <= maxDPI { if d >= minDPI { r.append(d) }; d *= 2 }
        return r
    }

    public static let mg7100 = table.first { $0.match == "MG7100" }!

    public static var known: [PixmaModel] { table }

    /// Conservative profile for a Canon that answers BJNP but is not in the table: A4 glass,
    /// 1200 dpi, generation-5 command set (most PIXMAs from 2012 on). Experimental.
    public static func generic(named name: String) -> PixmaModel {
        PixmaModel(name: name, match: "", pid: 0, generation: 5, minDPI: 0, maxDPI: 1200,
                   bedWidth75: 638, bedHeight75: 877, hasADF: false, interleaveUnit: 0)
    }

    /// True for the fallback profile of an unrecognised model.
    public var isGeneric: Bool { match.isEmpty }

    /// Finds the profile for a device ID ("MFG:Canon;…;MDL:MG7100 series;…") or a display name
    /// ("Canon MG7100 series"). The model token must match exactly, so "E400" never matches "E4000".
    public static func forIdentity(_ ieee1284: String) -> PixmaModel? {
        var mdl = IEEE1284.fields(ieee1284)["MDL"] ?? ieee1284
        for prefix in ["Canon ", "CANON ", "PIXMA ", "MAXIFY ", "PIXUS "] where mdl.hasPrefix(prefix) {
            mdl.removeFirst(prefix.count)
        }
        for prefix in ["PIXMA ", "MAXIFY ", "PIXUS "] where mdl.hasPrefix(prefix) { mdl.removeFirst(prefix.count) }
        guard let token = mdl.split(whereSeparator: { $0 == " " || $0 == "_" }).first.map(String.init)?.uppercased(),
              !token.isEmpty else { return nil }
        return byToken[token]
    }

    private static let byToken: [String: PixmaModel] = {
        var d: [String: PixmaModel] = [:]
        for m in table where d[m.match.uppercased()] == nil { d[m.match.uppercased()] = m }
        return d
    }()
}

public enum IEEE1284 {
    public static func fields(_ id: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in id.split(separator: ";") {
            let kv = part.split(separator: ":", maxSplits: 1)
            if kv.count == 2 {
                out[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return out
    }
}

public enum PixmaColorMode: String, Sendable, CaseIterable {
    case color      // 24-bit RGB
    case gray       // 8-bit grayscale (native on CIS sensors)
}

public struct PixmaScanRequest: Sendable {
    public var dpi: Int
    public var mode: PixmaColorMode
    /// Scan area in inches, origin at the top-left corner of the glass.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// Gamma applied by the scanner's lookup table. 1.0 = linear sensor data.
    public var gamma: Double
    /// Run the scanner's white calibration before this scan.
    public var calibrate: Bool

    public init(dpi: Int = 300, mode: PixmaColorMode = .color, x: Double = 0, y: Double = 0,
                width: Double = 8.5, height: Double = 11.69, gamma: Double = 2.2, calibrate: Bool = true) {
        self.dpi = dpi; self.mode = mode
        self.x = x; self.y = y; self.width = width; self.height = height
        self.gamma = gamma; self.calibrate = calibrate
    }
}

public enum PixmaScanPhase: Sendable, Equatable {
    case connecting
    case warmingUp
    case scanning(fraction: Double)
    case finishing
}

/// Raw 8-bit pixels written to a temporary file (memory-mapped when read back), so very large
/// scans – a full A4 page at 2400 dpi is ~1.7 GB – don't have to live in RAM.
public struct PixmaRawImage: Sendable {
    public let fileURL: URL
    public let width: Int
    public let height: Int
    public let channels: Int
    public let dpi: Int
    public var bytesPerRow: Int { width * channels }
}
