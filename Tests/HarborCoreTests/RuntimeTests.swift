import XCTest
@testable import HarborCore

/// Converts a small real iOS program the way Harbor converts an app, injects a freshly built
/// runtime and checks what the program sees.
final class RuntimeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("HarborRuntimeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Compiles Objective-C for iOS, patches it for Mac Catalyst (optionally loading the runtime
    /// from the same folder, as in a converted app) and returns its output.
    private func runConverted(_ source: String, name: String, frameworks: [String], runtime: Bool) throws -> String {
        let src = dir.appendingPathComponent("\(name).m")
        try source.write(to: src, atomically: true, encoding: .utf8)
        let exe = dir.appendingPathComponent(name)
        var args = ["-sdk", "iphoneos", "clang", "-target", "arm64-apple-ios17.0", "-fobjc-arc", "-o", exe.path, src.path]
        for framework in frameworks { args += ["-framework", framework] }
        try Shell.run("/usr/bin/xcrun", args)

        var binary = try MachOBinary(contentsOf: exe)
        try binary.convertToCatalyst()
        if runtime { try binary.addDylib(path: "@executable_path/\(HarborPaths.runtimeDylibName)") }
        try binary.write(to: exe)
        try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", exe.path])
        return try Shell.run(exe.path, [])
    }

    private func buildRuntime() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = dir.appendingPathComponent("Runtime")
        try Shell.run(root.appendingPathComponent("scripts/build-runtime.sh").path, [out.path])
        for name in [HarborPaths.runtimeDylibName, HarborPaths.webMediaName] {
            try FileManager.default.copyItem(at: out.appendingPathComponent(name), to: dir.appendingPathComponent(name))
        }
    }

    private static func values(_ output: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        return values
    }

    /// iPhone apps open the back camera; a Mac's cameras report as front-facing or external.
    func testBackCameraRequestGetsTheMacCamera() throws {
        let probe = """
        #import <AVFoundation/AVFoundation.h>
        int main(void) { @autoreleasepool {
            AVCaptureDevice *any = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
            AVCaptureDevice *back = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                                       mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionBack];
            AVCaptureDeviceDiscoverySession *wide = [AVCaptureDeviceDiscoverySession
                discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
                mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionBack];
            AVCaptureDeviceDiscoverySession *triple = [AVCaptureDeviceDiscoverySession
                discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInTripleCamera]
                mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionBack];
            printf("any=%s\\nback=%s\\nwide=%lu\\ntriple=%lu\\n", any.uniqueID.UTF8String ?: "none",
                   back.uniqueID.UTF8String ?: "none", (unsigned long)wide.devices.count, (unsigned long)triple.devices.count);
        }}
        """
        let plain = Self.values(try runConverted(probe, name: "plain", frameworks: ["AVFoundation", "Foundation"], runtime: false))
        XCTAssertEqual(plain["back"], "none", "a Mac has no back camera")
        guard let camera = plain["any"], camera != "none" else { throw XCTSkip("This Mac has no camera") }

        try buildRuntime()
        let output = try runConverted(probe, name: "converted", frameworks: ["AVFoundation", "Foundation"], runtime: true)
        let converted = Self.values(output)
        XCTAssertEqual(converted["back"], camera, output)
        XCTAssertNotEqual(converted["wide"], "0", output)
        XCTAssertEqual(converted["triple"], "0", "multi-lens cameras stay absent so apps take their single-camera path")
    }

    /// Catalyst's WKWebView has no navigator.mediaDevices, MediaStream or MediaRecorder; the app's own
    /// web views get them. Records a canvas, which needs no camera access, through the native encoder.
    func testAppWebViewsGetMediaCaptureAndRecording() throws {
        let probe = """
        #import <WebKit/WebKit.h>
        int main(void) { @autoreleasepool {
            WKWebView *web = [[WKWebView alloc] initWithFrame:CGRectMake(0, 0, 100, 100) configuration:[WKWebViewConfiguration new]];
            [web loadHTMLString:@"<p>probe</p>" baseURL:[NSURL URLWithString:@"https://localhost/"]];
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30];
            while ((web.loading || !web.URL.host) && deadline.timeIntervalSinceNow > 0) // not the initial about:blank
                [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            __block BOOL done = NO;
            NSString *script = @"const md = navigator.mediaDevices; let devices = 'none';"
                "if (md && md.enumerateDevices) devices = String(Array.isArray(await md.enumerateDevices()));"
                "const v = document.createElement('video'); let attached = 'no';"
                "if (window.MediaStream) { const s = new MediaStream([]); v.srcObject = s; attached = String(v.srcObject === s); }"
                "let recorded = 'none';"
                "if (window.MediaRecorder && HTMLCanvasElement.prototype.captureStream) {"
                "  const c = document.createElement('canvas'); c.width = 64; c.height = 48; const g = c.getContext('2d'); let n = 0;"
                "  const paint = setInterval(() => { g.fillStyle = `hsl(${n++ * 20}, 80%, 50%)`; g.fillRect(0, 0, 64, 48); }, 30);"
                "  const r = new MediaRecorder(c.captureStream(30)), chunks = [];"
                "  r.ondataavailable = e => chunks.push(e.data);"
                "  const stopped = new Promise(res => { r.onstop = res; });"
                "  r.start(); await new Promise(res => setTimeout(res, 1500)); r.stop(); await stopped; clearInterval(paint);"
                "  const blob = new Blob(chunks, { type: r.mimeType }), bytes = new Uint8Array(await blob.arrayBuffer());"
                "  recorded = `${r.mimeType}:${String.fromCharCode(...bytes.slice(4, 8))}:${blob.size > 1000}`;"
                "}"
                "return [`gum=${typeof (md && md.getUserMedia)}`, `stream=${typeof MediaStream}`, `devices=${devices}`, `srcObject=${attached}`,"
                "  `mp4=${window.MediaRecorder && MediaRecorder.isTypeSupported('video/mp4')}`,"
                "  `webm=${window.MediaRecorder && MediaRecorder.isTypeSupported('video/webm')}`,"
                "  `destination=${typeof AudioContext.prototype.createMediaStreamDestination}`, `recorded=${recorded}`].join('\\\\n');";
            [web callAsyncJavaScript:script arguments:@{} inFrame:nil inContentWorld:WKContentWorld.pageWorld
                   completionHandler:^(id result, NSError *error) {
                printf("%s\\n", [result description].UTF8String ?: error.description.UTF8String);
                done = YES;
            }];
            while (!done && deadline.timeIntervalSinceNow > 0)
                [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }}
        """
        let frameworks = ["WebKit", "UIKit", "Foundation"]
        let plain = Self.values(try runConverted(probe, name: "plainweb", frameworks: frameworks, runtime: false))
        XCTAssertEqual(plain["gum"], "undefined", "Catalyst web views have no getUserMedia of their own")

        try buildRuntime()
        let output = try runConverted(probe, name: "convertedweb", frameworks: frameworks, runtime: true)
        let converted = Self.values(output)
        XCTAssertEqual(converted["gum"], "function", output)
        XCTAssertEqual(converted["stream"], "function", output)
        XCTAssertEqual(converted["devices"], "true", output)
        XCTAssertEqual(converted["srcObject"], "true", output)
        XCTAssertEqual(converted["mp4"], "true", output)
        XCTAssertEqual(converted["webm"], "false", output)
        XCTAssertEqual(converted["destination"], "function", output)
        XCTAssertEqual(converted["recorded"], "video/mp4:ftyp:true", "a playable MP4 came back from the native encoder\n\(output)")
    }
}

