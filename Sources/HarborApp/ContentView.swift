import AppKit
import HarborCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: LibraryModel
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(model.apps) { app in
                    AppRow(app: app).tag(app.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .overlay {
                if model.apps.isEmpty {
                    Text("No apps yet").foregroundStyle(.secondary)
                }
            }
            .toolbar {
                ToolbarItem {
                    Button { model.chooseFile() } label: { Label("Add App", systemImage: "plus") }
                        .help("Convert an iPhone or iPad app (⌘O)")
                }
            }
        } detail: {
            if let app = model.selectedApp {
                AppDetailView(app: app).id(app.id)
            } else {
                DropZone(targeted: dropTargeted)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { ["ipa", "app"].contains($0.pathExtension.lowercased()) }) else { return false }
            model.beginImport(url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .sheet(item: $model.importSession) { session in
            ImportSheet(session: session)
        }
        .alert("Something went wrong", isPresented: .constant(model.errorMessage != nil)) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Removed", isPresented: .constant(model.notice != nil)) {
            Button("OK") { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
    }
}

struct AppRow: View {
    let app: InstalledApp

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(app: app, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).lineLimit(1)
                Text(app.isPresent ? app.version : "Missing").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct AppIcon: View {
    let app: InstalledApp
    let size: CGFloat

    var body: some View {
        Image(nsImage: app.isPresent ? NSWorkspace.shared.icon(forFile: app.path)
                                     : NSWorkspace.shared.icon(for: .applicationBundle))
            .resizable()
            .frame(width: size, height: size)
    }
}

struct DropZone: View {
    @EnvironmentObject private var model: LibraryModel
    let targeted: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
            Text("Drop an iPhone or iPad app here")
                .font(.title2.weight(.semibold))
            Text("Harbor turns a decrypted .ipa into a Mac app in /Applications, with its own window,\nDock icon, Launchpad and Spotlight entry, and save data.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Choose File…") { model.chooseFile() }
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.35))
                .padding(24)
        }
    }
}
