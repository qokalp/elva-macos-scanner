import Foundation
import CoreGraphics
import Combine

/// Temporary file holding raw scan pixels. Several pages cut from one scan share it; the file is
/// deleted when the last page using it goes away.
final class BackingFile: @unchecked Sendable {
    let url: URL
    init(_ url: URL) { self.url = url }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// One scanned page. The original pixels are kept untouched; adjustments are re-applied on demand.
@MainActor
final class ScannedPage: ObservableObject, Identifiable {
    let id = UUID()
    let original: CGImage
    let dpi: Int
    let colorMode: ColorMode
    let mode: ScanMode
    let backing: BackingFile?
    let date = Date()

    @Published var adjustments: ImageAdjustments { didSet { scheduleRender() } }
    @Published private(set) var display: CGImage?
    @Published private(set) var thumbnail: CGImage?
    @Published private(set) var isRendering = false

    private var renderTask: Task<Void, Never>?
    nonisolated static let displayMaxDimension: CGFloat = 2000

    init(image: CGImage, dpi: Int, colorMode: ColorMode, mode: ScanMode,
         adjustments: ImageAdjustments, backing: BackingFile?) {
        original = image
        self.dpi = dpi
        self.colorMode = colorMode
        self.mode = mode
        self.adjustments = adjustments
        self.backing = backing
        scheduleRender(debounce: false)
    }

    var pixelSizeDescription: String {
        let wcm = Double(original.width) / Double(dpi) * 2.54
        let hcm = Double(original.height) / Double(dpi) * 2.54
        return String(format: "%d × %d px · %d dpi · %.1f × %.1f cm", original.width, original.height, dpi, wcm, hcm)
    }

    func scheduleRender(debounce: Bool = true) {
        renderTask?.cancel()
        let image = original, mode = colorMode, dpi = dpi, adj = adjustments
        isRendering = true
        renderTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled else { return }
            let (display, thumb) = await Task.detached(priority: .userInitiated) { () -> (CGImage?, CGImage?) in
                let d = ImageProcessor.render(image, mode: mode, dpi: dpi, adjustments: adj,
                                              maxDimension: ScannedPage.displayMaxDimension)
                let t = d.flatMap { ImageProcessor.render($0, mode: mode == .color ? .color : .gray, dpi: dpi,
                                                          adjustments: ImageAdjustments(), maxDimension: 240) }
                return (d, t)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.display = display
            self.thumbnail = thumb
            self.isRendering = false
        }
    }

    func cancelRendering() { renderTask?.cancel() }
}
