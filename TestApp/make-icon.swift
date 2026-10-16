// Draws the test app's full-bleed 1024px iOS icon: usage `make-icon <out.png>`.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let gradient = CGGradient(colorsSpace: space, colors: [
    CGColor(red: 0.05, green: 0.55, blue: 0.75, alpha: 1),
    CGColor(red: 0.03, green: 0.16, blue: 0.38, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: CGFloat(size), y: 0), options: [])

// A lighthouse-beam wedge and a bold "H".
ctx.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.4, alpha: 0.35))
ctx.move(to: CGPoint(x: 512, y: 512))
ctx.addLine(to: CGPoint(x: 1024, y: 760))
ctx.addLine(to: CGPoint(x: 1024, y: 980))
ctx.closePath()
ctx.fillPath()

let font = CTFontCreateWithName("SF Pro Rounded Bold" as CFString, 560, nil)
let attributes: [NSAttributedString.Key: Any] = [
    NSAttributedString.Key(kCTFontAttributeName as String): font,
    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
]
let line = CTLineCreateWithAttributedString(NSAttributedString(string: "H", attributes: attributes))
let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
ctx.textPosition = CGPoint(x: (CGFloat(size) - bounds.width) / 2 - bounds.minX,
                           y: (CGFloat(size) - bounds.height) / 2 - bounds.minY)
CTLineDraw(line, ctx)

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
