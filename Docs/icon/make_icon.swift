import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Usage: swift make_icon.swift <immich-logo.png> <out.png>
let args = CommandLine.arguments
let logoURL = URL(fileURLWithPath: args[1]), outURL = URL(fileURLWithPath: args[2])
let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255,
                                         CGFloat(hex & 0xff) / 255, a])!
}

let src = CGImageSourceCreateWithURL(logoURL as CFURL, nil)!
let logo = CGImageSourceCreateImageAtIndex(src, 0, nil)!

let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// Work in top-left coordinates.
ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)

// Background gradient: deep indigo → teal (diagonal).
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x15127A), rgb(0x1B3FB0), rgb(0x0FB5B0)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 0), end: CGPoint(x: S, y: S), options: [])

let horizon: CGFloat = 548
let logoSize: CGFloat = 400
let logoRect = CGRect(x: (S - logoSize) / 2, y: horizon - logoSize - 14, width: logoSize, height: logoSize)

// Draws an image upright in the flipped (top-left) context.
func drawUpright(_ img: CGImage, in r: CGRect, mirrored: Bool = false) {
    ctx.saveGState()
    if mirrored {
        // reflection: mirror around the horizon → image appears upside down below the line
        ctx.translateBy(x: 0, y: r.minY); ctx.draw(img, in: CGRect(x: r.minX, y: 0, width: r.width, height: r.height))
    } else {
        ctx.translateBy(x: 0, y: r.maxY); ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: r.minX, y: 0, width: r.width, height: r.height))
    }
    ctx.restoreGState()
}

// Soft glow behind the logo.
let glow = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: logoRect.midX, y: logoRect.midY), startRadius: 0,
                       endCenter: CGPoint(x: logoRect.midX, y: logoRect.midY), endRadius: 300, options: [])

// Reflection: mirrored logo below the horizon, fading out.
let reflRect = CGRect(x: logoRect.minX, y: horizon + 14, width: logoSize, height: logoSize)
let maskCtx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
// mask in bottom-left coords: white = visible
let fade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                      colors: [CGColor(gray: 0.55, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray, locations: [0, 1])!
maskCtx.drawLinearGradient(fade, start: CGPoint(x: 0, y: S - reflRect.minY), end: CGPoint(x: 0, y: S - reflRect.minY - logoSize * 0.85),
                           options: [.drawsAfterEndLocation])
let mask = maskCtx.makeImage()!
ctx.saveGState()
ctx.clip(to: CGRect(x: 0, y: 0, width: S, height: S), mask: mask)   // mask image is drawn in user space (flipped)
ctx.restoreGState()
// Apply mask in device space to avoid flip confusion.
ctx.saveGState()
ctx.scaleBy(x: 1, y: -1); ctx.translateBy(x: 0, y: -S)               // back to bottom-left
ctx.clip(to: CGRect(x: 0, y: 0, width: S, height: S), mask: mask)
ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)               // top-left again
drawUpright(logo, in: reflRect, mirrored: true)
ctx.restoreGState()

// Water line with glow.
for (w, a) in [(26.0, 0.06), (14.0, 0.12), (7.0, 0.25), (3.0, 0.9)] as [(CGFloat, CGFloat)] {
    ctx.setStrokeColor(rgb(0xBFF6FF, a)); ctx.setLineWidth(w); ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 150, y: horizon)); ctx.addLine(to: CGPoint(x: S - 150, y: horizon)); ctx.strokePath()
}

// Logo on top.
drawUpright(logo, in: logoRect)

// Sync ring: two arcs with arrowheads (clockwise).
let c = CGPoint(x: S / 2, y: S / 2), R: CGFloat = 430, lw: CGFloat = 30
func pt(_ deg: CGFloat, _ r: CGFloat = R) -> CGPoint {   // degrees, 0 = right, clockwise (y down)
    let t = deg * .pi / 180; return CGPoint(x: c.x + r * cos(t), y: c.y + r * sin(t))
}
func arc(from a0: CGFloat, to a1: CGFloat, colors: [CGColor]) {
    ctx.saveGState()
    let path = CGMutablePath()
    path.addArc(center: c, radius: R, startAngle: a0 * .pi / 180, endAngle: a1 * .pi / 180, clockwise: false)
    let stroked = path.copy(strokingWithWidth: lw, lineCap: .round, lineJoin: .round, miterLimit: 10)
    // arrowhead at a1, pointing along clockwise tangent
    let tip = pt(a1 + 9), base = a1 - 2
    let head = CGMutablePath()
    head.move(to: tip); head.addLine(to: pt(base, R + 42)); head.addLine(to: pt(base, R - 42)); head.closeSubpath()
    ctx.addPath(stroked); ctx.addPath(head); ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: pt(a0), end: pt(a1), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}
arc(from: 196, to: 318, colors: [rgb(0xFFFFFF, 0.25), rgb(0xFFFFFF, 0.95)])
arc(from: 16, to: 138, colors: [rgb(0x9FF5FF, 0.25), rgb(0x9FF5FF, 0.95)])

let out = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, out, nil)
CGImageDestinationFinalize(dest)
print("ok")
