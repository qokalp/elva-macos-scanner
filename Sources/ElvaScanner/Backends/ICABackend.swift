import Foundation
import ImageCaptureCore
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Scanners exposed by macOS's Image Capture architecture: AirScan/eSCL devices (driverless) and
/// anything with an installed ICA driver (e.g. Canon's own ICA driver on older macOS releases).
final class ICABackend: NSObject, ScannerBackend, ICScannerDeviceDelegate, @unchecked Sendable {
    let device: ICScannerDevice
    private var sessionOpen = false
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var selectContinuation: CheckedContinuation<Void, Error>?
    private var scanContinuation: CheckedContinuation<[URL], Error>?
    private var scannedURLs: [URL] = []
    private var progressTimer: Timer?

    init(device: ICScannerDevice) {
        self.device = device
        super.init()
        device.delegate = self
    }

    var id: String { "ica:\(device.uuidString ?? device.name ?? "?")" }
    var displayName: String { device.name ?? "Scanner" }
    var kindLabel: String { L("macOS driver / AirScan") }
    var connectionDetail: String {
        // Transport constants are strings such as "ICTransportTypeUSB" / "ICTransportTypeTCPIP".
        let raw = device.transportType ?? ""
        let transport = raw.contains("USB") ? "USB"
            : raw.contains("TCPIP") ? "Network"
            : raw.contains("Bluetooth") ? "Bluetooth" : "Image Capture"
        return "\(transport) · " + L("macOS driver / AirScan")
    }

    var capabilities: ScannerCapabilities {
        let fu = sessionOpen ? device.selectedFunctionalUnit : nil
        var resolutions = fu.map { Array($0.supportedResolutions).filter { $0 >= 50 } } ?? []
        if resolutions.isEmpty { resolutions = [75, 150, 300, 600, 1200] }
        // ICA reports the bed size in its current measurement unit.
        var w = 8.5, h = 11.69
        if let fu {
            let size = fu.physicalSize
            switch fu.measurementUnit {
            case .centimeters: w = size.width / 2.54; h = size.height / 2.54
            case .points: w = size.width / 72; h = size.height / 72
            case .pixels: w = size.width / Double(max(fu.resolution, 1)); h = size.height / Double(max(fu.resolution, 1))
            default: w = size.width; h = size.height
            }
        }
        let types = device.availableFunctionalUnitTypes.map { $0.uintValue }
        return ScannerCapabilities(
            resolutions: resolutions.sorted(), bedWidth: w > 0 ? w : 8.5, bedHeight: h > 0 ? h : 11.69,
            supportsGray: true,
            hasFeeder: types.contains(ICScannerFunctionalUnitType.documentFeeder.rawValue),
            hasTransparencyUnit: types.contains(ICScannerFunctionalUnitType.positiveTransparency.rawValue)
                || types.contains(ICScannerFunctionalUnitType.negativeTransparency.rawValue))
    }

    var notes: [String] { [] }

    // MARK: Session

    private var prepareTask: Task<Void, Error>?
    static let commandTimeout: TimeInterval = 30

