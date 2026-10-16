import AppKit
import HarborCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class LibraryModel: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var selection: InstalledApp.ID?
    @Published var importSession: ImportSession?
    @Published var errorMessage: String?
    @Published var notice: String?

    init() { refresh() }

    func refresh() {
        apps = AppLibrary.installedApps()
        if let selection, !apps.contains(where: { $0.id == selection }) { self.selection = nil }
        if selection == nil { selection = apps.first?.id }
    }

    var selectedApp: InstalledApp? { apps.first { $0.id == selection } }

    func beginImport(_ url: URL) {
        guard importSession == nil || importSession?.isBusy == false else { return }
        importSession = ImportSession(url: url, model: self)
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.ipa, .applicationBundle]
        panel.message = "Choose an iPhone or iPad app (.ipa) to convert"
        if panel.runModal() == .OK, let url = panel.url { beginImport(url) }
    }

    func finishedImport(_ app: InstalledApp) {
        refresh()
        selection = app.id
    }

    func open(_ app: InstalledApp) {
        NSWorkspace.shared.openApplication(at: app.url, configuration: .init()) { _, error in
            if let error { Task { @MainActor in self.errorMessage = error.localizedDescription } }
        }
    }

    func reveal(_ app: InstalledApp) { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }

    func isRunning(_ app: InstalledApp) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
    }

    func relaunch(_ app: InstalledApp) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
        running.forEach { $0.terminate() }
        Task {
            for _ in 0..<50 where running.contains(where: { !$0.isTerminated }) {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            open(app)
        }
    }

    func remove(_ app: InstalledApp, deleteData: Bool) {
        do {
            NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).forEach { $0.terminate() }
            let notes = try AppLibrary.uninstall(app, removeData: deleteData)
            if !notes.isEmpty { notice = notes.joined(separator: "\n") }
            refresh()
        } catch {
            errorMessage = "\(error)"
        }
    }
}

/// One drop-to-installed journey: inspect the package, let the user adjust options, convert.
@MainActor
final class ImportSession: ObservableObject, Identifiable {
    enum Phase {
        case inspecting
        case ready(InspectionReport)
        case converting
        case finished(ConversionResult)
        case failed(String)
    }

    let id = UUID()
    let url: URL
    private weak var model: LibraryModel?

    @Published var phase: Phase = .inspecting
    @Published var log: [String] = []
    @Published var name = ""
    @Published var deviceID = "automatic"
    @Published var bundleID = ""

    var isBusy: Bool {
        switch phase {
        case .inspecting, .converting: return true
        default: return false
        }
    }

    init(url: URL, model: LibraryModel) {
        self.url = url
        self.model = model
        Task.detached { [url] in
            let result = Result { try Inspector.inspect(url) }
            await MainActor.run {
                switch result {
                case .success(let report):
                    self.name = report.name
                    self.phase = report.canConvert ? .ready(report) : .failed(report.problems.joined(separator: "\n"))
                case .failure(let error):
                    self.phase = .failed("\(error)")
                }
            }
        }
    }

    func convert() {
        var options = ConversionOptions(source: url)
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if !trimmedName.isEmpty { options.nameOverride = trimmedName }
        if deviceID != "automatic" { options.deviceProfileID = deviceID }
        let trimmedID = bundleID.trimmingCharacters(in: .whitespaces)
        if !trimmedID.isEmpty { options.bundleIDOverride = trimmedID }
        phase = .converting
        log = []
        Task.detached { [options] in
            let converter = Converter(options: options) { line in
                Task { @MainActor in self.log.append(line) }
            }
            let result = Result { try converter.run() }
            await MainActor.run {
                switch result {
                case .success(let conversion):
                    self.phase = .finished(conversion)
                    self.model?.finishedImport(conversion.app)
                case .failure(let error):
                    self.phase = .failed("\(error)")
                }
            }
        }
    }
}

extension UTType {
    static let ipa = UTType(filenameExtension: "ipa") ?? .zip
}
