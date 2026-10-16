import Foundation

public struct ConversionOptions: Sendable {
    /// An .ipa, or a device-built .app bundle.
    public var source: URL
    public var destinationDirectory = URL(fileURLWithPath: "/Applications", isDirectory: true)
    /// Device profile id; defaults to an iPhone or iPad profile based on the app's device family.
    public var deviceProfileID: String?
    /// Use when the official app is also installed on this Mac, so the two don't share a container.
    public var bundleIDOverride: String?
    public var nameOverride: String?
    public var signingIdentity = "-"
    public var keepExtensions = false
    public var injectRuntime = true
    public var runtimeDirectory: URL?

    public init(source: URL) { self.source = source }
}

public struct ConversionResult: Sendable {
    public let app: InstalledApp
    public let warnings: [String]
}

/// Turns an iOS app package into a Mac app: unpack, patch every binary for Mac Catalyst,
/// inject the runtime, rewrite Info.plist, make a Mac icon, sign, install and register.
public final class Converter {
    public typealias Log = (String) -> Void

    let options: ConversionOptions
    let log: Log
    let fm = FileManager.default
    private var warnings: [String] = []

    public init(options: ConversionOptions, log: @escaping Log = { _ in }) {
        self.options = options
        self.log = log
    }

    public func run() throws -> ConversionResult {
        guard fm.fileExists(atPath: options.source.path) else { throw HarborError.sourceNotFound(options.source.path) }
        let runtimeDir = options.injectRuntime ? try RuntimeLocator.locate(options.runtimeDirectory) : nil

        let work = HarborPaths.workRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        log("Unpacking \(options.source.lastPathComponent)")
        let app = try stage(into: work)
        let infoURL = app.appendingPathComponent("Info.plist")
        guard let original = NSDictionary(contentsOf: infoURL) as? [String: Any] else {
            throw HarborError.invalidBundle("no readable Info.plist")
        }
        guard let exeName = original["CFBundleExecutable"] as? String,
              fm.fileExists(atPath: app.appendingPathComponent(exeName).path) else {
            throw HarborError.invalidBundle("CFBundleExecutable is missing")
        }
        guard let originalID = original["CFBundleIdentifier"] as? String else {
            throw HarborError.invalidBundle("CFBundleIdentifier is missing")
        }
        let mainExe = app.appendingPathComponent(exeName)
        let bundleID = options.bundleIDOverride ?? originalID
        // Checked before this conversion registers the app or creates its settings folder.
        if let clash = AppLibrary.bundleIDClash(bundleID) { warnings.append(clash) }
        let name = Converter.fileSafe(options.nameOverride
            ?? original["CFBundleDisplayName"] as? String
            ?? original["CFBundleName"] as? String
            ?? exeName)

        // Check for FairPlay before doing any work.
        let main = try MachOBinary(contentsOf: mainExe)
        if let cryptID = main.cryptID, cryptID != 0 { throw MachOError.encrypted(exeName) }

        removeIOSOnlyContent(from: app)

        log("Patching binaries for Mac Catalyst")
        var machOFiles = try patchBinaries(in: app, mainExecutable: mainExe, inject: runtimeDir != nil)
        if let runtimeDir { machOFiles += try embedRuntime(from: runtimeDir, into: app) }

        log("Rewriting Info.plist")
        let info = rewriteInfo(original, bundleID: bundleID, originalID: originalID, name: name)

        log("Creating the Mac icon")
        if try IconMaker.makeICNS(for: app, info: original, into: app, name: HarborPaths.iconFileName, workDir: work) {
            var withIcon = info
            withIcon["CFBundleIconFile"] = HarborPaths.iconFileName
            try writeInfo(withIcon, to: infoURL)
        } else {
            try writeInfo(info, to: infoURL)
            warnings.append("No app icon found; the app will use a generic icon.")
        }

        let store = AppStore(bundleID: bundleID)
        let settings = try resolveSettings(store: store, info: original)
        try AppStore.encoder.encode(settings).write(to: app.appendingPathComponent(HarborPaths.defaultsFileName))

        log("Signing (\(options.signingIdentity == "-" ? "ad hoc" : options.signingIdentity))")
        try CodeSigner(identity: options.signingIdentity).signApp(
            app, mainExecutable: mainExe, machOFiles: machOFiles,
            entitlements: Entitlements.make(info: original, bundleID: bundleID), workDir: work)

        log("Installing into \(options.destinationDirectory.path)")
        let destination = try install(app, name: name, bundleID: bundleID)

        let record = InstalledApp(
            bundleID: bundleID, name: name,
            version: original["CFBundleShortVersionString"] as? String ?? "",
            path: destination.path, sourceFile: options.source.path, convertedAt: Date(),
            harborVersion: HarborPaths.harborVersion, warnings: warnings)
        try store.save(record)
        log("Installed \(destination.path)")
        return ConversionResult(app: record, warnings: warnings)
    }

