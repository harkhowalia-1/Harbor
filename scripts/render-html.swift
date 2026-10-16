// Renders an HTML or SVG file to a PNG with WebKit, for Harbor's graphics (scripts/make-graphics.sh).
//
//     render-html <input.html|svg> <output.png> <width> <height> [scale]
//
// The page may load files relative to itself (the app icon, for example).
import AppKit
import WebKit

let arguments = CommandLine.arguments
guard arguments.count >= 5, let width = Double(arguments[3]), let height = Double(arguments[4]) else {
    FileHandle.standardError.write(Data("usage: render-html <input> <output.png> <width> <height> [scale]\n".utf8))
    exit(2)
}
let scale = arguments.count > 5 ? Double(arguments[5]) ?? 1 : 1
let input = URL(fileURLWithPath: arguments[1]).standardizedFileURL
let output = URL(fileURLWithPath: arguments[2])

final class Renderer: NSObject, WKNavigationDelegate {
    let view: WKWebView
    let width: Double, height: Double, scale: Double, output: URL
    init(width: Double, height: Double, scale: Double, output: URL) {
        self.width = width
        self.height = height
        self.scale = scale
        self.output = output
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        super.init()
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Let images and web fonts settle.
        let width = self.width, height = self.height, scale = self.scale, output = self.output
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let configuration = WKSnapshotConfiguration()
            configuration.rect = webView.bounds
            configuration.snapshotWidth = NSNumber(value: Double(webView.bounds.width) * scale / (NSScreen.main?.backingScaleFactor ?? 2))
            webView.takeSnapshot(with: configuration) { image, error in
                guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
                    FileHandle.standardError.write(Data("snapshot failed: \(String(describing: error))\n".utf8))
                    exit(1)
                }
                // Exactly width*scale x height*scale pixels.
                let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: pixels)
                bitmap.draw(in: NSRect(x: 0, y: 0, width: width * scale, height: height * scale))
                NSGraphicsContext.restoreGraphicsState()
                try! pixels.representation(using: .png, properties: [:])!.write(to: output)
                exit(0)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        FileHandle.standardError.write(Data("load failed: \(error)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
let renderer = Renderer(width: width, height: height, scale: scale, output: output)
renderer.view.loadFileURL(input, allowingReadAccessTo: input.deletingLastPathComponent().deletingLastPathComponent())
app.run()
