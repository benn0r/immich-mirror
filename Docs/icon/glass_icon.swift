import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Generates the layered Liquid Glass app icon (Icon Composer `.icon` bundle) for Photo Mirror Sync:
// a photo motif (sun + two peaks) above a water line, its reflection below, and a sync ring.
// Every shape is its own layer. Layers are flat (no glass/translucency) with only the system's
// specular edge highlight and a soft shadow — subtle rather than "glassy". Set "glass" : true per layer
// for the full Liquid Glass look.
//
//   swift Docs/icon/glass_icon.swift ImmichMirror/AppIcon.icon

let iconDir = URL(fileURLWithPath: CommandLine.arguments[1])
let assets = iconDir.appendingPathComponent("Assets")
try? FileManager.default.removeItem(at: iconDir)
try! FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

let S = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
  CGColor(
    colorSpace: cs,
    components: [
      CGFloat((h >> 16) & 255) / 255, CGFloat((h >> 8) & 255) / 255, CGFloat(h & 255) / 255, a,
    ])!
}

// Palette
let sunTop: UInt32 = 0xFFC145, sunBottom: UInt32 = 0xFF6B4A
let peakBackTop: UInt32 = 0x7B61FF, peakBackBottom: UInt32 = 0x3A86FF
let peakFrontTop: UInt32 = 0x2EC4B6, peakFrontBottom: UInt32 = 0x1E9E8F
let arrowA: (UInt32, UInt32) = (0xFFC145, 0xFF6B4A)
let arrowB: (UInt32, UInt32) = (0x2EC4B6, 0x3A86FF)

let horizon: CGFloat = 590

