import SwiftUI
import UniformTypeIdentifiers

/// A scanned page with the current adjustments applied.
struct PageView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var page: ScannedPage

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { model.selectedPageID = nil } label: {
                    Label(L("Back to Glass"), systemImage: "chevron.backward")
                }
                .controlSize(.large)
                .help(L("Return to the glass to scan more"))
                Spacer()
                Text(page.pixelSizeDescription).font(.caption).foregroundStyle(.secondary)
                if page.isRendering { ProgressView().controlSize(.small) }
                Spacer()
                Button { model.rotateSelected(by: -90) } label: { Image(systemName: "rotate.left") }
                    .help(L("Rotate left (⌘L)"))
                Button { model.rotateSelected(by: 90) } label: { Image(systemName: "rotate.right") }
                    .help(L("Rotate right (⇧⌘R)"))
                Button(role: .destructive) { model.deletePage(page) } label: { Image(systemName: "trash") }
                    .help(L("Delete this page"))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16).padding(.vertical, 10)

            GeometryReader { geo in
                if let img = page.display {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(20)
        }
    }
}

/// The tray of scanned pages: click to edit, drag to reorder, then save.
struct PageStrip: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmClear = false
    @State private var dropTarget: UUID?

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                            PageThumb(page: page, number: index + 1, selected: page.id == model.selectedPageID,
                                      dropHighlight: dropTarget == page.id)
                                .id(page.id)
                                .onTapGesture { model.selectedPageID = page.id }
                                .draggable(page.id.uuidString)
                                .dropDestination(for: String.self) { items, _ in
                                    guard let s = items.first, let id = UUID(uuidString: s) else { return false }
                                    withAnimation { model.movePage(id: id, before: page.id) }
                                    return true
                                } isTargeted: { dropTarget = $0 ? page.id : (dropTarget == page.id ? nil : dropTarget) }
                                .contextMenu {
                                    Button(L("Move Left")) { model.movePage(page, by: -1) }.disabled(index == 0)
                                    Button(L("Move Right")) { model.movePage(page, by: 1) }.disabled(index == model.pages.count - 1)
                                    Divider()
                                    Button(L("Delete"), role: .destructive) { model.deletePage(page) }
                                }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
                .onChange(of: model.pages.count) {
                    if let last = model.pages.last { withAnimation { proxy.scrollTo(last.id) } }
                }
            }
            Divider()
            VStack(spacing: 8) {
                Button { model.showSaveSheet = true } label: {
                    Label(L("Save…"), systemImage: "square.and.arrow.down").frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isBusy)
                Text(String(format: L("%d pages · drag to reorder"), model.pages.count))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L("Clear All…")) { confirmClear = true }
                    .buttonStyle(.borderless).font(.caption)
            }
            .frame(width: 170)
        }
        .frame(height: 140)
        .background(.bar)
        .confirmationDialog(String(format: L("Discard all %d scanned pages?"), model.pages.count), isPresented: $confirmClear) {
            Button(L("Discard Pages"), role: .destructive) { model.clearPages() }
        } message: {
            Text(L("Pages that have not been saved will be lost."))
        }
    }
}

struct PageThumb: View {
    @ObservedObject var page: ScannedPage
    let number: Int
    let selected: Bool
    var dropHighlight = false

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let t = page.thumbnail {
                    Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(.quaternary).overlay(ProgressView().controlSize(.small))
                }
            }
            .frame(width: 70, height: 84)
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.25) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(dropHighlight ? Color.orange : selected ? Color.accentColor : Color.secondary.opacity(0.3),
                        lineWidth: selected || dropHighlight ? 2 : 1))
            HStack(spacing: 3) {
                Image(systemName: page.mode.icon).font(.system(size: 9))
                Text("\(number)")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}
