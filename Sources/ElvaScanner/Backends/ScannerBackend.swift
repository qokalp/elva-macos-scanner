import Foundation
import CoreGraphics

struct ScannerCapabilities: Equatable {
    var resolutions: [Int]
    var bedWidth: Double          // inches
    var bedHeight: Double         // inches
    var supportsGray = true
    var hasFeeder = false
    var hasTransparencyUnit = false
    /// Gamma is sent to the device (PIXMA); other backends ignore it.
    var supportsGamma = false
    var supportsCalibrationControl = false
    var previewDPI: Int { resolutions.first(where: { $0 >= 75 }) ?? resolutions.first ?? 75 }
}

struct BackendScanRequest {
    var dpi: Int
    var gray: Bool
    var area: ScanArea
    var source: ScanSource
    /// Two-sided feeder scanning (ignored when the scanner can't do it).
    var duplex = false
    var gamma: Double
    var calibrate: Bool
}

struct ScanOutput {
    let image: CGImage
    let dpi: Int
    /// Temporary backing file; deleted when the page is discarded.
    let backingFile: URL?
}

enum ScanProgress: Equatable {
    case status(String)
    case fraction(Double)
}

/// A scanner the app can drive. Implementations do their blocking I/O off the main thread.
protocol ScannerBackend: AnyObject {
    var id: String { get }
    var displayName: String { get }
    /// Which route the scanner is driven through, e.g. "built-in driver" or "macOS driver / AirScan".
    var kindLabel: String { get }
    /// e.g. "Wi-Fi · Native PIXMA driver · 192.168.1.20"
    var connectionDetail: String { get }
    var capabilities: ScannerCapabilities { get }
    /// Optional notes shown to the user (unverified model, missing features, …).
    var notes: [String] { get }

    /// Opens the device / verifies it is reachable. Called before the first scan.
    func prepare() async throws
    /// One output per sheet side: a flatbed scan gives one, a document feeder one per page.
    func scan(_ request: BackendScanRequest, progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> [ScanOutput]
    func cancel()
}