final class LibraryTests: XCTestCase {
    func testWarnsWhenAnotherAppUsesTheBundleID() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HarborLibraryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        func app(_ name: String, info: [String: Any]) throws -> URL {
            let url = dir.appendingPathComponent("\(name).app")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: url.appendingPathComponent("Info.plist"))
            return url
        }
        let official = try app("Official", info: ["CFBundleIdentifier": "com.example.cam"])
        let converted = try app("Converted", info: ["CFBundleIdentifier": "com.example.cam", "HarborConverted": ["harborVersion": "1.0"]])
        let gone = dir.appendingPathComponent("Deleted.app")
        let id = "com.example.cam"

        XCTAssertNil(AppLibrary.bundleIDClash(id, registeredApps: [], containerExists: false, harborKnowsID: false))
        XCTAssertNil(AppLibrary.bundleIDClash(id, registeredApps: [converted, gone], containerExists: true, harborKnowsID: true),
                     "Harbor's own copy and stale registrations don't count")
        let other = try XCTUnwrap(AppLibrary.bundleIDClash(id, registeredApps: [converted, official], containerExists: false, harborKnowsID: true))
        XCTAssertTrue(other.contains(official.path), other)
        let leftover = try XCTUnwrap(AppLibrary.bundleIDClash(id, registeredApps: [], containerExists: true, harborKnowsID: false))
        XCTAssertTrue(leftover.contains("Library/Containers/\(id)"), leftover)
    }
}
