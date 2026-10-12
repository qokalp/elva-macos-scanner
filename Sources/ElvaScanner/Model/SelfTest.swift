import Foundation
import CoreGraphics

/// Diagnostic: run the app binary with `ELVA_SELFTEST=/path/out.pdf`. It finds a scanner,
/// previews, detects the items on the glass, scans them in one pass at 150 dpi, cuts one page per
/// item, saves them as one PDF via the normal pipeline, writes a log next to it and quits.
@MainActor
enum SelfTest {
    static func runIfRequested(_ model: AppModel) {
        guard let path = ProcessInfo.processInfo.environment["ELVA_SELFTEST"] else { return }
        let out = URL(fileURLWithPath: path)
        let logURL = out.deletingPathExtension().appendingPathExtension("log")
        var log = ""
        func note(_ s: String) {
            log += "\(Date().formatted(date: .omitted, time: .standard))  \(s)\n"
            try? log.write(to: logURL, atomically: true, encoding: .utf8)
        }
        Task {
            note("self-test started")
            for _ in 0..<40 where model.selectedScanner == nil { try? await Task.sleep(for: .milliseconds(250)) }
            guard let scanner = model.selectedScanner else { note("FAIL: no scanner found"); exit(1) }
            note("scanner: \(scanner.displayName) – \(scanner.connectionDetail)")
            do {
                try await scanner.prepare()
                let caps = scanner.capabilities
                let p = try await scanner.scan(BackendScanRequest(dpi: caps.previewDPI, gray: false,
                    area: ScanArea(x: 0, y: 0, width: caps.bedWidth, height: caps.bedHeight),
                    source: .flatbed, gamma: 2.2, calibrate: true)) { _ in }[0]
                let previewBacking = p.backingFile.map(BackingFile.init)
                note("preview: \(p.image.width)×\(p.image.height)")

                var items = ItemDetector.detect(in: p.image, bedWidth: caps.bedWidth, bedHeight: caps.bedHeight)
                note("detected \(items.count) item(s): " + items.map {
                    String(format: "[%.2f,%.2f %.2f×%.2f in]", $0.x, $0.y, $0.width, $0.height) }.joined(separator: " "))
                if items.isEmpty { items = [ScanArea(x: 0.5, y: 0.5, width: 2, height: 2)] }
                let union = ScanArea.union(items)!

                let s = try await scanner.scan(BackendScanRequest(dpi: 150, gray: false, area: union,
                    source: .flatbed, gamma: 2.2, calibrate: false)) { _ in }[0]
                let backing = s.backingFile.map(BackingFile.init)
                note("scan: \(s.image.width)×\(s.image.height) @ \(s.dpi)")

                var pages: [ExportPage] = []
                for r in items {
                    let rect = CGRect(x: ((r.x - union.x) * 150).rounded(), y: ((r.y - union.y) * 150).rounded(),
                                      width: (r.width * 150).rounded(), height: (r.height * 150).rounded())
                        .intersection(CGRect(x: 0, y: 0, width: s.image.width, height: s.image.height))
                    guard let crop = s.image.cropping(to: rect),
                          let img = ImageProcessor.render(crop, mode: .color, dpi: 150, adjustments: ImageAdjustments())
                    else { note("FAIL: crop"); exit(1) }
                    pages.append(ExportPage(image: img, dpi: 150))
                    note("page \(pages.count): \(img.width)×\(img.height)")
                }
                let files = try Exporter.export(pages, format: .pdf, asDocument: true, quality: 0.85,
                                                searchable: true, to: out)
                note("saved: \(files.map(\.path))")
                _ = (previewBacking, backing)

                // Phase 2: the same flow through AppModel, as the buttons drive it.
                model.selectMode(.photo)
                model.settings.dpi = 150
                note("mode photo → colour \(model.settings.colorMode.rawValue), adjustments sharpen \(model.settings.adjustments.sharpen)")
                model.applyPreset(.fullBed)
                model.settings.autoCropAfterPreview = true
                model.preview()
                try await Task.sleep(for: .seconds(1))
                while model.isBusy { try await Task.sleep(for: .milliseconds(300)) }
                try await Task.sleep(for: .seconds(1))
                note("preview() → auto-cropped to " + model.regions.map { String(format: "[%.2f,%.2f %.2f×%.2f]", $0.x, $0.y, $0.width, $0.height) }.joined() + ", preset \(model.settings.preset.rawValue)")
                model.previewImage = nil
                model.autoDetect(split: true)
                try await Task.sleep(for: .seconds(1))
                while model.isBusy { try await Task.sleep(for: .milliseconds(300)) }
                try await Task.sleep(for: .seconds(1))
                note("autoDetect(split) → multi \(model.settings.multiRegion), \(model.regions.count) region(s), status: \(model.statusMessage ?? "-")")
                model.autoDetect(split: false)
                try await Task.sleep(for: .seconds(1))
                note("autoDetect(crop) → " + model.regions.map { String(format: "[%.2f,%.2f %.2f×%.2f]", $0.x, $0.y, $0.width, $0.height) }.joined())
                model.scan()
                try await Task.sleep(for: .seconds(1))
                while model.isBusy { try await Task.sleep(for: .milliseconds(300)) }
                guard let page = model.pages.last else { note("FAIL: model scan produced no page; error: \(model.errorMessage ?? "-")"); exit(1) }
                note("model scan → \(model.pages.count) page(s), last \(page.original.width)×\(page.original.height), mode \(page.mode.rawValue)")

                // Phase 3: Image Capture route (AirScan / installed drivers), if such a scanner exists.
                note("scanners: " + model.scanners.map { "\($0.displayName) [\($0.kindLabel)]" }.joined(separator: ", "))
                if let ica = model.scanners.first(where: { $0 is ICABackend }) {
                    async let a: Void = ica.prepare()
                    async let b: Void = ica.prepare()     // concurrent callers must not hang
                    _ = try await (a, b)
                    let c = ica.capabilities
                    note(String(format: "ICA prepared: %@, dpi %@, glass %.2f×%.2f in", ica.displayName,
                                c.resolutions.map(String.init).joined(separator: "/"), c.bedWidth, c.bedHeight))
                    let outs = try await ica.scan(BackendScanRequest(dpi: 150, gray: false,
                        area: ScanArea(x: 0, y: 0, width: 3, height: 2), source: .flatbed,
                        gamma: 2.2, calibrate: false)) { _ in }
                    note("ICA scan → \(outs.count) output(s): " + outs.map { "\($0.image.width)×\($0.image.height)@\($0.dpi)" }.joined(separator: " "))
                    outs.compactMap(\.backingFile).forEach { try? FileManager.default.removeItem(at: $0) }
                } else {
                    note("no Image Capture scanner present – phase 3 skipped")
                }
                note("PASS")
                exit(0)
            } catch {
                note("FAIL: \(AppModel.message(for: error))")
                exit(1)
            }
        }
    }
}
