import SwiftUI

/// Save flow: choose what the scans are (one document, or separate photos), pick and order the
/// pages, then the format. Output options only appear here, once there is something to save.
struct SaveSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind: SaveKind = .document
    @State private var included: Set<UUID> = []
    @State private var name = ""

    private var selectedPages: [ScannedPage] { model.pages.filter { included.contains($0.id) } }

    private var format: Binding<OutputFormat> {
        kind == .document ? $model.settings.documentFormat : $model.settings.photoFormat
    }

    var body: some View {
        VStack(spacing: 0) {
            kindPicker.padding(20)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                pageList.frame(width: 300)
                Divider()
                options.frame(maxWidth: .infinity)
            }
            Divider()
            footer.padding(16)
        }
        .frame(width: 760, height: 560)
        .onAppear {
            kind = model.defaultSaveKind
            included = Set(model.pages.map(\.id))
            name = model.defaultFileName(kind: kind)
        }
        .onChange(of: kind) { name = model.defaultFileName(kind: kind) }
    }

    // MARK: Kind

    private var kindPicker: some View {
        HStack(spacing: 14) {
            KindCard(selected: kind == .document, icon: "doc.richtext", title: L("Document"),
                     detail: L("All pages in one file, in the order shown. Best for letters, contracts, receipts.")) {
                kind = .document
            }
            KindCard(selected: kind == .photos, icon: "photo.on.rectangle", title: L("Photos"),
                     detail: L("Each page saved as its own image file. Best for photos and pictures.")) {
                kind = .photos
            }
        }
    }

    // MARK: Pages

    private var pageList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Pages")).font(.headline)
                Spacer()
                Button(L("All")) { included = Set(model.pages.map(\.id)) }
                Button(L("None")) { included = [] }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14).padding(.vertical, 10)
            List {
                ForEach(Array(model.pages.enumerated()), id: \.element.id) { i, page in
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { included.contains(page.id) },
                            set: { if $0 { included.insert(page.id) } else { included.remove(page.id) } }))
                            .labelsHidden()
                        PageRowThumb(page: page)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: L("Page %d"), i + 1))
                            Text(page.mode.title).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                    }
                }
                .onMove { from, to in model.pages.move(fromOffsets: from, toOffset: to) }
            }
            .listStyle(.inset)
            Text(kind == .document ? L("Drag pages to change their order in the document.") : L("Files are numbered in this order."))
                .font(.caption).foregroundStyle(.secondary)
                .padding(10)
        }
    }

    // MARK: Options

    private var options: some View {
        Form {
            Section {
                Picker(L("Format"), selection: format) {
                    ForEach(kind == .document ? OutputFormat.documentFormats : OutputFormat.photoFormats) {
                        Text($0.label).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                Text(formatHint).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if format.wrappedValue.isLossy {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(L("Quality"))
                            Spacer()
                            Text(qualityLabel).foregroundStyle(.secondary)
                        }
                        Slider(value: $model.settings.quality, in: 0.4...1.0)
                        HStack {
                            Text(L("Smaller file")); Spacer(); Text(L("Better quality"))
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if format.wrappedValue == .pdf {
                Section {
                    Toggle(L("Searchable text (OCR)"), isOn: $model.settings.searchablePDF)
                    Text(L("Recognises the text on each page so you can search, select and copy it. Takes a few seconds per page."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                TextField(kind == .document ? L("File name") : L("File name prefix"), text: $name)
                Toggle(L("Remove saved pages from the list"), isOn: $model.settings.clearAfterSave)
            }
        }
        .formStyle(.grouped)
    }

    private var formatHint: String {
        switch format.wrappedValue {
        case .pdf: return L("Opens everywhere. Pages are compressed as JPEG; black & white pages stay sharp.")
        case .tiff: return kind == .document ? L("Lossless multi-page file; large, for archiving.") : L("Lossless, large files – for archiving or further editing.")
        case .jpeg: return L("Compatible with everything; good for sharing.")
        case .heic: return L("About half the size of JPEG at the same quality; opens on Apple devices.")
        case .png: return L("Lossless; good for graphics and screenshots, large for photos.")
        }
    }

    private var qualityLabel: String {
        let q = model.settings.quality
        return q >= 0.92 ? L("Maximum") : q >= 0.8 ? L("High") : q >= 0.6 ? L("Medium") : L("Compact")
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text(summary).foregroundStyle(.secondary)
            Spacer()
            Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
            Button(L("Save…")) {
                let pages = selectedPages
                let k = kind, f = format.wrappedValue, n = name
                dismiss()
                DispatchQueue.main.async { model.save(pages, kind: k, format: f, name: n) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(selectedPages.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var summary: String {
        let n = selectedPages.count
        if kind == .document {
            return String(format: L("%d pages → 1 %@ file"), n, format.wrappedValue.label)
        }
        return String(format: L("%d pages → %d %@ files"), n, n, format.wrappedValue.label)
    }
}

private struct KindCard: View {
    let selected: Bool
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(.system(size: 28)).frame(width: 36)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PageRowThumb: View {
    @ObservedObject var page: ScannedPage
    var body: some View {
        Group {
            if let t = page.thumbnail {
                Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: 36, height: 44)
    }
}
