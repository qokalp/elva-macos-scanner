import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 320, max: 400)
        } detail: {
            DetailView()
        }
        .toolbar { toolbar }
        .sheet(isPresented: $model.showSaveSheet) { SaveSheet() }
        .alert(L("Scanner Problem"), isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })) {
            Button(L("OK"), role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            StatusText()
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.showSaveSheet = true } label: {
                Label(model.pages.isEmpty ? L("Save") : String(format: L("Save %d…"), model.pages.count),
                      systemImage: "square.and.arrow.down")
                    .labelStyle(.titleAndIcon)
            }
            .help(L("Save the scanned pages as a document or as photos (⌘S)"))
            .disabled(model.pages.isEmpty || model.isBusy)
        }
    }
}

struct StatusText: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if let s = model.statusMessage {
                Text(s)
            } else if let scanner = model.selectedScanner {
                Text(scanner.displayName)
            } else {
                Text(L("No scanner"))
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(minWidth: 240)
    }
}

struct DetailView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let page = model.selectedPage {
                PageView(page: page)
            } else {
                GlassView()
            }
            if !model.pages.isEmpty {
                Divider()
                PageStrip()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The glass with its tools on top and the main scan actions below.
struct GlassView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            GlassToolbar()
            BedCanvas()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.batchMode && model.waitingForNextPage && !model.isBusy {
                BatchPrompt().padding(.horizontal, 20).padding(.bottom, 8)
            }
            ScanActionBar()
        }
    }
}

/// Large, always-visible Preview / Scan / Batch controls. Shows progress while the scanner works.
struct ScanActionBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            if let a = model.activity {
                ProgressPanel(activity: a)
            } else {
                Button { model.preview() } label: {
                    Label(L("Preview"), systemImage: "eye")
                        .frame(minWidth: 110)
                }
                .controlSize(.extraLarge)
                .help(L("Quick low-resolution scan of the whole glass (⇧⌘P)"))

                Button { model.scan() } label: {
                    Label(scanTitle, systemImage: "scanner.fill")
                        .font(.title3.weight(.semibold))
                        .frame(minWidth: 220)
                }
                .controlSize(.extraLarge)
                .buttonStyle(.borderedProminent)
                .help(L("Scan with the current settings (⌘R)"))

                Toggle(isOn: $model.batchMode) {
                    Label(L("Batch Scan"), systemImage: "square.stack.3d.down.right")
                        .frame(minWidth: 120)
                }
                .toggleStyle(.button)
                .controlSize(.extraLarge)
                .tint(model.batchMode ? .orange : nil)
                .help(L("Batch scanning: scan many pages one after another, then save them together (⌘B)"))
            }
        }
        .disabled(model.selectedScanner == nil && model.activity == nil)
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var scanTitle: String {
        let n = model.settings.activeRegions.count
        if model.batchMode { return String(format: L("Scan Page %d"), model.pages.count + 1) }
        return n > 1 ? String(format: L("Scan %d Items"), n) : L("Scan")
    }
}

private struct ProgressPanel: View {
    @EnvironmentObject var model: AppModel
    let activity: Activity

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(activity.title).font(.headline)
                    Spacer()
                    if let f = activity.fraction { Text("\(Int(f * 100))%").monospacedDigit().foregroundStyle(.secondary) }
                }
                if let f = activity.fraction {
                    ProgressView(value: f)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            .frame(maxWidth: 460)
            Button(role: .cancel) { model.cancel() } label: {
                Label(L("Cancel"), systemImage: "xmark.circle").frame(minWidth: 90)
            }
            .controlSize(.extraLarge)
            .disabled(!activity.cancellable)
        }
    }
}

struct BatchPrompt: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.on.doc").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: L("Page %d scanned"), model.pages.count)).font(.headline)
                if let c = model.countdown {
                    Text(String(format: L("Place the next page on the glass. Scanning in %d s…"), c)).foregroundStyle(.secondary)
                } else {
                    Text(L("Place the next page on the glass and close the lid, then press Scan.")).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 20)
            if model.countdown != nil {
                Button(L("Pause")) { model.stopCountdown() }
            }
            Button(L("Finish & Save…")) {
                model.batchMode = false
                model.showSaveSheet = true
            }
        }
        .padding(12)
        .frame(maxWidth: 720)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.orange.opacity(0.5)))
    }
}
