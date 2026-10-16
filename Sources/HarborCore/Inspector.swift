import Foundation

/// A read-only compatibility check of an .ipa or .app, without converting it.
public struct InspectionReport: Sendable {
    public var name: String
    public var bundleID: String
    public var version: String
    public var deviceFamilies: [Int]
    public var platform: String
    public var minimumOS: String
    public var encrypted: Bool
    public var binaryCount: Int
    public var missingLibraries: [String]
    /// Conversion still works, but the user should know (for example, a bundle ID clash).
    public var warnings: [String]
    public var problems: [String]

    public var canConvert: Bool { problems.isEmpty }
}

public enum Inspector {
    public static func inspect(_ source: URL) throws -> InspectionReport {
        let fm = FileManager.default
        let work = HarborPaths.workRoot.appendingPathComponent("inspect-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let app: URL
        if source.pathExtension.lowercased() == "app" {
            app = source
        } else {
            try Shell.run("/usr/bin/ditto", ["-x", "-k", source.path, work.path])
            let payload = work.appendingPathComponent("Payload")
            guard let found = (try? fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "app" }) else { throw HarborError.noAppInArchive }
            app = found
        }
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")) as? [String: Any],
              let exe = info["CFBundleExecutable"] as? String else {
            throw HarborError.invalidBundle("no readable Info.plist")
        }

        var report = InspectionReport(
            name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? exe,
            bundleID: info["CFBundleIdentifier"] as? String ?? "?",
            version: info["CFBundleShortVersionString"] as? String ?? "?",
            deviceFamilies: info["UIDeviceFamily"] as? [Int] ?? [1],
            platform: "?", minimumOS: "?", encrypted: false, binaryCount: 0, missingLibraries: [], warnings: [], problems: [])
        if let clash = AppLibrary.bundleIDClash(report.bundleID) { report.warnings.append(clash) }

        var missing = Set<String>()
        let walker = fm.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  MachOBinary.isMachO(at: url) else { continue }
            let isMain = url.lastPathComponent == exe && url.deletingLastPathComponent().standardizedFileURL == app.standardizedFileURL
            do {
                let binary = try MachOBinary(contentsOf: url)
                report.binaryCount += 1
                if let id = binary.cryptID, id != 0 { report.encrypted = true }
                if isMain, let build = binary.buildVersion {
                    report.platform = "\(build.platform)"
                    report.minimumOS = build.minOS.description
                    if build.platform == .iOSSimulator { report.problems.append(MachOError.simulatorBinary(exe).description) }
                }
                for dylib in binary.linkedDylibs where !dylib.isWeak && !SystemLibraryResolver.isAvailableToCatalyst(dylib.path) {
                    missing.insert(dylib.path)
                }
            } catch {
                if isMain { report.problems.append("\(error)") }
            }
        }
        report.missingLibraries = missing.sorted()
        if report.encrypted { report.problems.append(MachOError.encrypted(exe).description) }
        return report
    }
}