    // MARK: Steps

    private func stage(into work: URL) throws -> URL {
        let payload: URL
        if options.source.pathExtension.lowercased() == "app" {
            payload = work.appendingPathComponent("Payload", isDirectory: true)
            try fm.createDirectory(at: payload, withIntermediateDirectories: true)
            try Shell.run("/usr/bin/ditto", [options.source.path,
                                             payload.appendingPathComponent(options.source.lastPathComponent).path])
        } else {
            let extracted = work.appendingPathComponent("Extracted", isDirectory: true)
            try Shell.run("/usr/bin/ditto", ["-x", "-k", options.source.path, extracted.path])
            payload = extracted.appendingPathComponent("Payload", isDirectory: true)
        }
        let apps = (try? fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)) ?? []
        guard let app = apps.first(where: { $0.pathExtension == "app" }) else { throw HarborError.noAppInArchive }
        return app
    }

    /// Drops content that cannot run on a Mac or would confuse code signing.
    private func removeIOSOnlyContent(from app: URL) {
        var junk = ["_CodeSignature", "embedded.mobileprovision", "SC_Info", "Watch", "com.apple.WatchPlaceholder", "AppClips"]
        if !options.keepExtensions { junk += ["PlugIns", "Extensions"] }
        for item in junk {
            let url = app.appendingPathComponent(item)
            if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
        }
    }

    private func patchBinaries(in app: URL, mainExecutable: URL, inject: Bool) throws -> [URL] {
        var patched: [URL] = []
        var weakened = Set<String>()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let walker = fm.enumerator(at: app, includingPropertiesForKeys: keys) else { return [] }
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, values.isSymbolicLink != true, MachOBinary.isMachO(at: url) else { continue }
            let relative = String(url.path.dropFirst(app.path.count + 1))
            var binary: MachOBinary
            do {
                binary = try MachOBinary(contentsOf: url)
            } catch MachOError.unsupportedArchitecture {
                if url.standardizedFileURL == mainExecutable.standardizedFileURL { throw MachOError.unsupportedArchitecture(relative) }
                warnings.append("\(relative) is 32-bit only and was left out.")
                try fm.removeItem(at: url)
                continue
            }
            if let cryptID = binary.cryptID, cryptID != 0 { throw MachOError.encrypted(relative) }
            try binary.convertToCatalyst()
            for dylib in binary.linkedDylibs where !dylib.isWeak && !SystemLibraryResolver.isAvailableToCatalyst(dylib.path) {
                binary.weakLink(dylibPath: dylib.path)
                if weakened.insert(dylib.path).inserted {
                    warnings.append("\(dylib.path) does not exist on macOS. It is now weak-linked so the app can start; features that use it will not work.")
                }
            }
            if inject && url.standardizedFileURL == mainExecutable.standardizedFileURL {
                try binary.addDylib(path: HarborPaths.runtimeInstallName)
            }
            let permissions = try fm.attributesOfItem(atPath: url.path)[.posixPermissions]
            try binary.write(to: url)
            if let permissions { try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
            patched.append(url)
        }
        return patched
    }

    private func embedRuntime(from runtimeDir: URL, into app: URL) throws -> [URL] {
        let frameworks = app.appendingPathComponent("Frameworks", isDirectory: true)
        try fm.createDirectory(at: frameworks, withIntermediateDirectories: true)
        var copied: [URL] = []
        for name in [HarborPaths.runtimeDylibName, HarborPaths.appKitBridgeName, HarborPaths.webMediaName] {
            let source = runtimeDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            let target = frameworks.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: source, to: target)
            copied.append(target)
        }
        return copied
    }

    private func rewriteInfo(_ original: [String: Any], bundleID: String, originalID: String, name: String) -> [String: Any] {
        var info = original
        info["CFBundleIdentifier"] = bundleID
        if options.nameOverride != nil { info["CFBundleDisplayName"] = name }
        // Keys that make LaunchServices treat the bundle as an iPhone-only package.
        for key in ["LSRequiresIPhoneOS", "UIRequiredDeviceCapabilities", "CFBundleIconName", "MinimumOSVersion"] {
            info.removeValue(forKey: key)
        }
        info["CFBundleSupportedPlatforms"] = ["MacOSX"]
        info["LSMinimumSystemVersion"] = "11.0"
        info["HarborConverted"] = [
            "harborVersion": HarborPaths.harborVersion,
            "originalBundleIdentifier": originalID,
            "convertedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        return info
    }

    private func writeInfo(_ info: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        try data.write(to: url, options: .atomic)
    }

    /// Existing settings survive reconversion; an explicit profile choice replaces the device.
    private func resolveSettings(store: AppStore, info: [String: Any]) throws -> AppSettings {
        let families = (info["UIDeviceFamily"] as? [Int]) ?? [1]
        let fallback = families.contains(2) ? DeviceProfile.defaultPad : DeviceProfile.defaultPhone
        let requested = options.deviceProfileID.flatMap(DeviceProfile.named)
        if let id = options.deviceProfileID, requested == nil {
            warnings.append("Unknown device profile '\(id)'; using \(fallback.name).")
        }
        var settings = store.loadSettings() ?? AppSettings(device: requested ?? fallback, info: info)
        if let requested { settings.device = requested }
        try store.save(settings)
        return settings
    }

    private func install(_ app: URL, name: String, bundleID: String) throws -> URL {
        let directory = options.destinationDirectory
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(name).app", isDirectory: true)

        // An earlier install of the same app under another name is replaced, not duplicated.
        if let previous = AppStore(bundleID: bundleID).loadInstall(), previous.path != destination.path,
           previous.isPresent, AppLibrary.isHarborApp(at: previous.url) {
            try fm.trashItem(at: previous.url, resultingItemURL: nil)
        }

        if fm.fileExists(atPath: destination.path) {
            let existing = NSDictionary(contentsOf: destination.appendingPathComponent("Info.plist"))
            guard AppLibrary.isHarborApp(at: destination), existing?["CFBundleIdentifier"] as? String == bundleID else {
                throw HarborError.destinationTaken(destination.path)
            }
            do {
                _ = try fm.replaceItemAt(destination, withItemAt: app)
            } catch {
                try fm.removeItem(at: destination)
                try fm.copyItem(at: app, to: destination)
            }
        } else {
            try fm.moveItem(at: app, to: destination)
        }

        // The bundle was produced locally from a file the user chose; Gatekeeper's download
        // quarantine would otherwise block the locally signed result.
        try Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destination.path], allowFailure: true)
        try Shell.run(AppLibrary.lsregister, ["-f", destination.path], allowFailure: true)
        try Shell.run("/usr/bin/mdimport", [destination.path], allowFailure: true)
        return destination
    }

    static func fileSafe(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "App" : cleaned
    }
}

enum RuntimeLocator {
    static func locate(_ explicit: URL?) throws -> URL {
        var candidates: [URL] = []
        if let explicit { candidates.append(explicit) }
        if let env = ProcessInfo.processInfo.environment["HARBOR_RUNTIME_DIR"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("Runtime")) }
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
            candidates.append(exe.appendingPathComponent("../Resources/Runtime")) // Harbor.app/Contents/MacOS
            candidates.append(exe.appendingPathComponent("../Runtime"))           // Harbor.app/Contents/Resources/bin
            candidates.append(exe.appendingPathComponent("Runtime"))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/Runtime"))
        for dir in candidates {
            let dylib = dir.appendingPathComponent(HarborPaths.runtimeDylibName)
            if FileManager.default.fileExists(atPath: dylib.path) { return dir.standardizedFileURL }
        }
        throw HarborError.runtimeMissing
    }
}
