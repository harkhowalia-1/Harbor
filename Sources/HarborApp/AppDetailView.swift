import HarborCore
import SwiftUI

struct AppDetailView: View {
    @EnvironmentObject private var model: LibraryModel
    let app: InstalledApp

    @State private var settings: AppSettings
    @State private var keymapCount: Int
    @State private var confirmingRemove = false
    @State private var removeData = false
    @State private var running = false
    private let store: AppStore

    init(app: InstalledApp) {
        self.app = app
        store = AppStore(bundleID: app.bundleID)
        _settings = State(initialValue: store.loadSettings() ?? AppSettings(device: .defaultPhone))
        _keymapCount = State(initialValue: store.keymapElementCount())
    }

    var body: some View {
        Form {
            Section { header }

            if !app.warnings.isEmpty {
                Section("Conversion notes") {
                    ForEach(app.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    }
                }
            }

            Section("Device") {
                Picker("Present as", selection: $settings.device) {
                    ForEach(DeviceProfile.all) { profile in
                        Text("\(profile.name) — \(Int(profile.width))×\(Int(profile.height))").tag(profile)
                    }
                }
                Picker("Orientation", selection: $settings.orientation) {
                    Text("Automatic").tag(AppSettings.Orientation.auto)
                    Text("Portrait").tag(AppSettings.Orientation.portrait)
                    Text("Landscape").tag(AppSettings.Orientation.landscape)
                }
                LabeledContent("Window size") {
                    HStack {
                        Slider(value: $settings.windowScale, in: 0.5...2, step: 0.05)
                        Text("\(Int(settings.windowScale * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Toggle("Resizable window", isOn: $settings.resizable)
                Toggle("Keep the device's aspect ratio", isOn: Binding(get: { !settings.freeAspect },
                                                                       set: { settings.freeAspect = !$0 }))
                    .disabled(!settings.resizable)
                    .help("Turn off for apps that lay themselves out for any window shape.")
            }

            Section {
                Toggle("Map keys and controller buttons to touches", isOn: $settings.keymapping)
                Toggle("Show mapped controls over the app", isOn: $settings.showKeymapHints)
                Picker("Tilt (accelerometer & gyroscope)", selection: $settings.motion) {
                    Text("Off").tag(AppSettings.MotionSource.off)
                    Text("Arrow keys").tag(AppSettings.MotionSource.keyboard)
                    Text("Controller right stick").tag(AppSettings.MotionSource.controller)
                    Text("Pointer position").tag(AppSettings.MotionSource.mouse)
                }
                LabeledContent("Keymap") {
                    HStack {
                        Text(keymapCount == 0 ? "None" : "\(keymapCount) control\(keymapCount == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                        if keymapCount > 0 {
                            Button("Reset") {
                                try? store.resetKeymap()
                                keymapCount = 0
                            }
                        }
                    }
                }
            } header: {
                Text("Input")
            } footer: {
                Text("In the app: ⌘⇧K edits the keymap on top of the live app, ⌘⇧M turns mapping off for typing, ⌘⇧H shows or hides the mapped controls.")
            }

            Section {
                Toggle("Report \(settings.device.model) model and identifier (\(settings.device.machine))", isOn: $settings.spoofDevice)
                Toggle("Report the window as the screen size", isOn: $settings.spoofScreen)
                Toggle("Report the \(settings.device.idiom == .phone ? "iPhone" : "iPad") interface idiom", isOn: $settings.spoofIdiom)
                Toggle("Keep keychain items in the app's own container", isOn: $settings.keychainEmulation)
            } header: {
                Text("Compatibility")
            } footer: {
                Text("Only the app's own code sees these values; macOS and UIKit keep seeing the real Mac.")
            }

            Section {
                HStack {
                    Text("Changes apply the next time \(app.name) opens.").foregroundStyle(.secondary)
                    Spacer()
                    if running { Button("Relaunch Now") { model.relaunch(app) } }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings) { _, newValue in try? store.save(newValue) }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            running = model.isRunning(app)
            keymapCount = store.keymapElementCount()
        }
        .onAppear { running = model.isRunning(app) }
        .confirmationDialog("Remove \(app.name)?", isPresented: $confirmingRemove) {
            Button("Move to Trash", role: .destructive) { model.remove(app, deleteData: removeData) }
        } message: {
            Text(removeData ? "The app, its saved data and its Harbor settings will be moved to the Trash."
                            : "The app will be moved to the Trash. Its saved data stays, so reinstalling picks up where you left off.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            AppIcon(app: app, size: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.title.weight(.semibold))
                Text("Version \(app.version) · \(app.bundleID)").foregroundStyle(.secondary)
                Text(app.path).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
                HStack {
                    Button("Open") { model.open(app) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!app.isPresent)
                    Button("Show in Finder") { model.reveal(app) }
                        .disabled(!app.isPresent)
                    Button("Convert Again…") { model.beginImport(URL(fileURLWithPath: app.sourceFile)) }
                        .disabled(!FileManager.default.fileExists(atPath: app.sourceFile))
                        .help(app.sourceFile)
                    Spacer()
                    Menu("Remove") {
                        Button("Remove App…") {
                            removeData = false
                            confirmingRemove = true
                        }
                        Button("Remove App and Its Data…") {
                            removeData = true
                            confirmingRemove = true
                        }
                    }
                    .fixedSize()
                }
                .padding(.top, 6)
            }
        }
        .padding(.vertical, 6)
    }
}
