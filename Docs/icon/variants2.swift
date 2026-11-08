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

func shadowed(_ c: CGContext, blur: CGFloat, offset: CGSize, color: CGColor, _ body: () -> Void) {
    c.saveGState(); c.setShadow(offset: offset, blur: blur, color: color); c.beginTransparencyLayer(auxiliaryInfo: nil)
    body(); c.endTransparencyLayer(); c.restoreGState()
}

/// C with depth. `mesh` = soft colored blobs in the backdrop.
func depthC(name: String, top: UInt32, mid: UInt32, floorTop: UInt32, floorBottom: UInt32, mesh: CGFloat, lineCol: UInt32, refl: CGFloat = 0.42) {
    let c = canvas()
    let size: CGFloat = 380, hz: CGFloat = 572
    // 1. Backdrop: vertical gradient "wall"
    let wall = CGGradient(colorsSpace: cs, colors: [rgb(top), rgb(mid)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(wall, start: .zero, end: CGPoint(x: 0, y: hz), options: [])
    // 2. Floor: darker plane below the horizon, receding
    c.saveGState(); c.clip(to: CGRect(x: 0, y: hz, width: S, height: S - hz))
    let floor = CGGradient(colorsSpace: cs, colors: [rgb(floorTop), rgb(floorBottom)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(floor, start: CGPoint(x: 0, y: hz), end: CGPoint(x: 0, y: S), options: [])
    c.restoreGState()
    // 3. Soft colored light from the petals (subtle mesh)
    if mesh > 0 {
        for (p, col) in [(CGPoint(x: 300, y: 260), pink), (CGPoint(x: 520, y: 170), red), (CGPoint(x: 740, y: 300), yellow),
                         (CGPoint(x: 700, y: 520), green), (CGPoint(x: 320, y: 520), blue)] { blob(c, p, 360, col, mesh) }
    }
    // 4. Spotlight behind the logo + horizon haze
    blob(c, CGPoint(x: 512, y: 380), 360, 0xFFFFFF, 0.55)
    blob(c, CGPoint(x: 512, y: hz), 420, 0xFFFFFF, 0.35)
    // 5. Vignette for depth
    let vig = CGGradient(colorsSpace: cs, colors: [rgb(0x000000, 0), rgb(0x0A1430, 0.22)] as CFArray, locations: [0.55, 1])!
    c.drawRadialGradient(vig, startCenter: CGPoint(x: 512, y: 470), startRadius: 0, endCenter: CGPoint(x: 512, y: 470), endRadius: 760,
                         options: [.drawsAfterEndLocation])
    // 6. Ring with soft shadow
    shadowed(c, blur: 28, offset: CGSize(width: 0, height: -14), color: rgb(0x1B2A55, 0.28)) {
        ring(c, center: CGPoint(x: 512, y: 512), R: 400, lw: 36, arcs: [(200, 322, pink, red), (20, 142, green, blue)])
    }
    // 7. Reflection on the floor + glossy horizon line
    let r = CGRect(x: (S - size) / 2, y: hz - size - 8, width: size, height: size)
    reflection(c, CGRect(x: r.minX, y: hz + 8, width: size, height: size), startAlpha: refl, fadeLen: 280)
    _ = lineCol // horizon line removed
    // 8. Logo with contact shadow + lift
    let contact = CGGradient(colorsSpace: cs, colors: [rgb(0x0A1430, 0.25), rgb(0x0A1430, 0)] as CFArray, locations: [0, 1])!
    c.saveGState(); c.translateBy(x: 512, y: hz - 4); c.scaleBy(x: 1, y: 0.12)
    c.drawRadialGradient(contact, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 210, options: [])
    c.restoreGState()
    shadowed(c, blur: 30, offset: CGSize(width: 0, height: -12), color: rgb(0x1B2A55, 0.30)) { draw(c, logo, r) }
    imgs.append(save(c, name))
}

depthC(name: "C2.png", top: 0xFFFFFF, mid: 0xE4EAF4, floorTop: 0xD3DCEB, floorBottom: 0xB9C5DA, mesh: 0, lineCol: 0xFFFFFF)
depthC(name: "C3.png", top: 0xFBFCFF, mid: 0xE6E9F6, floorTop: 0xD6DCEE, floorBottom: 0xBCC4E0, mesh: 0.16, lineCol: 0xFFFFFF)
depthC(name: "C4.png", top: 0xEAF0FB, mid: 0xC9D6EE, floorTop: 0x9FB2D6, floorBottom: 0x6F86B8, mesh: 0.12, lineCol: 0xFFFFFF, refl: 0.7)
imgs.append(imgs[0])
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
