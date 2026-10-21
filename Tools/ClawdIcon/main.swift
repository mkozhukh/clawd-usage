import ClawdCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Renders the app icon: Clawd standing on the sand under a night sky, on the macOS
// rounded-square plate (824 px inside a 1024 px canvas). scripts/make-icon.sh turns it into AppIcon.icns.

guard CommandLine.arguments.count > 1 else { print("usage: ClawdIcon <out.png>"); exit(1) }
let size = 1024.0, plate = CGRect(x: 100, y: 100, width: 824, height: 824)
func cg(_ hex: String) -> CGColor {
    let c = RGBA(hex)
    return CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
}

let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let shape = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Plate with the soft drop shadow of the macOS icon grid.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(shape); ctx.setFillColor(cg("#FF1B2340")); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let sky = CGGradient(colorsSpace: nil, colors: [cg("#FF304A8C"), cg("#FF141A33")] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: plate.minY), end: CGPoint(x: 0, y: plate.maxY), options: [])
let ground = plate.minY + 200
ctx.setFillColor(cg("#FFB8955E")); ctx.fill(CGRect(x: plate.minX, y: plate.minY, width: plate.width, height: ground - plate.minY))
ctx.setFillColor(cg("#FF9C7A48")); ctx.fill(CGRect(x: plate.minX, y: ground - 14, width: plate.width, height: 14))
ctx.setFillColor(cg("#CCFDE68A"))
for (x, y, s) in [(230.0, 800.0, 16.0), (700.0, 840.0, 12.0), (810.0, 690.0, 16.0), (380.0, 880.0, 10.0), (170.0, 640.0, 10.0)] {
    ctx.fill(CGRect(x: x, y: y, width: s, height: s))
}

// The sprite in grid pixels (2 x 2.2 aspect, as in the widget); y grows downward, CG's upward.
let geo = ClawdSprite.geometry(ClawdFrame())
let all = geo.body + geo.eyes
let minX = all.map(\.x).min()!, maxX = all.map { $0.x + $0.w }.max()!, maxY = all.map { $0.y + $0.h }.max()!
let px = 32.0, py = px * 1.1
let left = size / 2 - (maxX + minX) / 2 * px
@MainActor func fill(_ rects: [PixelRect], _ hex: String) {
    // One path per color, so the anti-aliased edges of neighbouring rects do not leave seams.
    let path = CGMutablePath()
    for r in rects { path.addRect(CGRect(x: left + r.x * px, y: ground + (maxY - r.y - r.h) * py, width: r.w * px, height: r.h * py)) }
    ctx.addPath(path); ctx.setFillColor(cg(hex)); ctx.fillPath()
}
fill(geo.body, "#FFD77757")
fill(geo.eyes, "#FF141416")
ctx.restoreGState()

let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { print("Icon render failed"); exit(1) }
print("Icon saved: \(CommandLine.arguments[1])")
