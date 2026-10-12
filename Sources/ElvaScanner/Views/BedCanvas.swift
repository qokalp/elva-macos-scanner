import SwiftUI

/// Tools above the glass: automatic cropping, splitting into several items, area mode.
struct GlassToolbar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Button { model.autoDetect(split: false) } label: {
                Label(L("Auto Crop"), systemImage: "crop")
            }
            .help(L("Find what is on the glass and select just that (previews first if needed)"))

            Button { model.autoDetect(split: true) } label: {
                Label(L("Split Photos"), systemImage: "rectangle.split.2x2")
            }
            .help(L("Find every photo on the glass and scan each one as its own page"))

            Divider().frame(height: 18)

            Picker("", selection: Binding(get: { model.settings.multiRegion }, set: { model.setMultiRegion($0) })) {
                Text(L("Single Area")).tag(false)
                Text(L("Multiple Areas")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(L("Multiple Areas: drag on empty glass to add more areas; each becomes a separate page"))

            Spacer()

            if model.settings.multiRegion && model.regions.count > 1 {
                Text(String(format: L("%d areas"), model.regions.count)).foregroundStyle(.secondary)
            }
            Button { model.applyPreset(.fullBed) } label: {
                Label(L("Entire Glass"), systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help(L("Select the whole glass (double-click the glass)"))
        }
        .disabled(model.isBusy)
        .controlSize(.large)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

/// The scanner glass: shows the preview and lets the user draw, move and resize scan areas.
struct BedCanvas: View {
    @EnvironmentObject var model: AppModel
    @State private var drag: DragState?

    struct DragState {
        enum Kind { case create(CGPoint), move, resize(Corner) }
        var kind: Kind
        var index: Int
        var startArea: ScanArea
    }
    enum Corner { case topLeft, topRight, bottomLeft, bottomRight }

    var body: some View {
        GeometryReader { geo in
            let caps = model.capabilities
            let bed = fitRect(in: geo.size, inset: 20, aspect: caps.bedWidth / caps.bedHeight)
            let scale = bed.width / caps.bedWidth   // points per inch
            let rects = model.settings.activeRegions.map { a in
                CGRect(x: bed.minX + a.x * scale, y: bed.minY + a.y * scale, width: a.width * scale, height: a.height * scale)
            }

            ZStack(alignment: .topLeading) {
                glass(bed: bed)

                // Dim everything outside the areas
                Path { p in
                    p.addRect(bed)
                    rects.forEach { p.addRect($0) }
                }
                .fill(Color.black.opacity(0.35), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                ForEach(Array(rects.enumerated()), id: \.offset) { i, r in
                    regionOverlay(r, index: i, total: rects.count, bed: bed)
                }

                // Hint above the dimming, so it stays readable whatever is selected.
                if model.previewImage == nil {
                    VStack(spacing: 8) {
                        Image(systemName: "scanner").font(.system(size: 34, weight: .light))
                        Text(L("Place the item face down on the glass, then click Preview."))
                            .font(.headline)
                        Text(L("Drag on the glass to choose what to scan, or use Auto Crop."))
                            .font(.callout)
                    }
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(18)
                    .frame(maxWidth: min(360, bed.width - 32))
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .position(x: bed.midX, y: bed.midY)
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { g in handleDrag(g, bed: bed, scale: scale, rects: rects) }
                    .onEnded { _ in drag = nil }
            )
            .onTapGesture(count: 2) { model.applyPreset(.fullBed) }
        }
    }

    @ViewBuilder
    private func glass(bed: CGRect) -> some View {
        Group {
            if let preview = model.previewImage {
                Image(decorative: preview, scale: 1).resizable().interpolation(.high)
            } else {
                Rectangle().fill(Color.secondary.opacity(0.07))
            }
        }
        .frame(width: bed.width, height: bed.height)
        .overlay(Rectangle().stroke(Color.secondary.opacity(0.35), lineWidth: 1))
        .offset(x: bed.minX, y: bed.minY)
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }

    @ViewBuilder
    private func regionOverlay(_ r: CGRect, index i: Int, total: Int, bed: CGRect) -> some View {
        let selected = i == model.selectedRegionIndex || total == 1
        let area = model.settings.activeRegions[i]
        Rectangle()
            .strokeBorder(Color.accentColor, lineWidth: selected ? 2.5 : 1.5)
            .frame(width: r.width, height: r.height)
            .offset(x: r.minX, y: r.minY)
            .allowsHitTesting(false)
        if selected {
            ForEach(Array(corners(of: r).enumerated()), id: \.offset) { _, pt in
                Circle().fill(Color.accentColor)
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .frame(width: 11, height: 11)
                    .position(pt)
                    .allowsHitTesting(false)
            }
        }
        // Label: number (multi) + size
        HStack(spacing: 4) {
            if total > 1 { Text("\(i + 1)").bold() }
            Text(String(format: "%.1f × %.1f cm", area.width * 2.54, area.height * 2.54))
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(.regularMaterial, in: Capsule())
        .position(x: r.midX, y: max(r.minY - 12, bed.minY + 10))
        .allowsHitTesting(false)
        if total > 1 {
            Button { model.removeRegion(at: i) } label: {
                Image(systemName: "xmark.circle.fill").font(.title3)
                    .symbolRenderingMode(.palette).foregroundStyle(.white, .red)
            }
            .buttonStyle(.plain)
            .help(L("Remove this area"))
            .position(x: r.maxX - 4, y: r.minY + 4)
        }
    }

    private func handleDrag(_ g: DragGesture.Value, bed: CGRect, scale: CGFloat, rects: [CGRect]) {
        if drag == nil {
            let regions = model.settings.activeRegions
            // Prefer the selected area when areas overlap.
            let order = [model.selectedRegionIndex] + rects.indices.filter { $0 != model.selectedRegionIndex }
            var found: DragState?
            for i in order where rects.indices.contains(i) {
                if let c = corner(near: g.startLocation, in: rects[i]) {
                    found = DragState(kind: .resize(c), index: i, startArea: regions[i]); break
                }
            }
            if found == nil {
                // An area covering (almost) the whole glass can't be moved; drawing inside it starts a new one.
                let caps = model.capabilities
                for i in order where rects.indices.contains(i) && rects[i].contains(g.startLocation)
                    && !(regions[i].width > caps.bedWidth * 0.95 && regions[i].height > caps.bedHeight * 0.95) {
                    found = DragState(kind: .move, index: i, startArea: regions[i]); break
                }
            }
            if found == nil {
                let p = inches(g.startLocation, bed: bed, scale: scale)
                let idx = model.addRegion(ScanArea(x: p.x, y: p.y, width: 0.25, height: 0.25))
                found = DragState(kind: .create(g.startLocation), index: idx, startArea: model.regions[idx])
            }
            drag = found
            if let f = found { model.selectedRegionIndex = f.index }
        }
        guard let d = drag else { return }
        let start = d.startArea
        var a = start
        switch d.kind {
        case .create(let origin):
            let p0 = inches(origin, bed: bed, scale: scale), p1 = inches(g.location, bed: bed, scale: scale)
            a = ScanArea(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p1.x - p0.x), height: abs(p1.y - p0.y))
        case .move:
            a.x = start.x + g.translation.width / scale
            a.y = start.y + g.translation.height / scale
        case .resize(let c):
            let p = inches(g.location, bed: bed, scale: scale)
            var x0 = start.minX, y0 = start.minY, x1 = start.maxX, y1 = start.maxY
            switch c {
            case .topLeft: x0 = p.x; y0 = p.y
            case .topRight: x1 = p.x; y0 = p.y
            case .bottomLeft: x0 = p.x; y1 = p.y
            case .bottomRight: x1 = p.x; y1 = p.y
            }
            a = ScanArea(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
        }
        model.updateRegion(at: d.index, to: a)
    }

    private func inches(_ p: CGPoint, bed: CGRect, scale: CGFloat) -> CGPoint {
        CGPoint(x: (min(max(p.x, bed.minX), bed.maxX) - bed.minX) / scale,
                y: (min(max(p.y, bed.minY), bed.maxY) - bed.minY) / scale)
    }

    private func corners(of r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
    }

    private func corner(near p: CGPoint, in r: CGRect) -> Corner? {
        let tol: CGFloat = 12
        let list: [(CGPoint, Corner)] = [
            (CGPoint(x: r.minX, y: r.minY), .topLeft), (CGPoint(x: r.maxX, y: r.minY), .topRight),
            (CGPoint(x: r.minX, y: r.maxY), .bottomLeft), (CGPoint(x: r.maxX, y: r.maxY), .bottomRight),
        ]
        return list.first { hypot($0.0.x - p.x, $0.0.y - p.y) <= tol }?.1
    }
}

func fitRect(in size: CGSize, inset: CGFloat, aspect: CGFloat) -> CGRect {
    let avail = CGSize(width: max(1, size.width - 2 * inset), height: max(1, size.height - 2 * inset))
    var w = avail.width, h = w / aspect
    if h > avail.height { h = avail.height; w = h * aspect }
    return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: max(w, 1), height: max(h, 1))
}
