import Foundation
import AppKit
import CoreGraphics
import UniformTypeIdentifiers
import Combine
import PixmaKit

struct Activity: Equatable {
    var title: String
    var fraction: Double?        // nil = indeterminate
    var cancellable = true
}

enum SaveKind: String, CaseIterable, Identifiable {
    case document, photos
    var id: String { rawValue }
}

@MainActor
final class AppModel: ObservableObject {
    let manager = ScannerManager()
    let updates = UpdateChecker()

    @Published var settings = ScanSettings.load() {
        didSet {
            settings.save()
            if oldValue.language != settings.language { Lang.apply(settings.language) }
        }
    }
    @Published var selectedScannerID: String? {
        didSet {
            UserDefaults.standard.set(selectedScannerID, forKey: "SelectedScanner")
            if oldValue != selectedScannerID { previewImage = nil; scannerChanged() }
        }
    }
    @Published private(set) var preparedScannerIDs: Set<String> = []

    @Published var previewImage: CGImage?
    private var previewBacking: BackingFile?
    @Published var selectedRegionIndex = 0

    @Published var pages: [ScannedPage] = []
    @Published var selectedPageID: UUID?
    @Published var showSaveSheet = false

    @Published var activity: Activity?
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    // Batch scanning (the MG7150 has no document feeder, so batches are page-by-page on the glass).
    @Published var batchMode = false { didSet { if !batchMode { finishBatch() } } }
    @Published var waitingForNextPage = false
    @Published var countdown: Int?

    private var currentTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var calibratedThisSession: Set<String> = []
    private var cancellables: Set<AnyCancellable> = []

