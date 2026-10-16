import AppKit
import HarborCore
import SwiftUI

@main
struct HarborApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = LibraryModel()

    var body: some Scene {
        Window("Harbor", id: "library") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 520)
                .onAppear { delegate.model = model }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add App…") { model.chooseFile() }
                    .keyboardShortcut("o")
            }
        }
    }
}

/// Receives .ipa files opened from Finder or dropped on the Dock icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var model: LibraryModel? {
        didSet {
            pending.forEach { model?.beginImport($0) }
            pending = []
        }
    }
    @MainActor private var pending: [URL] = []

    @MainActor func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let model { model.beginImport(url) } else { pending.append(url) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
