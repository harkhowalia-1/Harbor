import Foundation

/// Per-app runtime settings. Harbor writes them to the app's folder under Application Support;
/// the injected runtime reads them at launch (the sandbox grants it that one folder).
public struct AppSettings: Codable, Equatable, Sendable {
    public enum Orientation: String, Codable, CaseIterable, Sendable { case auto, portrait, landscape }
    public enum MotionSource: String, Codable, CaseIterable, Sendable {
        /// No emulation: CoreMotion reports what the Mac has (nothing).
        case off
        /// Arrow keys tilt the virtual device.
        case keyboard
        /// The first game controller's right stick tilts the virtual device.
        case controller
        /// The pointer's position in the window tilts the virtual device.
        case mouse
    }

    public var device: DeviceProfile
    public var orientation: Orientation = .auto
    /// Window size as a multiple of the device's point size (before the system's Catalyst scaling).
    public var windowScale: Double = 1.0
    public var resizable: Bool = false
    /// With `resizable`, the window can take any shape instead of keeping the device's aspect ratio.
    public var freeAspect: Bool = false
    /// Report the profile's model / hw.machine / system name to app code.
    public var spoofDevice: Bool = true
    /// Report the window's size as the screen size to app code.
    public var spoofScreen: Bool = true
    /// Report the profile's idiom (phone/pad) to app code; UIKit itself still sees an iPad.
    public var spoofIdiom: Bool = true
    /// Fall back to a per-app keychain file when the real keychain rejects an ad-hoc signed app.
    public var keychainEmulation: Bool = true
    public var motion: MotionSource = .keyboard
    public var keymapping: Bool = true
    public var showKeymapHints: Bool = false

    public init(device: DeviceProfile) { self.device = device }

    /// Settings for a newly converted app. Apps that already cope with any window size on iPad
    /// (Split View and Stage Manager) get a freely resizable window, as iPad apps do on a Mac.
    public init(device: DeviceProfile, info: [String: Any]) {
        self.init(device: device)
        if AppSettings.supportsAnyWindowShape(info) {
            resizable = true
            freeAspect = true
        }
    }

    /// True for iPad apps that support multitasking: every orientation, and no UIRequiresFullScreen.
    public static func supportsAnyWindowShape(_ info: [String: Any]) -> Bool {
        guard (info["UIDeviceFamily"] as? [Int] ?? [1]).contains(2),
              (info["UIRequiresFullScreen~ipad"] ?? info["UIRequiresFullScreen"]) as? Bool != true else { return false }
        let orientations = Set((info["UISupportedInterfaceOrientations~ipad"] ?? info["UISupportedInterfaceOrientations"])
            as? [String] ?? [])
        return orientations.isSuperset(of: ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
                                            "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"])
    }

    public init(from decoder: Decoder) throws {
        // Every field is optional on disk so older settings files keep loading.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        device = try c.decodeIfPresent(DeviceProfile.self, forKey: .device) ?? .defaultPhone
        orientation = try c.decodeIfPresent(Orientation.self, forKey: .orientation) ?? .auto
        windowScale = try c.decodeIfPresent(Double.self, forKey: .windowScale) ?? 1.0
        resizable = try c.decodeIfPresent(Bool.self, forKey: .resizable) ?? false
        freeAspect = try c.decodeIfPresent(Bool.self, forKey: .freeAspect) ?? false
        spoofDevice = try c.decodeIfPresent(Bool.self, forKey: .spoofDevice) ?? true
        spoofScreen = try c.decodeIfPresent(Bool.self, forKey: .spoofScreen) ?? true
        spoofIdiom = try c.decodeIfPresent(Bool.self, forKey: .spoofIdiom) ?? true
        keychainEmulation = try c.decodeIfPresent(Bool.self, forKey: .keychainEmulation) ?? true
        motion = try c.decodeIfPresent(MotionSource.self, forKey: .motion) ?? .keyboard
        keymapping = try c.decodeIfPresent(Bool.self, forKey: .keymapping) ?? true
        showKeymapHints = try c.decodeIfPresent(Bool.self, forKey: .showKeymapHints) ?? false
    }
}

/// Facts about one converted app, stored next to its settings.
public struct InstalledApp: Codable, Equatable, Identifiable, Sendable {
    public var id: String { bundleID }
    public var bundleID: String
    public var name: String
    public var version: String
    public var path: String
    public var sourceFile: String
    public var convertedAt: Date
    public var harborVersion: String
    public var warnings: [String]

    public var url: URL { URL(fileURLWithPath: path) }
    public var isPresent: Bool { FileManager.default.fileExists(atPath: path) }
}

public enum HarborPaths {
    public static let harborVersion = "1.0"
    public static let runtimeDylibName = "libHarborRuntime.dylib"
    public static let appKitBridgeName = "libHarborAppKit.dylib"
    /// Camera, microphone and recording for web views; loaded by the runtime when the app creates one.
    public static let webMediaName = "libHarborWebMedia.dylib"
    /// Where the runtime is linked from inside a flat (iOS-layout) bundle.
    public static let runtimeInstallName = "@executable_path/Frameworks/\(runtimeDylibName)"
    public static let defaultsFileName = "HarborDefaults.json"
    public static let iconFileName = "HarborIcon"

    public static var realHome: URL { URL(fileURLWithPath: NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()) }

    public static var supportRoot: URL {
        realHome.appendingPathComponent("Library/Application Support/Harbor", isDirectory: true)
    }

    public static var appsRoot: URL { supportRoot.appendingPathComponent("Apps", isDirectory: true) }

    public static func appFolder(_ bundleID: String) -> URL {
        appsRoot.appendingPathComponent(bundleID, isDirectory: true)
    }

    /// Home-relative path the converted app's sandbox may read and write.
    public static func sandboxExceptionPath(_ bundleID: String) -> String {
        "/Library/Application Support/Harbor/Apps/\(bundleID)/"
    }

    public static func container(_ bundleID: String) -> URL {
        realHome.appendingPathComponent("Library/Containers/\(bundleID)", isDirectory: true)
    }

    public static var workRoot: URL {
        realHome.appendingPathComponent("Library/Caches/Harbor/Work", isDirectory: true)
    }
}

/// Reads and writes an app's settings.json, keymap.json and install.json.
public struct AppStore {
    public let bundleID: String
    public init(bundleID: String) { self.bundleID = bundleID }

    public var folder: URL { HarborPaths.appFolder(bundleID) }
    public var settingsURL: URL { folder.appendingPathComponent("settings.json") }
    public var keymapURL: URL { folder.appendingPathComponent("keymap.json") }
    public var installURL: URL { folder.appendingPathComponent("install.json") }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func loadSettings() -> AppSettings? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return try? AppStore.decoder.decode(AppSettings.self, from: data)
    }

    public func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try AppStore.encoder.encode(settings).write(to: settingsURL, options: .atomic)
    }

    public func loadInstall() -> InstalledApp? {
        guard let data = try? Data(contentsOf: installURL) else { return nil }
        return try? AppStore.decoder.decode(InstalledApp.self, from: data)
    }

    public func save(_ install: InstalledApp) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try AppStore.encoder.encode(install).write(to: installURL, options: .atomic)
    }

    /// Keymap elements as stored by the in-app editor (opaque to Harbor apart from a count).
    public func keymapElementCount() -> Int {
        guard let data = try? Data(contentsOf: keymapURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = json["elements"] as? [Any] else { return 0 }
        return elements.count
    }

    public func resetKeymap() throws {
        if FileManager.default.fileExists(atPath: keymapURL.path) {
            try FileManager.default.removeItem(at: keymapURL)
        }
    }
}
