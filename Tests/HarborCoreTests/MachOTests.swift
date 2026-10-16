import XCTest
@testable import HarborCore

/// Builds small real iOS binaries with the installed toolchain and checks every patch on them.
final class MachOTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("HarborTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Compiles C source for `target` into an executable (or a dylib) and returns its path.
    private func compile(_ source: String, target: String = "arm64-apple-ios16.0", dylib: Bool = false,
                         frameworks: [String] = [], name: String = "bin") throws -> URL {
        let src = dir.appendingPathComponent("\(name).c")
        try source.write(to: src, atomically: true, encoding: .utf8)
        let out = dir.appendingPathComponent(name)
        let sdk = target.contains("ios") ? "iphoneos" : "macosx"
        var args = ["-sdk", sdk, "clang", "-target", target, "-o", out.path, src.path]
        if dylib { args += ["-dynamiclib", "-install_name", "@rpath/\(name).dylib"] }
        for framework in frameworks { args += ["-framework", framework] }
        try Shell.run("/usr/bin/xcrun", args)
        return out
    }

    func testConvertsIOSBuildVersionToCatalyst() throws {
        let url = try compile("int main(void) { return 0; }")
        var binary = try MachOBinary(contentsOf: url)
        XCTAssertEqual(binary.buildVersion?.platform, .iOS)
        XCTAssertTrue(try binary.convertToCatalyst())
        XCTAssertEqual(binary.buildVersion?.platform, .macCatalyst)
        XCTAssertEqual(binary.buildVersion?.minOS, MachOVersion(16, 0))
        XCTAssertFalse(try binary.convertToCatalyst(), "a second pass changes nothing")

        try binary.write(to: url)
        let tool = try Shell.run("/usr/bin/xcrun", ["vtool", "-show-build", url.path])
        XCTAssertTrue(tool.contains("MACCATALYST"), tool)
    }

    func testRaisesMinimumOSToCatalystFloor() throws {
        let url = try compile("int main(void) { return 0; }", target: "arm64-apple-ios12.0")
        var binary = try MachOBinary(contentsOf: url)
        try binary.convertToCatalyst(minimumOS: MachOVersion(14, 0))
        XCTAssertEqual(binary.buildVersion?.minOS, MachOVersion(14, 0))
    }

    func testReplacesVersionMinCommand() throws {
        // Re-label the build-version command as the pre-iOS 12 LC_VERSION_MIN_IPHONEOS.
        let url = try compile("int main(void) { return 0; }")
        var raw = try [UInt8](Data(contentsOf: url))
        let probe = try MachOBinary(bytes: raw, name: "probe")
        let command = try XCTUnwrap(probe.loadCommands.first { $0.cmd == LC.buildVersion })
        let minOS = MachOBinary.readU32(raw, command.offset + 12)
        let sdk = MachOBinary.readU32(raw, command.offset + 16)
        MachOBinary.writeU32(&raw, command.offset, LC.versionMinIPhoneOS)
        MachOBinary.writeU32(&raw, command.offset + 8, minOS)
        MachOBinary.writeU32(&raw, command.offset + 12, sdk)
        let countBefore = probe.loadCommands.count

        var binary = try MachOBinary(bytes: raw, name: "old")
        XCTAssertEqual(binary.buildVersion?.platform, .iOS)
        XCTAssertTrue(try binary.convertToCatalyst())
        XCTAssertEqual(binary.buildVersion?.platform, .macCatalyst)
        XCTAssertEqual(binary.loadCommands.count, countBefore)
        XCTAssertFalse(binary.loadCommands.contains { $0.cmd == LC.versionMinIPhoneOS })
    }

    func testAddDylibAppendsAfterExistingImports() throws {
        let url = try compile("#include <stdio.h>\nint main(void) { puts(\"hi\"); return 0; }",
                              frameworks: ["Foundation"])
        var binary = try MachOBinary(contentsOf: url)
        let before = binary.linkedDylibs.map(\.path)
        let slack = binary.headerSlack
        try binary.addDylib(path: HarborPaths.runtimeInstallName)
        try binary.addDylib(path: HarborPaths.runtimeInstallName) // idempotent
        XCTAssertEqual(binary.linkedDylibs.map(\.path), before + [HarborPaths.runtimeInstallName])
        XCTAssertLessThan(binary.headerSlack, slack)

        try binary.write(to: url)
        try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", url.path])
        try Shell.run("/usr/bin/codesign", ["--verify", url.path])
        let otool = try Shell.run("/usr/bin/otool", ["-L", url.path])
        XCTAssertTrue(otool.contains("libHarborRuntime.dylib"), otool)
    }

    func testWeakLinksMissingFramework() throws {
        let url = try compile("int main(void) { return 0; }", frameworks: ["Foundation"])
        var binary = try MachOBinary(contentsOf: url)
        let foundation = try XCTUnwrap(binary.linkedDylibs.first { $0.path.contains("Foundation") })
        XCTAssertFalse(foundation.isWeak)
        binary.weakLink(dylibPath: foundation.path)
        XCTAssertTrue(try XCTUnwrap(binary.linkedDylibs.first { $0.path == foundation.path }).isWeak)
    }

    func testDetectsFairPlayEncryption() throws {
        let url = try compile("int main(void) { return 0; }")
        var raw = try [UInt8](Data(contentsOf: url))
        let clean = try MachOBinary(bytes: raw, name: "clean")
        XCTAssertEqual(clean.cryptID, 0, "device executables carry an encryption command with cryptid 0")
        let command = try XCTUnwrap(clean.loadCommands.first { $0.cmd == LC.encryptionInfo64 })
        MachOBinary.writeU32(&raw, command.offset + 16, 1)
        XCTAssertEqual(try MachOBinary(bytes: raw, name: "encrypted").cryptID, 1)
    }

    func testThinsUniversalBinaryToARM64() throws {
        let arm = try compile("int f(void) { return 1; }", dylib: true, name: "arm")
        let intel = try compile("int f(void) { return 1; }", target: "x86_64-apple-macos12.0", dylib: true, name: "intel")
        let fat = dir.appendingPathComponent("fat")
        try Shell.run("/usr/bin/lipo", ["-create", arm.path, intel.path, "-output", fat.path])
        XCTAssertTrue(MachOBinary.isMachO(at: fat))
        let binary = try MachOBinary(contentsOf: fat)
        XCTAssertTrue(binary.wasThinned)
        XCTAssertEqual(binary.buildVersion?.platform, .iOS)
    }

    func testRejectsSimulatorBuilds() throws {
        let url = try compile("int main(void) { return 0; }", target: "arm64-apple-ios16.0-simulator")
        var binary = try MachOBinary(contentsOf: url)
        XCTAssertThrowsError(try binary.convertToCatalyst()) { error in
            guard case MachOError.simulatorBinary = error else { return XCTFail("\(error)") }
        }
    }

    func testIgnoresNonMachOFiles() throws {
        let text = dir.appendingPathComponent("notes.txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)
        XCTAssertFalse(MachOBinary.isMachO(at: text))
    }

    func testSystemLibraryResolver() {
        XCTAssertTrue(SystemLibraryResolver.isAvailableToCatalyst("/System/Library/Frameworks/UIKit.framework/UIKit"))
        XCTAssertTrue(SystemLibraryResolver.isAvailableToCatalyst("/usr/lib/libSystem.B.dylib"))
        XCTAssertTrue(SystemLibraryResolver.isAvailableToCatalyst("@rpath/Anything.framework/Anything"))
        XCTAssertFalse(SystemLibraryResolver.isAvailableToCatalyst("/System/Library/Frameworks/NoSuchKit.framework/NoSuchKit"))
    }
}

final class SettingsTests: XCTestCase {
    func testOldSettingsFilesStillDecode() throws {
        let json = #"{"device": {"id":"iphone-16","name":"iPhone 16","model":"iPhone","machine":"iPhone17,3","idiom":"phone","width":393,"height":852,"scale":3,"systemVersion":"27.0"}}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.device.machine, "iPhone17,3")
        XCTAssertEqual(settings.motion, .keyboard)
        XCTAssertTrue(settings.keymapping)
    }

    func testOnlyMultitaskingIPadAppsGetAFreeWindowShape() throws {
        let all = ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
                   "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]
        let multitasking: [String: Any] = ["UIDeviceFamily": [1, 2], "UISupportedInterfaceOrientations~ipad": all]
        XCTAssertTrue(AppSettings.supportsAnyWindowShape(multitasking))
        let free = AppSettings(device: .defaultPad, info: multitasking)
        XCTAssertTrue(free.resizable && free.freeAspect)

        var fullScreen = multitasking
        fullScreen["UIRequiresFullScreen"] = true
        XCTAssertFalse(AppSettings.supportsAnyWindowShape(fullScreen))
        XCTAssertFalse(AppSettings.supportsAnyWindowShape(["UIDeviceFamily": [1], "UISupportedInterfaceOrientations": all]),
                       "iPhone-only apps never had to handle arbitrary sizes")
        // Like the iOS 4 app: universal, but portrait-only and full screen.
        let portraitOnly: [String: Any] = ["UIDeviceFamily": [1, 2], "UIRequiresFullScreen": true,
                                           "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"]]
        let locked = AppSettings(device: .defaultPad, info: portraitOnly)
        XCTAssertFalse(locked.resizable || locked.freeAspect)

        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"resizable": true}"#.utf8))
        XCTAssertFalse(old.freeAspect, "settings saved before free shapes existed keep the locked aspect ratio")
    }

    func testEntitlementsFollowUsageDescriptions() {
        let plain = Entitlements.make(info: [:], bundleID: "com.example.game")
        XCTAssertEqual(plain["com.apple.security.app-sandbox"] as? Bool, true)
        XCTAssertNil(plain["com.apple.security.device.camera"])
        XCTAssertEqual(plain["com.apple.security.temporary-exception.files.home-relative-path.read-write"] as? [String],
                       ["/Library/Application Support/Harbor/Apps/com.example.game/"])

        let camera = Entitlements.make(info: ["NSCameraUsageDescription": "x", "NSLocationWhenInUseUsageDescription": "y"],
                                       bundleID: "com.example.cam")
        XCTAssertEqual(camera["com.apple.security.device.camera"] as? Bool, true)
        XCTAssertEqual(camera["com.apple.security.personal-information.location"] as? Bool, true)
    }
}
