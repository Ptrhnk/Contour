// Renders the app icon to a 1024 px PNG. `make icon` turns it into
// Resources/AppIcon.icns; the .icns is committed so a normal build needs
// neither this script nor iconutil.
//
//     swift scripts/make-icon.swift out.png

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0
let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.png")

let space = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                    bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

// Apple's macOS grid: an 824 pt tile centred in 1024, leaving room for the shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0, 0, 0, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0.07, 0.08, 0.13))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()

let background = CGGradient(colorsSpace: space,
                            colors: [rgb(0.16, 0.17, 0.30), rgb(0.05, 0.06, 0.11)] as CFArray,
                            locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: tile.maxY),
                       end: CGPoint(x: 0, y: tile.minY), options: [])

// Faint EQ grid.
ctx.setStrokeColor(rgb(1, 1, 1, 0.06))
ctx.setLineWidth(3)
for i in 1..<6 {
    let y = tile.minY + tile.height * Double(i) / 6
    ctx.move(to: CGPoint(x: tile.minX, y: y)); ctx.addLine(to: CGPoint(x: tile.maxX, y: y))
    let x = tile.minX + tile.width * Double(i) / 6
    ctx.move(to: CGPoint(x: x, y: tile.minY)); ctx.addLine(to: CGPoint(x: x, y: tile.maxY))
}
ctx.strokePath()

// An EQ response: low shelf up, a dip, a presence bell, a gentle high roll-off.
func response(_ t: Double) -> Double {
    func bell(_ c: Double, _ w: Double, _ g: Double) -> Double { g * exp(-pow((t - c) / w, 2)) }
    let shelf = 0.16 / (1 + exp((t - 0.22) / 0.05))
    let rolloff = -0.14 / (1 + exp(-(t - 0.9) / 0.04))
    return shelf + bell(0.42, 0.09, -0.15) + bell(0.66, 0.08, 0.24) + rolloff
}

func curve(offset: Double) -> CGMutablePath {
    let path = CGMutablePath()
    let steps = 200
    for i in 0...steps {
        let t = Double(i) / Double(steps)
        let x = tile.minX - 20 + (tile.width + 40) * t
        let y = tile.midY - 30 + tile.height * (response(t) + offset)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    return path
}

// Contour lines: fainter echoes of the curve below the main one.
for (k, offset) in [-0.30, -0.21, -0.12].enumerated() {
    ctx.addPath(curve(offset: offset))
    ctx.setStrokeColor(rgb(0.35, 0.85, 0.95, 0.10 + 0.08 * Double(k)))
    ctx.setLineWidth(10)
    ctx.setLineCap(.round)
    ctx.strokePath()
}

// Glow under the main curve.
let main = curve(offset: 0)
let fill = main.mutableCopy()!
fill.addLine(to: CGPoint(x: tile.maxX + 20, y: tile.minY))
fill.addLine(to: CGPoint(x: tile.minX - 20, y: tile.minY))
fill.closeSubpath()
ctx.saveGState()
ctx.addPath(fill)
ctx.clip()
let glow = CGGradient(colorsSpace: space,
                      colors: [rgb(0.30, 0.80, 0.95, 0.35), rgb(0.30, 0.80, 0.95, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(glow, start: CGPoint(x: 0, y: tile.midY + 120),
                       end: CGPoint(x: 0, y: tile.minY + 60), options: [.drawsBeforeStartLocation])
ctx.restoreGState()

// Main curve, teal into amber.
ctx.saveGState()
ctx.addPath(main)
ctx.setLineWidth(30)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.replacePathWithStrokedPath()
ctx.clip()
let stroke = CGGradient(colorsSpace: space,
                        colors: [rgb(0.25, 0.88, 0.95), rgb(0.62, 0.55, 1.0), rgb(1.0, 0.68, 0.32)] as CFArray,
                        locations: [0, 0.5, 1])!
ctx.drawLinearGradient(stroke, start: CGPoint(x: tile.minX, y: 0),
                       end: CGPoint(x: tile.maxX, y: 0), options: [])
ctx.restoreGState()

ctx.restoreGState()

let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(out.path)") }
