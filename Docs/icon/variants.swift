import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// swift variants.swift <logo.png> <outdir>   → writes A.png … D.png and sheet.png
let args = CommandLine.arguments
let logo = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil)!, 0, nil)!
let outDir = URL(fileURLWithPath: args[2])
let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((h >> 16) & 255) / 255, CGFloat((h >> 8) & 255) / 255, CGFloat(h & 255) / 255, a])!
}
// Immich petal colors
let red = 0xFA2921 as UInt32, yellow = 0xFFB400 as UInt32, green = 0x18C249 as UInt32, blue = 0x1E83F7 as UInt32, pink = 0xED79B5 as UInt32

func canvas() -> CGContext {
    let c = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    c.translateBy(x: 0, y: S); c.scaleBy(x: 1, y: -1)   // top-left origin
    return c
}
func draw(_ c: CGContext, _ img: CGImage, _ r: CGRect, flipped: Bool = false, alpha: CGFloat = 1) {
    c.saveGState(); c.setAlpha(alpha)
    if flipped { c.translateBy(x: 0, y: r.minY) } else { c.translateBy(x: 0, y: r.maxY); c.scaleBy(x: 1, y: -1) }
    c.draw(img, in: CGRect(x: r.minX, y: 0, width: r.width, height: r.height))
    c.restoreGState()
}
/// Mirrored logo below `top`, fading from `startAlpha` to 0 over `fadeLen`.
func reflection(_ c: CGContext, _ r: CGRect, startAlpha: CGFloat, fadeLen: CGFloat) {
    let m = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                       colors: [CGColor(gray: startAlpha, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray, locations: [0, 1])!
    m.drawLinearGradient(g, start: CGPoint(x: 0, y: S - r.minY), end: CGPoint(x: 0, y: S - r.minY - fadeLen), options: [.drawsAfterEndLocation])
    let mask = m.makeImage()!
    c.saveGState()
    c.scaleBy(x: 1, y: -1); c.translateBy(x: 0, y: -S)
    c.clip(to: CGRect(x: 0, y: 0, width: S, height: S), mask: mask)
    c.translateBy(x: 0, y: S); c.scaleBy(x: 1, y: -1)
    draw(c, logo, r, flipped: true)
    c.restoreGState()
}
func line(_ c: CGContext, y: CGFloat, x0: CGFloat, x1: CGFloat, color: UInt32, layers: [(CGFloat, CGFloat)]) {
    for (w, a) in layers {
        c.setStrokeColor(rgb(color, a)); c.setLineWidth(w); c.setLineCap(.round)
        c.move(to: CGPoint(x: x0, y: y)); c.addLine(to: CGPoint(x: x1, y: y)); c.strokePath()
    }
}
func blob(_ c: CGContext, _ p: CGPoint, _ r: CGFloat, _ col: UInt32, _ a: CGFloat) {
    let g = CGGradient(colorsSpace: cs, colors: [rgb(col, a), rgb(col, 0)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: r, options: [])
}
/// Sync arrows as two arcs, gradient-stroked.
func ring(_ c: CGContext, center: CGPoint, R: CGFloat, lw: CGFloat, arcs: [(CGFloat, CGFloat, UInt32, UInt32)], alpha: CGFloat = 1) {
    func pt(_ d: CGFloat, _ r: CGFloat) -> CGPoint { let t = d * .pi / 180; return CGPoint(x: center.x + r * cos(t), y: center.y + r * sin(t)) }
    for (a0, a1, c0, c1) in arcs {
        c.saveGState()
        let p = CGMutablePath(); p.addArc(center: center, radius: R, startAngle: a0 * .pi / 180, endAngle: a1 * .pi / 180, clockwise: false)
        let s = p.copy(strokingWithWidth: lw, lineCap: .round, lineJoin: .round, miterLimit: 10)
        let h = CGMutablePath(); h.move(to: pt(a1 + 8, R)); h.addLine(to: pt(a1 - 3, R + lw * 1.35)); h.addLine(to: pt(a1 - 3, R - lw * 1.35)); h.closeSubpath()
        c.addPath(s); c.addPath(h); c.clip()
        let g = CGGradient(colorsSpace: cs, colors: [rgb(c0, alpha * 0.35), rgb(c1, alpha)] as CFArray, locations: [0, 1])!
        c.drawLinearGradient(g, start: pt(a0, R), end: pt(a1, R), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        c.restoreGState()
    }
}
func save(_ c: CGContext, _ name: String) -> CGImage {
    let img = c.makeImage()!
    let d = CGImageDestinationCreateWithURL(outDir.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
    return img
}

var imgs: [CGImage] = []

// A — "Clean": Apple-like white, big logo, soft reflection on a hairline. No arrows.
do {
    let c = canvas()
    let bg = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF), rgb(0xE8EDF5)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(bg, start: .zero, end: CGPoint(x: 0, y: S), options: [])
    let size: CGFloat = 470, hz: CGFloat = 600
    let r = CGRect(x: (S - size) / 2, y: hz - size - 10, width: size, height: size)
    reflection(c, CGRect(x: r.minX, y: hz + 10, width: size, height: size), startAlpha: 0.38, fadeLen: 300)
    line(c, y: hz, x0: 190, x1: S - 190, color: 0xB8C2D3, layers: [(4, 1)])
    draw(c, logo, r)
    imgs.append(save(c, "A.png"))
}

// B — "Night lake": dark navy, colorful aurora glow from the petals, reflection on water.
do {
    let c = canvas()
    let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x0B1026), rgb(0x141B3D), rgb(0x0A0F22)] as CFArray, locations: [0, 0.6, 1])!
    c.drawLinearGradient(bg, start: .zero, end: CGPoint(x: 0, y: S), options: [])
    let size: CGFloat = 450, hz: CGFloat = 590
    let r = CGRect(x: (S - size) / 2, y: hz - size - 10, width: size, height: size)
    for (p, col) in [(CGPoint(x: 512, y: 200), red), (CGPoint(x: 700, y: 330), yellow), (CGPoint(x: 640, y: 520), green),
                     (CGPoint(x: 380, y: 520), blue), (CGPoint(x: 320, y: 300), pink)] { blob(c, p, 330, col, 0.30) }
    reflection(c, CGRect(x: r.minX, y: hz + 10, width: size, height: size), startAlpha: 0.5, fadeLen: 330)
    line(c, y: hz, x0: 160, x1: S - 160, color: 0xCFE9FF, layers: [(24, 0.05), (10, 0.15), (3, 0.85)])
    draw(c, logo, r)
    imgs.append(save(c, "B.png"))
}