    init() {
        Lang.apply(settings.language)
        selectedScannerID = UserDefaults.standard.string(forKey: "SelectedScanner")
        rememberedScannerID = selectedScannerID
        manager.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the new value is stored; evaluate on the next turn.
            DispatchQueue.main.async { self?.scannersUpdated() }
        }.store(in: &cancellables)
        manager.start()
    }

    // MARK: Scanner

    var scanners: [any ScannerBackend] { manager.scanners }

    var selectedScanner: (any ScannerBackend)? {
        scanners.first { $0.id == selectedScannerID }
    }

    var capabilities: ScannerCapabilities {
        selectedScanner?.capabilities
            ?? ScannerCapabilities(resolutions: [75, 150, 300, 600, 1200, 2400], bedWidth: 8.5, bedHeight: 11.69)
    }

    /// The scanner list changed: pick one if needed, and connect to the selected scanner once it
    /// appears (its ID may have been restored from the last session before it was discovered).
    private func scannersUpdated() {
        objectWillChange.send()
        if selectedScanner == nil, !scanners.isEmpty {
            // Wait until the network search is done, so a scanner that shows up first (or the one
            // remembered from last time, which may still be on its way) doesn't win by accident.
            if !manager.didFinishInitialSearch { return }
            // The built-in driver is preferred: it is verified and offers every resolution and option.
            let preferred = scanners.first { $0 is PixmaBackend } ?? scanners[0]
            selectedScannerID = preferred.id
        } else if let s = selectedScanner, !preparedScannerIDs.contains(s.id), !preparing.contains(s.id) {
            scannerChanged()
        }
    }
    private var preparing: Set<String> = []
    private var rememberedScannerID: String?

    private func scannerChanged() {
        guard let scanner = selectedScanner else { return }
        let caps = scanner.capabilities
        if !caps.resolutions.contains(settings.dpi) {
            settings.dpi = caps.resolutions.min(by: { abs($0 - settings.dpi) < abs($1 - settings.dpi) }) ?? 300
        }
        if !caps.hasFeeder { settings.source = .flatbed }
        applyPreset(settings.preset)
        Task { await prepareSelectedScanner() }
    }

    func prepareSelectedScanner() async {
        guard let scanner = selectedScanner, !preparedScannerIDs.contains(scanner.id),
              !preparing.contains(scanner.id) else { return }
        preparing.insert(scanner.id)
        defer { preparing.remove(scanner.id) }
        do {
            try await scanner.prepare()
            preparedScannerIDs.insert(scanner.id)
            applyPreset(settings.preset)
            objectWillChange.send()
        } catch {
            statusMessage = String(format: L("%@ is not responding: %@"), scanner.displayName, Self.message(for: error))
        }
    }

    // MARK: Mode

    func selectMode(_ mode: ScanMode) {
        var s = settings
        mode.apply(to: &s, resolutions: capabilities.resolutions)
        settings = s
    }

    // MARK: Regions

    var regions: [ScanArea] { settings.regions }

    func applyPreset(_ preset: PaperPreset) {
        let caps = capabilities
        settings.preset = preset
        switch preset {
        case .custom:
            settings.regions = settings.regions.map { $0.clamped(toWidth: caps.bedWidth, height: caps.bedHeight) }
        case .fullBed:
            settings.regions = [ScanArea(x: 0, y: 0, width: caps.bedWidth, height: caps.bedHeight)]
            settings.multiRegion = false
        default:
            let (w, h) = preset.size!
            settings.regions = [ScanArea(x: 0, y: 0, width: w, height: h).clamped(toWidth: caps.bedWidth, height: caps.bedHeight)]
            settings.multiRegion = false
        }
        selectedRegionIndex = 0
    }

    func updateRegion(at index: Int, to area: ScanArea) {
        guard settings.regions.indices.contains(index) else { return }
        let caps = capabilities
        settings.preset = .custom
        settings.regions[index] = area.clamped(toWidth: caps.bedWidth, height: caps.bedHeight)
    }

    /// Adds a region in multi-area mode, or replaces the single region otherwise. Returns its index.
    @discardableResult
    func addRegion(_ area: ScanArea) -> Int {
        let caps = capabilities
        let a = area.clamped(toWidth: caps.bedWidth, height: caps.bedHeight)
        settings.preset = .custom
        if settings.multiRegion {
            settings.regions.append(a)
            selectedRegionIndex = settings.regions.count - 1
        } else {
            settings.regions = [a]
            selectedRegionIndex = 0
        }
        return selectedRegionIndex
    }

    func removeRegion(at index: Int) {
        guard settings.regions.count > 1, settings.regions.indices.contains(index) else { return }
        settings.regions.remove(at: index)
        selectedRegionIndex = min(selectedRegionIndex, settings.regions.count - 1)
    }

    func setMultiRegion(_ on: Bool) {
        settings.multiRegion = on
        if !on, settings.regions.indices.contains(selectedRegionIndex) {
            settings.regions = [settings.regions[selectedRegionIndex]]
            selectedRegionIndex = 0
        }
    }

    /// Replaces the selection with what the detector finds on the glass (previewing first if needed).
    /// `split`: one area per item; otherwise a single area around everything.
    func autoDetect(split: Bool) {
        guard selectedScanner != nil || previewImage != nil else { return noScanner() }
        Task {
            if previewImage == nil {
                guard await performPreview() else { return }
            }
            await applyDetection(split: split)
        }
    }

    /// Runs the item detector on the current preview and replaces the selection with the result.
    private func applyDetection(split: Bool) async {
        guard let preview = previewImage else { return }
        let caps = capabilities
        let items = await Task.detached {
            ItemDetector.detect(in: preview, bedWidth: caps.bedWidth, bedHeight: caps.bedHeight)
        }.value
        guard !items.isEmpty else {
            statusMessage = L("Nothing found on the glass – selection unchanged.")
            return
        }
        settings.preset = .custom
        if split && items.count > 1 {
            settings.multiRegion = true
            settings.regions = items
            statusMessage = String(format: L("%d items found – each will be saved as a separate page."), items.count)
        } else {
            settings.multiRegion = false
            settings.regions = [ScanArea.union(items)!]
            statusMessage = split ? L("Only one item found.") : nil
        }
        selectedRegionIndex = 0
        selectedPageID = nil
    }

    // MARK: Pages

    var selectedPage: ScannedPage? { pages.first { $0.id == selectedPageID } }

    /// The adjustments shown in the sidebar: the selected page's, or the defaults for new scans.
    var currentAdjustments: ImageAdjustments {
        get { selectedPage?.adjustments ?? settings.adjustments }
        set {
            if let page = selectedPage {
                page.adjustments = newValue
                objectWillChange.send()
            } else {
                settings.adjustments = newValue
            }
        }
    }

    func applyAdjustmentsToAllPages() {
        let adj = currentAdjustments
        for page in pages {
            var a = adj
            a.rotation = page.adjustments.rotation
            page.adjustments = a
        }
        statusMessage = String(format: L("Applied to %d pages."), pages.count)
    }

    func rotateSelected(by degrees: Int) {
        guard let page = selectedPage else { return }
        page.adjustments.rotation = ((page.adjustments.rotation + degrees) % 360 + 360) % 360
        objectWillChange.send()
    }

    func deletePage(_ page: ScannedPage) {
        page.cancelRendering()
        if let i = pages.firstIndex(where: { $0.id == page.id }) {
            pages.remove(at: i)
            if selectedPageID == page.id {
                selectedPageID = pages.indices.contains(i) ? pages[i].id : pages.last?.id
            }
        }
    }

    func movePage(_ page: ScannedPage, by offset: Int) {
        guard let i = pages.firstIndex(where: { $0.id == page.id }) else { return }
        let j = i + offset
        guard pages.indices.contains(j) else { return }
        pages.swapAt(i, j)
    }

    /// Drag-and-drop reordering: puts `id` where `target` currently is.
    func movePage(id: UUID, before target: UUID) {
        guard id != target, let from = pages.firstIndex(where: { $0.id == id }),
              let to = pages.firstIndex(where: { $0.id == target }) else { return }
        let page = pages.remove(at: from)
        pages.insert(page, at: to)
    }

    func clearPages() {
        pages.forEach { $0.cancelRendering() }
        pages.removeAll()
        selectedPageID = nil
        finishBatch()
    }

    // MARK: Scanning

    var isBusy: Bool { activity != nil }

    /// Previews the glass and, if enabled, crops the selection to what was found
    /// (one area per item when Multiple Areas is on).
    func preview() {
        Task {
            guard await performPreview(), settings.autoCropAfterPreview else { return }
            await applyDetection(split: settings.multiRegion)
        }
    }

    @discardableResult
    func performPreview() async -> Bool {
        guard let scanner = selectedScanner else { noScanner(); return false }
        let caps = scanner.capabilities
        let request = BackendScanRequest(
            dpi: caps.previewDPI, gray: false,
            area: ScanArea(x: 0, y: 0, width: caps.bedWidth, height: caps.bedHeight),
            source: .flatbed, gamma: settings.gamma, calibrate: shouldCalibrate(scanner))
        return await perform(title: L("Previewing…")) { [weak self] progress in
            guard let output = try await scanner.scan(request, progress: progress).first else { return }
            await MainActor.run {
                guard let self else { return }
                self.previewImage = output.image
                self.previewBacking = output.backingFile.map(BackingFile.init)
                self.selectedPageID = nil
            }
        }
    }

    func scan() {
        guard let scanner = selectedScanner else { return noScanner() }
        stopCountdown()
        waitingForNextPage = false
        let s = settings
        let caps = scanner.capabilities
        // Areas only apply to the glass; the feeder always scans whole pages.
        let feeder = s.source == .feeder && caps.hasFeeder
        let regions = feeder ? [ScanArea(x: 0, y: 0, width: caps.bedWidth, height: caps.bedHeight)] : s.activeRegions
        guard let union = ScanArea.union(regions) else { return }
        let request = BackendScanRequest(
            dpi: s.dpi, gray: s.colorMode != .color, area: union,
            source: feeder ? .feeder : .flatbed, duplex: feeder && s.duplex,
            gamma: s.gamma, calibrate: shouldCalibrate(scanner))
        let title = batchMode ? String(format: L("Scanning page %d…"), pages.count + 1) : L("Scanning…")
        Task {
            await perform(title: title) { [weak self] progress in
                let outputs = try await scanner.scan(request, progress: progress)
                await MainActor.run { self?.addPages(from: outputs, regions: regions, union: union, settings: s) }
            }
        }
    }

    /// Turns scan results into pages. A flatbed scan covering several areas is cut into one page per
    /// area; a document-feeder scan gives one page per sheet side.
    private func addPages(from outputs: [ScanOutput], regions: [ScanArea], union: ScanArea, settings s: ScanSettings) {
        var adj = s.adjustments
        adj.rotation = 0
        var added: [ScannedPage] = []
        func page(_ image: CGImage, _ output: ScanOutput, _ backing: BackingFile?) -> ScannedPage {
            ScannedPage(image: image, dpi: output.dpi, colorMode: s.colorMode, mode: s.mode,
                        adjustments: adj, backing: backing)
        }
        if outputs.count == 1, let output = outputs.first, regions.count > 1 {
            let backing = output.backingFile.map(BackingFile.init)
            let dpi = Double(output.dpi)
            let bounds = CGRect(x: 0, y: 0, width: output.image.width, height: output.image.height)
            for r in regions {
                let rect = CGRect(x: ((r.x - union.x) * dpi).rounded(), y: ((r.y - union.y) * dpi).rounded(),
                                  width: (r.width * dpi).rounded(), height: (r.height * dpi).rounded())
                    .intersection(bounds)
                guard !rect.isEmpty, let cropped = output.image.cropping(to: rect) else { continue }
                added.append(page(cropped, output, backing))
            }
        } else {
            // Pages that share one file (multi-page TIFF) share its backing so it outlives all of them.
            var backing: BackingFile?
            for output in outputs {
                if let url = output.backingFile { backing = BackingFile(url) }
                added.append(page(output.image, output, backing))
            }
        }
        pages.append(contentsOf: added)
        // Stay on the glass in batch mode so the next page can be set up; otherwise show the result.
        if batchMode {
            waitingForNextPage = true
            if s.batchAutoContinue { startCountdown(seconds: Int(s.batchInterval)) }
        } else if let first = added.first {
            selectedPageID = first.id
        }
        if added.count > 1 {
            statusMessage = String(format: L("%d pages added."), added.count)
        }
    }

    func finishBatch() {
        waitingForNextPage = false
        stopCountdown()
    }

    private func shouldCalibrate(_ scanner: any ScannerBackend) -> Bool {
        switch settings.calibration {
        case .everyScan: return true
        case .never: return false
        case .oncePerSession:
            if calibratedThisSession.contains(scanner.id) { return false }
            calibratedThisSession.insert(scanner.id)
            return true
        }
    }

    private func startCountdown(seconds: Int) {
        countdownTask?.cancel()
        countdown = seconds
        countdownTask = Task { [weak self] in
            for remaining in stride(from: seconds, to: 0, by: -1) {
                await MainActor.run { self?.countdown = remaining }
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            await MainActor.run {
                guard let self, self.waitingForNextPage else { return }
                self.countdown = nil
                self.scan()
            }
        }
    }

    func stopCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

    private func noScanner() {
        errorMessage = L("No scanner selected. Make sure the scanner is on and connected to the same network, or add it by IP address.")
    }

    /// Runs one device operation with progress reporting. Returns true on success.
    @discardableResult
    private func perform(title: String,
                         _ work: @escaping (@escaping @Sendable (ScanProgress) -> Void) async throws -> Void) async -> Bool {
        guard currentTask == nil else { return false }
        activity = Activity(title: title, fraction: nil)
        statusMessage = nil
        var ok = false
        let task = Task { [weak self] in
            let progress: @Sendable (ScanProgress) -> Void = { p in
                Task { @MainActor in
                    guard let self, self.activity != nil else { return }
                    switch p {
                    case .status(let s): self.activity?.title = L(s); self.activity?.fraction = nil
                    case .fraction(let f): self.activity?.title = title; self.activity?.fraction = f
                    }
                }
            }
            do {
                try await work(progress)
                ok = true
            } catch is CancellationError {
                self?.statusMessage = L("Scan cancelled.")
            } catch PixmaError.cancelled {
                self?.statusMessage = L("Scan cancelled.")
            } catch {
                self?.errorMessage = Self.message(for: error)
            }
        }
        currentTask = task
        await task.value
        activity = nil
        currentTask = nil
        return ok
    }

    func cancel() {
        stopCountdown()
        waitingForNextPage = false
        guard let task = currentTask else { return }
        activity?.title = L("Cancelling…")
        activity?.cancellable = false
        selectedScanner?.cancel()
        task.cancel()
    }

    static func message(for error: Error) -> String {
        guard let e = error as? PixmaError else { return error.localizedDescription }
        switch e {
        case .network(let m): return L("Cannot reach the scanner. Check that it is on and on the same network.") + "\n(\(m))"
        case .timeout: return L("The scanner stopped responding. Check its Wi-Fi connection and try again.")
        case .protocolError(let m): return L("The scanner sent an unexpected reply. Try again; if it persists, turn the printer off and on.") + "\n(\(m))"
        case .busy: return L("The scanner is busy (printing, copying, or in use by another computer). Try again in a moment.")
        case .cancelled: return L("Scan cancelled.")
        case .scannerRejected: return L("The scanner is reserved by another job or app (for example Canon IJ Scan Utility or VueScan). Close the other app or wait for it to finish, then try again.")
        case .unsupported(let m): return m
        }
    }

    // MARK: Saving

    var defaultSaveKind: SaveKind {
        let docs = pages.filter { $0.mode.isDocument }.count
        return docs * 2 >= pages.count ? .document : .photos
    }

    func defaultFileName(kind: SaveKind) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        let prefix = settings.fileNamePrefix.trimmingCharacters(in: .whitespaces)
        let base = prefix.isEmpty ? (kind == .document ? L("Document") : L("Photo")) : prefix
        return "\(base) \(f.string(from: Date()))"
    }

    /// Saves the given pages (already in the desired order).
    func save(_ targets: [ScannedPage], kind: SaveKind, format: OutputFormat, name: String) {
        guard !targets.isEmpty else { return }
        let destination: URL
        if kind == .document || targets.count == 1 {
            let panel = NSSavePanel()
            panel.title = L("Save")
            panel.nameFieldStringValue = name
            panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
            panel.canCreateDirectories = true
            if let dir = UserDefaults.standard.url(forKey: "LastExportDirectory") { panel.directoryURL = dir }
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
            UserDefaults.standard.set(url.deletingLastPathComponent(), forKey: "LastExportDirectory")
        } else {
            let panel = NSOpenPanel()
            panel.title = L("Choose a Folder for the Photos")
            panel.prompt = L("Save Here")
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            if let dir = UserDefaults.standard.url(forKey: "LastExportDirectory") { panel.directoryURL = dir }
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            destination = dir.appendingPathComponent(name).appendingPathExtension(format.fileExtension)
            UserDefaults.standard.set(dir, forKey: "LastExportDirectory")
        }

        let jobs = targets.map { ($0.original, $0.colorMode, $0.dpi, $0.adjustments) }
        let quality = settings.quality
        let searchable = settings.searchablePDF && format == .pdf
        let asDocument = kind == .document
        let clear = settings.clearAfterSave
        let savedIDs = Set(targets.map(\.id))
        activity = Activity(title: searchable ? L("Recognising text and saving…") : L("Saving…"), fraction: 0, cancellable: false)
        Task { [weak self] in
            do {
                let files = try await Task.detached(priority: .userInitiated) { () throws -> [URL] in
                    var rendered: [ExportPage] = []
                    for (image, mode, dpi, adj) in jobs {
                        guard let out = ImageProcessor.render(image, mode: mode, dpi: dpi, adjustments: adj) else {
                            throw ScanError.message(L("Could not process a page for saving."))
                        }
                        rendered.append(ExportPage(image: out, dpi: dpi))
                    }
                    return try Exporter.export(rendered, format: format, asDocument: asDocument, quality: quality,
                                               searchable: searchable, to: destination) { f in
                        Task { @MainActor in self?.activity?.fraction = f }
                    }
                }.value
                self?.statusMessage = files.count == 1
                    ? String(format: L("Saved %@"), files[0].lastPathComponent)
                    : String(format: L("Saved %d files"), files.count)
                NSWorkspace.shared.activateFileViewerSelecting(files)
                if clear, let self {
                    self.pages.removeAll { savedIDs.contains($0.id) }
                    if let sel = self.selectedPageID, savedIDs.contains(sel) { self.selectedPageID = nil }
                }
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            self?.activity = nil
        }
    }

    func cleanUp() {
        pages.removeAll()
        previewBacking = nil
        // Remove any raw scan files left behind by an earlier crash.
        let tmp = FileManager.default.temporaryDirectory
        if let files = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) {
            for f in files where f.lastPathComponent.hasPrefix("elva-") && f.pathExtension == "raw" {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }
}
