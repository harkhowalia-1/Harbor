import Foundation

/// Sandbox entitlements for a converted app. The sandbox is what gives each app its own
/// container (~/Library/Containers/<bundle id>), i.e. the iOS-style Documents/Library/tmp.
enum Entitlements {
    static func make(info: [String: Any], bundleID: String) -> [String: Any] {
        var e: [String: Any] = [
            "com.apple.security.app-sandbox": true,
            "com.apple.security.network.client": true,
            "com.apple.security.network.server": true,
            "com.apple.security.files.user-selected.read-write": true,
            "com.apple.security.temporary-exception.files.home-relative-path.read-write":
                [HarborPaths.sandboxExceptionPath(bundleID)],
        ]
        func declares(_ keys: String...) -> Bool { keys.contains { info[$0] != nil } }
        if declares("NSCameraUsageDescription") { e["com.apple.security.device.camera"] = true }
        if declares("NSMicrophoneUsageDescription") { e["com.apple.security.device.audio-input"] = true }
        if info.keys.contains(where: { $0.hasPrefix("NSLocation") }) {
            e["com.apple.security.personal-information.location"] = true
        }
        if declares("NSPhotoLibraryUsageDescription", "NSPhotoLibraryAddUsageDescription") {
            e["com.apple.security.personal-information.photos-library"] = true
        }
        if declares("NSContactsUsageDescription") { e["com.apple.security.personal-information.addressbook"] = true }
        if declares("NSCalendarsUsageDescription", "NSCalendarsFullAccessUsageDescription", "NSRemindersUsageDescription") {
            e["com.apple.security.personal-information.calendars"] = true
        }
        if declares("NSBluetoothAlwaysUsageDescription", "NSBluetoothPeripheralUsageDescription") {
            e["com.apple.security.device.bluetooth"] = true
        }
        return e
    }
}

struct CodeSigner {
    /// "-" signs ad hoc. Any identity from `security find-identity -p codesigning` also works.
    var identity: String

    func sign(_ url: URL, entitlements: URL? = nil) throws {
        var args = ["--force", "--sign", identity, "--timestamp=none"]
        if let entitlements { args += ["--entitlements", entitlements.path] }
        args.append(url.path)
        try Shell.run("/usr/bin/codesign", args)
    }

    /// Signs nested code inside-out (dylibs and frameworks), then the app with its entitlements.
    func signApp(_ app: URL, mainExecutable: URL, machOFiles: [URL], entitlements: [String: Any], workDir: URL) throws {
        var items = Set<URL>()
        for file in machOFiles where file.standardizedFileURL != mainExecutable.standardizedFileURL {
            items.insert(Self.signingUnit(for: file, inside: app))
        }
        let ordered = items.sorted { $0.pathComponents.count > $1.pathComponents.count }
        for item in ordered { try sign(item) }

        let plist = workDir.appendingPathComponent("entitlements.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
        try data.write(to: plist)
        try sign(app, entitlements: plist)
    }

    /// A framework is signed as a bundle via its directory; anything else is signed as a loose file.
    static func signingUnit(for file: URL, inside app: URL) -> URL {
        var dir = file.deletingLastPathComponent()
        while dir.path.count > app.path.count {
            if ["framework", "appex", "bundle"].contains(dir.pathExtension),
               let info = NSDictionary(contentsOf: dir.appendingPathComponent("Info.plist")),
               let exe = info["CFBundleExecutable"] as? String,
               dir.appendingPathComponent(exe).standardizedFileURL == file.standardizedFileURL {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return file
    }
}
