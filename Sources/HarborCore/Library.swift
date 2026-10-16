import CoreServices
import Foundation

public enum HarborError: Error, CustomStringConvertible {
    case sourceNotFound(String)
    case noAppInArchive
    case invalidBundle(String)
    case destinationTaken(String)
    case runtimeMissing

    public var description: String {
        switch self {
        case .sourceNotFound(let p): return "No such file: \(p)"
        case .noAppInArchive: return "The archive has no Payload/*.app inside; is it really an .ipa?"
        case .invalidBundle(let why): return "Not a usable iOS app bundle: \(why)"
        case .destinationTaken(let p): return "\(p) already exists and was not created by Harbor. Remove it or choose another name."
        case .runtimeMissing: return "Harbor's runtime (\(HarborPaths.runtimeDylibName)) was not found. Run scripts/build.sh, or set HARBOR_RUNTIME_DIR."
        }
    }
}

/// The set of apps Harbor has converted, tracked through each app's install.json.
public enum AppLibrary {
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    public static func installedApps() -> [InstalledApp] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: HarborPaths.appsRoot, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { AppStore(bundleID: $0.lastPathComponent).loadInstall() }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func find(_ query: String) -> InstalledApp? {
        let apps = installedApps()
        return apps.first { $0.bundleID == query }
            ?? apps.first { $0.name.caseInsensitiveCompare(query) == .orderedSame }
            ?? apps.first { $0.path == URL(fileURLWithPath: query).standardizedFileURL.path }
    }

    /// True when the bundle at `url` was produced by Harbor (it carries the HarborConverted marker).
    public static func isHarborApp(at url: URL) -> Bool {
        guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist")) else { return false }
        return info["HarborConverted"] != nil
    }

    /// Moves the app to the Trash. With `removeData`, its sandbox container and Harbor settings go too.
    /// Returns notes about anything macOS would not let Harbor remove.
    @discardableResult
    public static func uninstall(_ app: InstalledApp, removeData: Bool) throws -> [String] {
        let fm = FileManager.default
        var notes: [String] = []
        if app.isPresent {
            try? Shell.run(lsregister, ["-u", app.path], allowFailure: true)
            try fm.trashItem(at: app.url, resultingItemURL: nil)
        }
        if removeData {
            let folder = HarborPaths.appFolder(app.bundleID)
            if fm.fileExists(atPath: folder.path) { try fm.trashItem(at: folder, resultingItemURL: nil) }
            let container = HarborPaths.container(app.bundleID)
            if fm.fileExists(atPath: container.path) {
                do {
                    try fm.trashItem(at: container, resultingItemURL: nil)
                } catch {
                    // macOS protects a container from other apps: its folder and metadata stay,
                    // but the app's data inside can still go.
                    let items = try fm.contentsOfDirectory(at: container, includingPropertiesForKeys: nil)
                        .filter { !$0.lastPathComponent.hasPrefix(".com.apple.containermanagerd") }
                    for item in items { try fm.trashItem(at: item, resultingItemURL: nil) }
                    notes.append("macOS keeps the app's empty container folder at \(container.path)"
                                 + (items.isEmpty ? "." : "; the data inside it went to the Trash."))
                }
            }
        } else {
            // Keep settings and keymap for a later reinstall, but forget the install location.
            try? fm.removeItem(at: AppStore(bundleID: app.bundleID).installURL)
        }
        return notes
    }

    public static func launch(_ app: InstalledApp) throws {
        try Shell.run("/usr/bin/open", [app.path])
    }

    /// A warning when another app on this Mac already uses `bundleID` (an official copy, or the
    /// developer's own Mac build), since a converted app with the same id shares its container
    /// and privacy permissions. Harbor's own conversions don't count.
    public static func bundleIDClash(_ bundleID: String) -> String? {
        let registered = (LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL]) ?? []
        let fm = FileManager.default
        return bundleIDClash(bundleID, registeredApps: registered,
                             containerExists: fm.fileExists(atPath: HarborPaths.container(bundleID).appendingPathComponent("Data").path),
                             harborKnowsID: fm.fileExists(atPath: HarborPaths.appFolder(bundleID).path))
    }

    /// `harborKnowsID`: Harbor has converted an app with this id before, so an existing container is its own.
    static func bundleIDClash(_ bundleID: String, registeredApps: [URL], containerExists: Bool, harborKnowsID: Bool) -> String? {
        let others = registeredApps.filter { FileManager.default.fileExists(atPath: $0.path) && !isHarborApp(at: $0) }
        let advice = "The converted copy would share its data and permissions; choose another bundle ID (--bundle-id) to keep them apart."
        if let other = others.first {
            return "\(other.path) already uses the bundle ID \(bundleID). \(advice)"
        }
        if containerExists && !harborKnowsID {
            return "Another app has already stored data for \(bundleID) in \(HarborPaths.container(bundleID).path). \(advice)"
        }
        return nil
    }
}
