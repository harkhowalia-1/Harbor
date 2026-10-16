// Draws Harbor's own Mac icon (a phone moored in a harbour) as an .iconset: `make-harbor-icon <dir.iconset>`.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func render(_ size: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(size) / 1024
    ctx.scaleBy(x: s, y: s)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 185.4, cornerHeight: 185.4, transform: nil)

    // Shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(squircle)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // Dusk sky.
    let sky = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.98, green: 0.62, blue: 0.40, alpha: 1),
        CGColor(red: 0.42, green: 0.36, blue: 0.70, alpha: 1),
        CGColor(red: 0.10, green: 0.16, blue: 0.40, alpha: 1),
    ] as CFArray, locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 512, y: 300), end: CGPoint(x: 512, y: 924), options: [.drawsAfterEndLocation, .drawsBeforeStartLocation])

    // Phone, standing in the water.
    let phone = CGRect(x: 372, y: 250, width: 280, height: 520)
    let phonePath = CGPath(roundedRect: phone, cornerWidth: 58, cornerHeight: 58, transform: nil)
    ctx.addPath(phonePath)
    ctx.setFillColor(CGColor(red: 0.08, green: 0.09, blue: 0.14, alpha: 1))
    ctx.fillPath()
    let screen = phone.insetBy(dx: 20, dy: 20)
    let screenPath = CGPath(roundedRect: screen, cornerWidth: 40, cornerHeight: 40, transform: nil)
    ctx.saveGState()
    ctx.addPath(screenPath)
    ctx.clip()
    let glow = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.35, green: 0.85, blue: 0.95, alpha: 1),
        CGColor(red: 0.20, green: 0.45, blue: 0.95, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(glow, start: CGPoint(x: screen.minX, y: screen.maxY), end: CGPoint(x: screen.maxX, y: screen.minY), options: [])
    ctx.restoreGState()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 472, y: 718, width: 80, height: 22), cornerWidth: 11, cornerHeight: 11, transform: nil))
    ctx.setFillColor(CGColor(red: 0.08, green: 0.09, blue: 0.14, alpha: 1))
    ctx.fillPath()

    // Water: layered waves across the lower third.
    func wave(baseline: CGFloat, amplitude: CGFloat, phase: CGFloat, color: CGColor) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: baseline))
        var x: CGFloat = 0
        while x <= 1024 {
            path.addLine(to: CGPoint(x: x, y: baseline + amplitude * sin((x / 1024) * .pi * 3 + phase)))
            x += 8
        }
        path.addLine(to: CGPoint(x: 1024, y: 0))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(color)
        ctx.fillPath()
    }
    wave(baseline: 380, amplitude: 22, phase: 0.3, color: CGColor(red: 0.16, green: 0.55, blue: 0.85, alpha: 0.85))
    wave(baseline: 320, amplitude: 26, phase: 1.6, color: CGColor(red: 0.10, green: 0.40, blue: 0.75, alpha: 0.92))
    wave(baseline: 250, amplitude: 24, phase: 2.8, color: CGColor(red: 0.05, green: 0.25, blue: 0.55, alpha: 1))
    ctx.restoreGState()

    // A soft rim so the tile reads on dark and light Docks.
    ctx.addPath(squircle)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
    ctx.setLineWidth(4)
    ctx.strokePath()
    return ctx.makeImage()!
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, render(points * scale), nil)
        CGImageDestinationFinalize(dest)
    }
}
