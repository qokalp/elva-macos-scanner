import SwiftUI
import AppKit

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @State private var showAddScanner = false

    var body: some View {
        Group {
            if let page = model.selectedPage {
                PagePanel(page: page)
            } else {
                ScanPanel(manager: model.manager, showAddScanner: $showAddScanner)
            }
        }
        .sheet(isPresented: $showAddScanner) { AddScannerSheet() }
    }
}

// MARK: - Scan panel (glass)

private struct ScanPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var manager: ScannerManager
    @Binding var showAddScanner: Bool
    @AppStorage("ShowTips") private var showTips = true
    @AppStorage("ShowCorrections") private var showCorrections = false
    @AppStorage("ShowAdvanced") private var showAdvanced = false

    private var caps: ScannerCapabilities { model.capabilities }

    var body: some View {
        Form {
            scannerSection
            modeSection
            scanSection
            Section {
                DisclosureGroup(L("Image Corrections"), isExpanded: $showCorrections) {
                    AdjustmentControls(adjustments: Binding(get: { model.settings.adjustments },
                                                            set: { model.settings.adjustments = $0 }),
                                       colorMode: model.settings.colorMode, showCrop: false)
                }
            } footer: {
                Text(L("Set by the mode; applied to new scans. You can still change every page after scanning."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            advancedSection
        }
        .formStyle(.grouped)
    }

    // MARK: Scanner

    private var scannerSection: some View {
        Section(L("Scanner")) {
            if manager.scanners.isEmpty {
                HStack {
                    if manager.isSearching { ProgressView().controlSize(.small) }
                    Text(manager.isSearching ? L("Looking for scanners…") : L("No scanners found"))
                        .foregroundStyle(.secondary)
                }
                if !manager.isSearching {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Make sure the printer is on and on the same network. Elva Scanner also needs Local Network access."))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L("Open Local Network Settings")) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }
            } else {
                Picker(L("Scanner"), selection: $model.selectedScannerID) {
                    ForEach(manager.scanners, id: \.id) { s in
                        Text("\(s.displayName) — \(s is PixmaBackend ? "Elva" : "macOS")").tag(Optional(s.id))
                    }
                }
                .labelsHidden()
                if let s = model.selectedScanner {
                    let ready = model.preparedScannerIDs.contains(s.id)
                    HStack(spacing: 5) {
                        Circle().fill(ready ? Color.green : Color.secondary).frame(width: 7, height: 7)
                        Text(ready ? L("Ready") + " · " + s.kindLabel : L("Connecting…"))
                        Spacer()
                        Text(String(format: L("up to %d dpi"), caps.resolutions.max() ?? 0))
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ForEach(s.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                }
            }
            HStack {
                Button { Task { await manager.refresh() } } label: {
                    Label(L("Search Again"), systemImage: "arrow.clockwise")
                }
                .disabled(manager.isSearching)
                Spacer()
                Button { showAddScanner = true } label: { Label(L("Add Manually…"), systemImage: "plus") }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
    }

    // MARK: Mode

    private var modeSection: some View {
        Section(L("What are you scanning?")) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8),
                                GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(ScanMode.allCases) { mode in
                    ModeCard(mode: mode, selected: model.settings.mode == mode) { model.selectMode(mode) }
                }
            }
            .padding(.vertical, 2)
            DisclosureGroup(isExpanded: $showTips) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.settings.mode.tips, id: \.self) { tip in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "lightbulb").foregroundStyle(.yellow)
                            Text(tip).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.callout)
                .padding(.top, 4)
            } label: {
                Label(L("Tips"), systemImage: "lightbulb.fill").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Scan

    private var scanSection: some View {
        Section(L("Scan Settings")) {
            Picker(L("Color"), selection: $model.settings.colorMode) {
                ForEach(ColorMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker(L("Resolution"), selection: $model.settings.dpi) {
                ForEach(caps.resolutions, id: \.self) { Text(resolutionLabel($0)).tag($0) }
            }

            Picker(L("Size"), selection: Binding(get: { model.settings.preset }, set: { model.applyPreset($0) })) {
                ForEach(PaperPreset.allCases) { Text($0.label).tag($0) }
            }

            if caps.hasFeeder {
                Picker(L("Source"), selection: $model.settings.source) {
                    ForEach(ScanSource.allCases) { Text($0.label).tag($0) }
                }
                if model.settings.source == .feeder {
                    Toggle(L("Two-sided (duplex)"), isOn: $model.settings.duplex)
                    Text(L("The feeder scans every sheet loaded; each side becomes a page. Two-sided scanning is used if the scanner supports it."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            sizeEstimate
        }
    }

    private var sizeEstimate: some View {
        let bytes = model.settings.estimatedBytes()
        let big = bytes > 600_000_000
        let regions = model.settings.activeRegions
        return VStack(alignment: .leading, spacing: 2) {
            if regions.count == 1, let a = regions.first {
                Text(String(format: "%.1f × %.1f cm · %d × %d px", a.width * 2.54, a.height * 2.54,
                            Int(a.width * Double(model.settings.dpi)), Int(a.height * Double(model.settings.dpi))))
            } else {
                Text(String(format: L("%d areas → %d pages from one scan"), regions.count, regions.count))
            }
            Text(String(format: L("≈ %@ uncompressed"), ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)))
                .foregroundStyle(big ? .orange : .secondary)
            if big {
                Text(L("Very large scan – it can take several minutes over Wi-Fi. Consider a smaller area or lower resolution."))
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: Advanced

    private var advancedSection: some View {
        Section {
            DisclosureGroup(L("Advanced"), isExpanded: $showAdvanced) {
                if caps.supportsGamma {
                    SliderRow(title: String(format: L("Scanner gamma %.1f"), model.settings.gamma),
                              value: $model.settings.gamma, range: 1.0...3.0, neutral: 2.2, showsValue: false)
                }
                if caps.supportsCalibrationControl {
                    Picker(L("Calibration"), selection: $model.settings.calibration) {
                        ForEach(CalibrationPolicy.allCases) { Text($0.label).tag($0) }
                    }
                }
                Toggle(L("Auto crop after preview"), isOn: $model.settings.autoCropAfterPreview)
                Toggle(L("Batch: scan next page automatically"), isOn: $model.settings.batchAutoContinue)
                if model.settings.batchAutoContinue {
                    Stepper(value: $model.settings.batchInterval, in: 3...60, step: 1) {
                        Text(String(format: L("Time to change pages: %d s"), Int(model.settings.batchInterval)))
                    }
                }
                Toggle(L("Check for updates automatically"), isOn: $model.settings.checkForUpdates)
                Picker(L("Language"), selection: $model.settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
                }
            }
        }
    }
}

private struct ModeCard: View {
    let mode: ScanMode
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: mode.icon).font(.system(size: 20))
                Text(mode.title).font(.caption).multilineTextAlignment(.center).lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .padding(.vertical, 4)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor : Color.secondary.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mode.tips.first ?? "")
    }
}

// MARK: - Page panel

private struct PagePanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var page: ScannedPage

    private var number: Int { (model.pages.firstIndex { $0.id == page.id } ?? 0) + 1 }

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: page.mode.icon).foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text(String(format: L("Page %d of %d"), number, model.pages.count)).font(.headline)
                        Text(page.mode.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button { model.rotateSelected(by: -90) } label: { Label(L("Rotate Left"), systemImage: "rotate.left") }
                    Button { model.rotateSelected(by: 90) } label: { Label(L("Rotate Right"), systemImage: "rotate.right") }
                }
                .buttonStyle(.bordered)
            }
            Section(L("Corrections for This Page")) {
                AdjustmentControls(adjustments: Binding(get: { page.adjustments }, set: { page.adjustments = $0 }),
                                   colorMode: page.colorMode, showCrop: true)
                if model.pages.count > 1 {
                    Button(L("Apply to All Pages")) { model.applyAdjustmentsToAllPages() }
                }
            }
            Section {
                Button(L("Back to Glass")) { model.selectedPageID = nil }
                Button(L("Delete Page"), role: .destructive) { model.deletePage(page) }
            }
        }
        .formStyle(.grouped)
    }
}

/// Shared controls for image adjustments (before scanning: defaults; after: per page).
struct AdjustmentControls: View {
    @Binding var adjustments: ImageAdjustments
    let colorMode: ColorMode
    let showCrop: Bool

    var body: some View {
        Toggle(L("Auto Levels"), isOn: $adjustments.autoLevels)
        SliderRow(title: L("Brightness"), value: $adjustments.brightness, range: -1...1)
        SliderRow(title: L("Contrast"), value: $adjustments.contrast, range: -1...1)
        if colorMode == .color {
            SliderRow(title: L("Saturation"), value: $adjustments.saturation, range: -1...1)
        }
        SliderRow(title: L("Sharpen"), value: $adjustments.sharpen, range: 0...1)
        if colorMode == .blackWhite {
            SliderRow(title: L("Threshold"), value: $adjustments.threshold, range: 0.05...0.95, neutral: 0.5)
        }
        Toggle(L("Descreen (printed pictures)"), isOn: $adjustments.descreen)
        Picker(L("Negative"), selection: $adjustments.negative) {
            ForEach(NegativeMode.allCases) { Text($0.label).tag($0) }
        }
        if showCrop {
            Toggle(L("Crop to content"), isOn: $adjustments.autoCrop)
        }
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var neutral: Double = 0
    var showsValue = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                if showsValue {
                    Text(String(format: "%+.0f", (value - neutral) * 100))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                if abs(value - neutral) > 0.0001 {
                    Button { value = neutral } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless)
                        .help(L("Reset"))
                }
            }
            Slider(value: $value, in: range)
                .labelsHidden()
        }
    }
}

struct AddScannerSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "network").font(.title2).foregroundStyle(.tint)
                Text(L("Add a Scanner Manually")).font(.headline)
            }
            Text(L("Elva Scanner finds scanners on your network by itself. If yours doesn't show up, type its IP address below."))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                TextField(L("e.g. 192.168.1.40"), text: $host)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Text(L("You can see the address on the printer's screen (network or Wi-Fi settings) or in your router's list of connected devices."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GroupBox {
                Text(L("Adding by address works for Canon PIXMA and MAXIFY printers. Scanners from other brands (HP, Brother, Epson…) appear automatically when macOS supports them."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text(L("Checking…")).foregroundStyle(.secondary).font(.callout)
                }
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Add"), action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .padding(22)
        .frame(width: 440)
    }

    private func add() {
        working = true; error = nil
        Task {
            do {
                let id = try await model.manager.addManual(host: host)
                model.selectedScannerID = id
                dismiss()
            } catch {
                self.error = String(format: L("No supported scanner answered at %@. Check the address and that the printer is switched on."),
                                    host.trimmingCharacters(in: .whitespaces))
            }
            working = false
        }
    }
}
