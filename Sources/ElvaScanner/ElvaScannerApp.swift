import SwiftUI
import AppKit

@main
struct ElvaScannerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Elva Scanner") {
            ContentView()
                .environmentObject(model)
                .environment(\.locale, Lang.locale)
                .frame(minWidth: 980, minHeight: 680)
                .onAppear {
                    appDelegate.model = model
                    SelfTest.runIfRequested(model)
                    model.updates.checkAutomaticallyIfDue(enabled: model.settings.checkForUpdates)
                }
                .modifier(UpdateAlert(updates: model.updates))
        }
        .defaultSize(width: 1220, height: 860)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button(L("Check for Updates…")) { Task { await model.updates.check(userInitiated: true) } }
            }
            CommandMenu(L("Scan")) {
                Button(L("Preview")) { model.preview() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(model.isBusy || model.selectedScanner == nil)
                Button(L("Scan")) { model.scan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isBusy || model.selectedScanner == nil)
                Button(L("Cancel")) { model.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.isBusy)
                Divider()
                Button(L("Auto Crop")) { model.autoDetect(split: false) }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(model.isBusy)
                Button(L("Split Photos")) { model.autoDetect(split: true) }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(model.isBusy)
                Toggle(L("Batch Scan"), isOn: $model.batchMode)
                    .keyboardShortcut("b", modifiers: .command)
                Divider()
                Button(L("Rotate Left")) { model.rotateSelected(by: -90) }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(model.selectedPage == nil)
                Button(L("Rotate Right")) { model.rotateSelected(by: 90) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.selectedPage == nil)
            }
            CommandGroup(replacing: .saveItem) {
                Button(L("Save…")) { model.showSaveSheet = true }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.pages.isEmpty || model.isBusy)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.cleanUp() }
    }
}

/// Shows the result of an update check.
struct UpdateAlert: ViewModifier {
    @ObservedObject var updates: UpdateChecker

    func body(content: Content) -> some View {
        content.alert(item: $updates.result) { r in
            switch r.kind {
            case .available(let version, let page):
                return Alert(title: Text(String(format: L("Elva Scanner %@ is available"), version)),
                             message: Text(String(format: L("You have version %@. Download the new version and drag it to your Applications folder to replace the old one."), updates.currentVersion)),
                             primaryButton: .default(Text(L("Download"))) { NSWorkspace.shared.open(page) },
                             secondaryButton: .cancel(Text(L("Later"))))
            case .upToDate:
                return Alert(title: Text(L("You're up to date")),
                             message: Text(String(format: L("Elva Scanner %@ is the newest version."), updates.currentVersion)))
            case .failed:
                return Alert(title: Text(L("Couldn't check for updates")),
                             message: Text(L("Check your internet connection and try again.")))
            }
        }
    }
}
