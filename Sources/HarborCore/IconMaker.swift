import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Builds a Mac-style .icns (inset rounded square with a shadow) from an iOS app's full-bleed icon.
enum IconMaker {
    /// Finds the largest icon the iOS bundle ships, from loose PNGs or its asset catalog.
    static func sourceIcon(in bundle: URL, info: [String: Any]) -> CGImage? {
        var names = Set<String>()
        var catalogName: String?
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            guard let icons = info[key] as? [String: Any],
                  let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] else { continue }
            (primary["CFBundleIconFiles"] as? [String])?.forEach { names.insert($0) }
            catalogName = catalogName ?? primary["CFBundleIconName"] as? String
        }
        (info["CFBundleIconFiles"] as? [String])?.forEach { names.insert($0) }
        if let file = info["CFBundleIconFile"] as? String { names.insert((file as NSString).deletingPathExtension) }
        catalogName = catalogName ?? info["CFBundleIconName"] as? String

        var best: CGImage?
        let files = (try? FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension.lowercased() == "png" {
            let base = file.deletingPathExtension().lastPathComponent
            let named = names.contains { base.hasPrefix($0) }
            guard named || (names.isEmpty && base.lowercased().hasPrefix("appicon")) else { continue }
            if let image = loadImage(file), image.width > (best?.width ?? 0) { best = image }
        }

        if (best?.width ?? 0) < 512 {
            let car = bundle.appendingPathComponent("Assets.car")
            if FileManager.default.fileExists(atPath: car.path),
               let image = AssetCatalogReader.largestImage(named: catalogName ?? "AppIcon", in: car),
               image.width > (best?.width ?? 0) {
                best = image
            }
        }
        return best
    }

    static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Draws the iOS artwork into Apple's macOS icon grid: an 824pt rounded square centred in 1024.
    static func macIcon(from source: CGImage, size: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let s = CGFloat(size) / 1024
        let rect = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let path = CGPath(roundedRect: rect, cornerWidth: 185.4 * s, cornerHeight: 185.4 * s, transform: nil)
        ctx.interpolationQuality = .high

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: CGColor(gray: 0, alpha: 0.3))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(source, in: rect)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Writes `<name>.icns` into `directory`. Returns false if the bundle has no usable icon.
    static func makeICNS(for bundle: URL, info: [String: Any], into directory: URL, name: String, workDir: URL) throws -> Bool {
        guard let source = sourceIcon(in: bundle, info: info) else { return false }
        let iconset = workDir.appendingPathComponent("\(name).iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: iconset) }
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                guard let image = macIcon(from: source, size: points * scale) else { return false }
                let suffix = scale == 2 ? "@2x" : ""
                try writePNG(image, to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
            }
        }
        let output = directory.appendingPathComponent("\(name).icns")
        try Shell.run("/usr/bin/iconutil", ["-c", "icns", "-o", output.path, iconset.path])
        return true
    }
}

/// Reads images out of a compiled asset catalog using CoreUI, the private framework behind Assets.car.
/// Every call is guarded: if CoreUI changes shape, icon extraction just falls back to nothing.
enum AssetCatalogReader {
    private typealias InitWithURL = @convention(c) (AnyObject, Selector, NSURL, UnsafeMutablePointer<NSError?>?) -> AnyObject?
    private typealias ImagesWithName = @convention(c) (AnyObject, Selector, NSString) -> NSArray?
    private typealias ImageGetter = @convention(c) (AnyObject, Selector) -> Unmanaged<CGImage>?

    static func largestImage(named name: String, in car: URL) -> CGImage? {
        guard dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_NOW) != nil,
              let cls = NSClassFromString("CUICatalog") as? NSObject.Type else { return nil }

        let initSel = NSSelectorFromString("initWithURL:error:")
        let imagesSel = NSSelectorFromString("imagesWithName:")
        let imageSel = NSSelectorFromString("image")
        guard cls.instancesRespond(to: initSel), cls.instancesRespond(to: imagesSel),
              let allocated = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeRetainedValue() as? NSObject
        else { return nil }
        let initIMP = unsafeBitCast(allocated.method(for: initSel), to: InitWithURL.self)
        var error: NSError?
        guard let catalog = initIMP(allocated, initSel, car as NSURL, &error) as? NSObject else { return nil }

        // Every rendition with this name: per-size icon images plus a multisize set (skipped).
        let images = unsafeBitCast(catalog.method(for: imagesSel), to: ImagesWithName.self)
        var best: CGImage?
        for case let named as NSObject in images(catalog, imagesSel, name as NSString) ?? [] {
            guard named.responds(to: imageSel) else { continue }
            let getter = unsafeBitCast(named.method(for: imageSel), to: ImageGetter.self)
            if let image = getter(named, imageSel)?.takeUnretainedValue(), image.width > (best?.width ?? 0) {
                best = image
            }
        }
        return best
    }
}