    /// Opens the session once; concurrent callers share the same attempt.
    @MainActor
    func prepare() async throws {
        if sessionOpen { return }
        if let running = prepareTask { return try await running.value }
        let task = Task { @MainActor in
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                openContinuation = c
                device.requestOpenSession()
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.commandTimeout) { [weak self] in
                    guard let self, let pending = self.openContinuation else { return }
                    self.openContinuation = nil
                    pending.resume(throwing: ScanError.message(L("The scanner did not respond. Check that it is on, then try again.")))
                }
            }
            sessionOpen = true
            // After opening, the device announces its functional unit on its own (didSelect). Until
            // that arrives, settings and scan requests are silently ignored, so wait for it.
            if !functionalUnitReady { try await waitForFunctionalUnit(requesting: nil) }
            try await select(.flatbed)
        }
        prepareTask = task
        do { try await task.value } catch { prepareTask = nil; throw error }
        prepareTask = nil
    }

    private var functionalUnitReady = false

    @MainActor
    private func select(_ type: ICScannerFunctionalUnitType) async throws {
        if functionalUnitReady && device.selectedFunctionalUnit.type == type { return }
        try await waitForFunctionalUnit(requesting: type)
    }

    /// Waits for the next didSelect callback, optionally asking for a functional unit first.
    @MainActor
    private func waitForFunctionalUnit(requesting type: ICScannerFunctionalUnitType?) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            selectContinuation = c
            if let type { functionalUnitReady = false; device.requestSelect(type) }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.commandTimeout) { [weak self] in
                guard let self, let pending = self.selectContinuation else { return }
                self.selectContinuation = nil
                pending.resume(throwing: ScanError.message(L("The scanner did not respond. Check that it is on, then try again.")))
            }
        }
    }

    @MainActor
    func scan(_ request: BackendScanRequest, progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> [ScanOutput] {
        try await prepare()
        try await select(request.source == .feeder ? .documentFeeder : .flatbed)
        let fu = device.selectedFunctionalUnit

        let supported = Array(fu.supportedResolutions)
        let dpi = supported.contains(request.dpi) ? request.dpi
            : (supported.min(by: { abs($0 - request.dpi) < abs($1 - request.dpi) }) ?? request.dpi)
        fu.resolution = dpi
        fu.measurementUnit = .inches
        fu.pixelDataType = request.gray ? .gray : .RGB
        fu.bitDepth = .depth8Bits
        if request.source == .flatbed {
            fu.scanArea = NSRect(x: request.area.x, y: request.area.y,
                                 width: request.area.width, height: request.area.height)
        } else if let feeder = fu as? ICScannerFunctionalUnitDocumentFeeder, feeder.supportsDuplexScanning {
            feeder.duplexScanningEnabled = request.duplex
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ElvaScanner-ICA", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        device.transferMode = .fileBased
        device.downloadsDirectory = dir
        device.documentName = "scan-\(UUID().uuidString)"
        device.documentUTI = UTType.tiff.identifier

        progress(.status("Scanning…"))
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak fu] _ in
            if let pct = fu?.scanProgressPercentDone, pct > 0 { progress(.fraction(Double(pct) / 100)) }
        }
        defer { progressTimer?.invalidate(); progressTimer = nil }

        let urls = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<[URL], Error>) in
                scannedURLs = []
                scanContinuation = c
                device.requestScan()
            }
        } onCancel: { [device] in
            device.cancelScan()
        }

        // A feeder delivers one file per page; some drivers write one multi-page TIFF instead.
        var outputs: [ScanOutput] = []
        for url in urls {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { continue }
            let count = CGImageSourceGetCount(src)
            for i in 0..<count {
                if let image = CGImageSourceCreateImageAtIndex(src, i, nil) {
                    // The file is shared by its pages; only the first output owns (and deletes) it.
                    outputs.append(ScanOutput(image: image, dpi: dpi, backingFile: i == 0 ? url : nil))
                }
            }
        }
        guard !outputs.isEmpty else { throw ScanError.message(L("The scanner returned an unreadable image.")) }
        return outputs
    }

    func cancel() { device.cancelScan() }

    // MARK: ICDeviceDelegate

    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        let c = openContinuation; openContinuation = nil
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        sessionOpen = false
        functionalUnitReady = false
    }

    func didRemove(_ device: ICDevice) {
        sessionOpen = false
        let err = ScanError.message(L("The scanner was disconnected."))
        openContinuation?.resume(throwing: err); openContinuation = nil
        selectContinuation?.resume(throwing: err); selectContinuation = nil
        scanContinuation?.resume(throwing: err); scanContinuation = nil
    }

    // MARK: ICScannerDeviceDelegate

    func scannerDevice(_ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit, error: (any Error)?) {
        if error == nil { functionalUnitReady = true }
        let c = selectContinuation; selectContinuation = nil
        if let error { c?.resume(throwing: error) } else { c?.resume() }
    }

    func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        scannedURLs.append(url)
    }

    func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: (any Error)?) {
        let c = scanContinuation; scanContinuation = nil
        if let error {
            c?.resume(throwing: error)
        } else if !scannedURLs.isEmpty {
            c?.resume(returning: scannedURLs)
        } else {
            c?.resume(throwing: ScanError.message(L("The scan finished without producing an image. If you used the document feeder, check that paper is loaded.")))
        }
    }
}

enum ScanError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}
