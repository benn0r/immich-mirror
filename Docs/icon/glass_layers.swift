import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// swift glass_layers.swift <logo.png> <AppIcon.icon dir>
let args = CommandLine.arguments
let logo = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil)!, 0, nil)!
let iconDir = URL(fileURLWithPath: args[2])
let assets = iconDir.appendingPathComponent("Assets")
try? FileManager.default.removeItem(at: iconDir)
try! FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

let S = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((h >> 16) & 255) / 255, CGFloat((h >> 8) & 255) / 255, CGFloat(h & 255) / 255, a])!
}
func layerCtx() -> CGContext {
    let c = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: S * 4, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.translateBy(x: 0, y: CGFloat(S)); c.scaleBy(x: 1, y: -1)
    return c
}
func save(_ img: CGImage, _ name: String) {
    let d = CGImageDestinationCreateWithURL(assets.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
}

// Layout
let logoSize: CGFloat = 470
let logoRect = CGRect(x: (CGFloat(S) - logoSize) / 2, y: 512 - logoSize / 2 - 20, width: logoSize, height: logoSize)

// 1. Render logo once at final size/position.
let base = layerCtx()
base.saveGState(); base.translateBy(x: 0, y: logoRect.maxY); base.scaleBy(x: 1, y: -1)
base.draw(logo, in: CGRect(x: logoRect.minX, y: 0, width: logoSize, height: logoSize)); base.restoreGState()
let px = base.data!.bindMemory(to: UInt8.self, capacity: S * S * 4)

// 2. Split petals by nearest Immich color (alpha kept → antialiased edges survive).
let petals: [(String, (Double, Double, Double))] = [
    ("petal-red", (250, 41, 33)), ("petal-yellow", (255, 180, 0)), ("petal-green", (24, 194, 73)),
    ("petal-blue", (30, 131, 247)), ("petal-pink", (237, 121, 181)),
]
var buffers = petals.map { _ in [UInt8](repeating: 0, count: S * S * 4) }
for i in stride(from: 0, to: S * S * 4, by: 4) {
    let a = Double(px[i + 3]); if a < 1 { continue }
    let r = Double(px[i]) * 255 / a, g = Double(px[i + 1]) * 255 / a, b = Double(px[i + 2]) * 255 / a
    var best = 0, bestD = Double.infinity
    for (k, (_, c)) in petals.enumerated() {
        let d = (r - c.0) * (r - c.0) + (g - c.1) * (g - c.1) + (b - c.2) * (b - c.2)
        if d < bestD { bestD = d; best = k }
    }
    for j in 0..<4 { buffers[best][i + j] = px[i + j] }
}
for (k, (name, _)) in petals.enumerated() {
    let img = buffers[k].withUnsafeMutableBytes { p -> CGImage in
        CGContext(data: p.baseAddress, width: S, height: S, bitsPerComponent: 8, bytesPerRow: S * 4, space: cs,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }
    save(img, name + ".png")
}

// 3. Sync arrows (each its own layer), solid colors — glass adds the shading.
let center = CGPoint(x: 512, y: 512), R: CGFloat = 405, lw: CGFloat = 40
func pt(_ d: CGFloat, _ r: CGFloat) -> CGPoint { let t = d * .pi / 180; return CGPoint(x: center.x + r * cos(t), y: center.y + r * sin(t)) }
func arrow(_ name: String, _ a0: CGFloat, _ a1: CGFloat, _ c0: UInt32, _ c1: UInt32) {
    let c = layerCtx()
    let p = CGMutablePath(); p.addArc(center: center, radius: R, startAngle: a0 * .pi / 180, endAngle: a1 * .pi / 180, clockwise: false)
    let s = p.copy(strokingWithWidth: lw, lineCap: .round, lineJoin: .round, miterLimit: 10)
    let h = CGMutablePath(); h.move(to: pt(a1 + 8, R)); h.addLine(to: pt(a1 - 3, R + lw * 1.3)); h.addLine(to: pt(a1 - 3, R - lw * 1.3)); h.closeSubpath()
    c.addPath(s); c.addPath(h); c.clip()
    let g = CGGradient(colorsSpace: cs, colors: [rgb(c0, 0.55), rgb(c1, 1)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(g, start: pt(a0, R), end: pt(a1, R), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    save(c.makeImage()!, name + ".png")
}
arrow("arrow-top", 200, 322, 0xED79B5, 0xFA2921)
arrow("arrow-bottom", 20, 142, 0x18C249, 0x1E83F7)

// 4. Reflection: mirrored logo under its own bottom edge, fading (non-glass, low opacity).
do {
    let c = layerCtx()
    let hz = logoRect.maxY + 6
    let m = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray, locations: [0, 1])!
    m.drawLinearGradient(g, start: CGPoint(x: 0, y: CGFloat(S) - hz), end: CGPoint(x: 0, y: CGFloat(S) - hz - 190), options: [.drawsAfterEndLocation])
    let mask = m.makeImage()!
    c.saveGState(); c.scaleBy(x: 1, y: -1); c.translateBy(x: 0, y: -CGFloat(S))
    c.clip(to: CGRect(x: 0, y: 0, width: S, height: S), mask: mask)
    c.translateBy(x: 0, y: CGFloat(S)); c.scaleBy(x: 1, y: -1)
    c.translateBy(x: 0, y: hz)
    c.draw(logo, in: CGRect(x: logoRect.minX, y: 0, width: logoSize, height: logoSize))
    c.restoreGState()
    save(c.makeImage()!, "reflection.png")
}

// 5. icon.json — groups listed front-most first.
let json = """
{
  "fill" : {
    "automatic-gradient" : "extended-srgb:0.80000,0.85000,0.94000,1.00000"
  },
  "groups" : [
    {
      "name" : "Logo",
      "layers" : [
        { "name" : "red",    "image-name" : "petal-red.png",    "glass" : true },
        { "name" : "yellow", "image-name" : "petal-yellow.png", "glass" : true },
        { "name" : "green",  "image-name" : "petal-green.png",  "glass" : true },
        { "name" : "blue",   "image-name" : "petal-blue.png",   "glass" : true },
        { "name" : "pink",   "image-name" : "petal-pink.png",   "glass" : true }
      ],
      "shadow" : { "kind" : "layer-color", "opacity" : 0.5 },
      "translucency" : { "enabled" : true, "value" : 0.3 },
      "specular" : true,
      "lighting" : "individual"
    },
    {
      "name" : "Sync",
      "layers" : [
        { "name" : "top",    "image-name" : "arrow-top.png",    "glass" : true },
        { "name" : "bottom", "image-name" : "arrow-bottom.png", "glass" : true }
      ],
      "shadow" : { "kind" : "neutral", "opacity" : 0.4 },
      "translucency" : { "enabled" : true, "value" : 0.4 },
      "specular" : true,
      "lighting" : "individual"
    },
    {
      "name" : "Reflection",
      "layers" : [
        { "name" : "reflection", "image-name" : "reflection.png", "glass" : false, "opacity" : 0.35 }
      ],
      "shadow" : { "kind" : "none", "opacity" : 0 },
      "specular" : false
    }
  ],
  "supported-platforms" : {
    "squares" : "shared"
  }
}
"""
try! json.write(to: iconDir.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
print("ok")
