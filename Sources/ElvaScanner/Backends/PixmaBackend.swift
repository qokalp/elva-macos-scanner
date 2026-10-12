import Foundation
import CoreGraphics
import PixmaKit

/// Native Canon PIXMA backend: speaks BJNP + the PIXMA scan protocol directly over Wi-Fi/Ethernet.
/// No Canon driver is needed, which is what makes the MG7150 usable on current macOS.
final class PixmaBackend: ScannerBackend, @unchecked Sendable {
    let host: String
    private(set) var name: String
    private var model: PixmaModel
    private var scanner: PixmaScanner?
    private var resolvedAddress: String?
    private let lock = NSLock()

    init(host: String, name: String) {
        self.host = host
        self.name = name
        self.model = PixmaModel.forIdentity(name) ?? .generic(named: name)
    }

    var id: String { "pixma:\(host)" }
    var displayName: String { name }
    var kindLabel: String { L("built-in driver") }
    var connectionDetail: String {
        "Network · Native PIXMA driver · \(resolvedAddress ?? host)"
    }

    var capabilities: ScannerCapabilities {
        ScannerCapabilities(resolutions: model.supportedDPIs,
                            bedWidth: model.bedWidthInches, bedHeight: model.bedHeightInches,
                            supportsGray: true, hasFeeder: false, hasTransparencyUnit: false,
                            supportsGamma: true, supportsCalibrationControl: true)
    }

    var notes: [String] {
        if model.isGeneric { return [L("note.generic")] }
        if !model.verified { return [String(format: L("note.untested"), model.name)] }
        return []
    }

    func prepare() async throws {
        let host = self.host
        let (scanner, address) = try await Task.detached { () throws -> (PixmaScanner, String) in
            let s = try PixmaScanner(host: host)
            try s.identify()
            return (s, s.connection.resolvedAddress)
        }.value
        lock.withLock {
            self.scanner = scanner
            self.model = scanner.model
            self.resolvedAddress = address
            let mdl = IEEE1284.fields(scanner.identity)["MDL"]
            if let mdl, !name.localizedCaseInsensitiveContains(mdl) { name = "Canon \(mdl)" }
        }
    }

    func scan(_ request: BackendScanRequest, progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> [ScanOutput] {
        if lock.withLock({ scanner }) == nil { try await prepare() }
        guard let scanner = lock.withLock({ scanner }) else { throw PixmaError.network("Scanner not available") }

        let pixmaRequest = PixmaScanRequest(
            dpi: request.dpi, mode: request.gray ? .gray : .color,
            x: request.area.x, y: request.area.y, width: request.area.width, height: request.area.height,
            gamma: request.gamma, calibrate: request.calibrate)

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { () throws -> [ScanOutput] in
                let raw = try scanner.scan(pixmaRequest) { phase in
                    switch phase {
                    case .connecting: progress(.status("Connecting…"))
                    case .warmingUp: progress(.status("Warming up…"))
                    case .scanning(let f): progress(.fraction(f))
                    case .finishing: progress(.status("Finishing…"))
                    }
                }
                do {
                    return [ScanOutput(image: try raw.makeCGImage(), dpi: raw.dpi, backingFile: raw.fileURL)]
                } catch {
                    raw.removeFile()
                    throw error
                }
            }.value
        } onCancel: {
            scanner.cancel()
        }
    }

    func cancel() { lock.withLock { scanner }?.cancel() }
}