// C — "Sync ring": white background, thin Immich-colored sync arrows around the mirrored logo.
do {
    let c = canvas()
    let bg = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF), rgb(0xEEF2F8)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(bg, start: .zero, end: CGPoint(x: 0, y: S), options: [])
    let size: CGFloat = 380, hz: CGFloat = 560
    let r = CGRect(x: (S - size) / 2, y: hz - size - 8, width: size, height: size)
    ring(c, center: CGPoint(x: 512, y: 512), R: 400, lw: 34,
         arcs: [(200, 322, pink, red), (20, 142, green, blue)])
    reflection(c, CGRect(x: r.minX, y: hz + 8, width: size, height: size), startAlpha: 0.35, fadeLen: 250)
    line(c, y: hz, x0: 250, x1: S - 250, color: 0xB8C2D3, layers: [(4, 1)])
    draw(c, logo, r)
    imgs.append(save(c, "C.png"))
}

// D — "Mirror split": logo whole on top half (white), mirrored in a deep-blue "server" half.
do {
    let c = canvas()
    let hz: CGFloat = 540
    c.setFillColor(rgb(0xFFFFFF)); c.fill(CGRect(x: 0, y: 0, width: S, height: hz))
    let low = CGGradient(colorsSpace: cs, colors: [rgb(0x1A2A6C), rgb(0x0D1640)] as CFArray, locations: [0, 1])!
    c.saveGState(); c.clip(to: CGRect(x: 0, y: hz, width: S, height: S - hz))
    c.drawLinearGradient(low, start: CGPoint(x: 0, y: hz), end: CGPoint(x: 0, y: S), options: [])
    c.restoreGState()
    let size: CGFloat = 400
    let r = CGRect(x: (S - size) / 2, y: hz - size - 12, width: size, height: size)
    reflection(c, CGRect(x: r.minX, y: hz + 12, width: size, height: size), startAlpha: 0.9, fadeLen: 420)
    draw(c, logo, r)
    imgs.append(save(c, "D.png"))
}

// Contact sheet with rounded masks + labels-free (2x2, each 480px)
let cell: CGFloat = 480, pad: CGFloat = 40
let W = cell * 2 + pad * 3
let sheet = CGContext(data: nil, width: Int(W), height: Int(W), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
sheet.setFillColor(rgb(0x8A8F98)); sheet.fill(CGRect(x: 0, y: 0, width: W, height: W))
for (i, img) in imgs.enumerated() {
    let col = CGFloat(i % 2), row = CGFloat(1 - i / 2)     // A,B top row
    let rect = CGRect(x: pad + col * (cell + pad), y: pad + row * (cell + pad), width: cell, height: cell)
    sheet.saveGState()
    sheet.addPath(CGPath(roundedRect: rect, cornerWidth: cell * 0.225, cornerHeight: cell * 0.225, transform: nil)); sheet.clip()
    sheet.draw(img, in: rect)
    sheet.restoreGState()
}
_ = save(sheet, "sheet.png")
print("ok")