func layer(_ draw: (CGContext) -> Void) -> CGImage {
  let c = CGContext(
    data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  c.translateBy(x: 0, y: CGFloat(S))
  c.scaleBy(x: 1, y: -1)  // top-left origin
  draw(c)
  return c.makeImage()!
}
func save(_ img: CGImage, _ name: String) {
  let d = CGImageDestinationCreateWithURL(
    assets.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(d, img, nil)
  CGImageDestinationFinalize(d)
}
func fillGradient(_ c: CGContext, _ path: CGPath, _ top: UInt32, _ bottom: UInt32) {
  c.saveGState()
  c.addPath(path)
  c.clip()
  let box = path.boundingBox
  let g = CGGradient(colorsSpace: cs, colors: [rgb(top), rgb(bottom)] as CFArray, locations: [0, 1])!
  c.drawLinearGradient(
    g, start: CGPoint(x: box.midX, y: box.minY), end: CGPoint(x: box.midX, y: box.maxY), options: [])
  c.restoreGState()
}

/// Mountain with a rounded summit, sitting on the horizon.
func peak(left: CGFloat, apex: CGPoint, right: CGFloat, radius: CGFloat) -> CGPath {
  let p = CGMutablePath()
  p.move(to: CGPoint(x: left, y: horizon))
  p.addArc(tangent1End: apex, tangent2End: CGPoint(x: right, y: horizon), radius: radius)
  p.addLine(to: CGPoint(x: right, y: horizon))
  p.closeSubpath()
  return p
}

let sun = CGPath(ellipseIn: CGRect(x: 600, y: 250, width: 140, height: 140), transform: nil)
let back = peak(left: 270, apex: CGPoint(x: 470, y: 300), right: 670, radius: 40)
let front = peak(left: 470, apex: CGPoint(x: 625, y: 400), right: 780, radius: 34)

save(layer { fillGradient($0, sun, sunTop, sunBottom) }, "sun.png")
save(layer { fillGradient($0, back, peakBackTop, peakBackBottom) }, "peak-back.png")
save(layer { fillGradient($0, front, peakFrontTop, peakFrontBottom) }, "peak-front.png")

// Reflection: the whole scene mirrored at the horizon, fading out (one non-glass layer).
let scene = layer { c in
  fillGradient(c, sun, sunTop, sunBottom)
  fillGradient(c, back, peakBackTop, peakBackBottom)
  fillGradient(c, front, peakFrontTop, peakFrontBottom)
}
save(
  layer { c in
    let gap: CGFloat = 14
    // fade mask (device space, bottom-left origin)
    let m = CGContext(
      data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    let fade = CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceGray(),
      colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray,
      locations: [0, 1])!
    let top = CGFloat(S) - (horizon + gap)
    m.drawLinearGradient(
      fade, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: top - 230),
      options: [.drawsAfterEndLocation])
    c.saveGState()
    c.scaleBy(x: 1, y: -1)
    c.translateBy(x: 0, y: -CGFloat(S))
    c.clip(to: CGRect(x: 0, y: 0, width: S, height: S), mask: m.makeImage()!)
    // mirror: device y' = 2*(S - horizon - gap/2) - y
    c.translateBy(x: 0, y: 2 * (CGFloat(S) - horizon - gap / 2))
    c.scaleBy(x: 1, y: -1)
    c.draw(scene, in: CGRect(x: 0, y: 0, width: S, height: S))
    c.restoreGState()
  }, "reflection.png")

// Sync ring: two arrows.
let center = CGPoint(x: 512, y: 512)
let R: CGFloat = 408
let lw: CGFloat = 40
func pt(_ d: CGFloat, _ r: CGFloat) -> CGPoint {
  let t = d * .pi / 180
  return CGPoint(x: center.x + r * cos(t), y: center.y + r * sin(t))
}
func arrow(_ a0: CGFloat, _ a1: CGFloat, _ colors: (UInt32, UInt32)) -> CGImage {
  layer { c in
    let p = CGMutablePath()
    p.addArc(
      center: center, radius: R, startAngle: a0 * .pi / 180, endAngle: a1 * .pi / 180,
      clockwise: false)
    let stroke = p.copy(strokingWithWidth: lw, lineCap: .round, lineJoin: .round, miterLimit: 10)
    let head = CGMutablePath()
    head.move(to: pt(a1 + 8, R))
    head.addLine(to: pt(a1 - 3, R + lw * 1.3))
    head.addLine(to: pt(a1 - 3, R - lw * 1.3))
    head.closeSubpath()
    c.addPath(stroke)
    c.addPath(head)
    c.clip()
    let g = CGGradient(
      colorsSpace: cs, colors: [rgb(colors.0, 0.55), rgb(colors.1)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(
      g, start: pt(a0, R), end: pt(a1, R),
      options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
  }
}
save(arrow(200, 322, arrowA), "arrow-top.png")
save(arrow(20, 142, arrowB), "arrow-bottom.png")

// icon.json — groups listed front-most first.
let json = """
  {
    "fill" : {
      "automatic-gradient" : "extended-srgb:0.86000,0.90000,0.97000,1.00000"
    },
    "groups" : [
      {
        "name" : "Scene",
        "layers" : [
          { "name" : "front peak", "image-name" : "peak-front.png", "glass" : false },
          { "name" : "back peak",  "image-name" : "peak-back.png",  "glass" : false },
          { "name" : "sun",        "image-name" : "sun.png",        "glass" : false }
        ],
        "shadow" : { "kind" : "neutral", "opacity" : 0.25 },
        "translucency" : { "enabled" : false, "value" : 0 },
        "specular" : true,
        "lighting" : "individual"
      },
      {
        "name" : "Sync",
        "layers" : [
          { "name" : "top",    "image-name" : "arrow-top.png",    "glass" : false },
          { "name" : "bottom", "image-name" : "arrow-bottom.png", "glass" : false }
        ],
        "shadow" : { "kind" : "neutral", "opacity" : 0.25 },
        "translucency" : { "enabled" : false, "value" : 0 },
        "specular" : true,
        "lighting" : "individual"
      },
      {
        "name" : "Reflection",
        "layers" : [
          { "name" : "reflection", "image-name" : "reflection.png", "glass" : false, "opacity" : 0.4 }
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
