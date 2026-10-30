// Renders the Video Upscaler app icon and writes an .icns file.
// Usage: swift Tools/MakeIcon.swift <output.icns> [preview.png]
//
// Follows the macOS icon grid: a 1024×1024 canvas holding an 824×824 continuous-corner
// rounded square, with a transparent margin around it so the icon has the standard macOS shape.

import AppKit
import CoreGraphics
import SwiftUI

let canvas: CGFloat = 1024
let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tileRadius: CGFloat = 185.4

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

func continuousRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

func makeContext(_ width: Int, _ height: Int) -> CGContext {
    CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

/// The little landscape shown inside the film frame: sky, sun and mountains.
func drawScene(in ctx: CGContext, size: CGSize) {
    let w = size.width, h = size.height
    ctx.drawLinearGradient(
        gradient([color(0x2E1A6E), color(0x8B3FD9), color(0xFF6FA3), color(0xFFB36B)], [0, 0.45, 0.8, 1]),
        start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: h * 0.25), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    // Sun
    ctx.saveGState()
    let sun = CGRect(x: w * 0.56, y: h * 0.38, width: w * 0.24, height: w * 0.24)
    ctx.addEllipse(in: sun)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([color(0xFFF3B0), color(0xFFC46B)]),
        start: CGPoint(x: sun.midX, y: sun.maxY), end: CGPoint(x: sun.midX, y: sun.minY), options: []
    )
    ctx.restoreGState()
    // Far mountains
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 0, y: h * 0.42))
    ctx.addLine(to: CGPoint(x: w * 0.22, y: h * 0.62))
    ctx.addLine(to: CGPoint(x: w * 0.42, y: h * 0.44))
    ctx.addLine(to: CGPoint(x: w * 0.62, y: h * 0.58))
    ctx.addLine(to: CGPoint(x: w * 0.86, y: h * 0.4))
    ctx.addLine(to: CGPoint(x: w, y: h * 0.48))
    ctx.addLine(to: CGPoint(x: w, y: 0))
    ctx.addLine(to: CGPoint(x: 0, y: 0))
    ctx.closePath()
    ctx.setFillColor(color(0x5B2A9E))
    ctx.fillPath()
    // Near mountains
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 0, y: h * 0.2))
    ctx.addLine(to: CGPoint(x: w * 0.3, y: h * 0.42))
    ctx.addLine(to: CGPoint(x: w * 0.5, y: h * 0.28))
    ctx.addLine(to: CGPoint(x: w * 0.72, y: h * 0.38))
    ctx.addLine(to: CGPoint(x: w, y: h * 0.16))
    ctx.addLine(to: CGPoint(x: w, y: 0))
    ctx.addLine(to: CGPoint(x: 0, y: 0))
    ctx.closePath()
    ctx.setFillColor(color(0x2A1556))
    ctx.fillPath()
}

/// A four-pointed sparkle centred on `c`.
func sparkle(center c: CGPoint, radius r: CGFloat, waist: CGFloat = 0.22) -> CGPath {
    let p = CGMutablePath()
    let k = r * waist
    p.move(to: CGPoint(x: c.x, y: c.y + r))
    p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + k, y: c.y + k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + k, y: c.y - k))
    p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - k, y: c.y - k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - k, y: c.y + k))
    p.closeSubpath()
    return p
}

func renderMaster() -> CGImage {
    let ctx = makeContext(Int(canvas), Int(canvas))
    let tile = continuousRect(tileRect, radius: tileRadius)

    // Soft drop shadow, kept inside the canvas.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(tile)
    ctx.setFillColor(color(0x241A5C))
    ctx.fillPath()
    ctx.restoreGState()

    // Tile background.
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([color(0x7B6CFF), color(0x4B3BD6), color(0x1F1660)], [0, 0.5, 1]),
        start: CGPoint(x: 0, y: tileRect.maxY), end: CGPoint(x: 0, y: tileRect.minY), options: []
    )
    ctx.drawRadialGradient(
        gradient([color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)]),
        startCenter: CGPoint(x: 512, y: 900), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 900), endRadius: 560, options: []
    )

    // Film frame.
    let frame = CGRect(x: 200, y: 262, width: 624, height: 470)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x0B0630, 0.55))
    ctx.addPath(continuousRect(frame, radius: 54))
    ctx.setFillColor(color(0x15102E))
    ctx.fillPath()
    ctx.restoreGState()

    // Sprocket holes.
    ctx.setFillColor(color(0xFFFFFF, 0.9))
    let holeW: CGFloat = 38, holeH: CGFloat = 26
    for i in 0..<8 {
        let x = frame.minX + 50 + CGFloat(i) * ((frame.width - 100 - holeW) / 7)
        for y in [frame.maxY - 22 - holeH, frame.minY + 22] {
            ctx.addPath(continuousRect(CGRect(x: x, y: y, width: holeW, height: holeH), radius: 8))
        }
    }
    ctx.fillPath()

    // Picture: pixelated on the lower left, crisp on the upper right.
    let picture = CGRect(x: frame.minX + 28, y: frame.minY + 72, width: frame.width - 56, height: frame.height - 144)
    let sceneCtx = makeContext(Int(picture.width), Int(picture.height))
    drawScene(in: sceneCtx, size: picture.size)
    let crisp = sceneCtx.makeImage()!

    let blocks = 14
    let lowCtx = makeContext(blocks, Int((CGFloat(blocks) * picture.height / picture.width).rounded()))
    lowCtx.interpolationQuality = .high
    lowCtx.draw(crisp, in: CGRect(x: 0, y: 0, width: lowCtx.width, height: lowCtx.height))
    let pixelated = lowCtx.makeImage()!

    let picturePath = continuousRect(picture, radius: 20)
    ctx.saveGState()
    ctx.addPath(picturePath)
    ctx.clip()
    ctx.draw(crisp, in: picture)
    // Diagonal split.
    let split = CGMutablePath()
    split.move(to: CGPoint(x: picture.minX, y: picture.maxY + 40))
    split.addLine(to: CGPoint(x: picture.minX + picture.width * 0.62, y: picture.maxY + 40))
    split.addLine(to: CGPoint(x: picture.minX + picture.width * 0.38, y: picture.minY - 40))
    split.addLine(to: CGPoint(x: picture.minX, y: picture.minY - 40))
    split.closeSubpath()
    ctx.saveGState()
    ctx.addPath(split)
    ctx.clip()
    ctx.interpolationQuality = .none
    ctx.draw(pixelated, in: picture)
    // Faint grid lines between the big pixels.
    ctx.setStrokeColor(color(0x000000, 0.18))
    ctx.setLineWidth(2)
    let cell = picture.width / CGFloat(blocks)
    var gx = picture.minX + cell
    while gx < picture.maxX { ctx.move(to: CGPoint(x: gx, y: picture.minY)); ctx.addLine(to: CGPoint(x: gx, y: picture.maxY)); gx += cell }
    let cellY = picture.height / CGFloat(lowCtx.height)
    var gy = picture.minY + cellY
    while gy < picture.maxY { ctx.move(to: CGPoint(x: picture.minX, y: gy)); ctx.addLine(to: CGPoint(x: picture.maxX, y: gy)); gy += cellY }
    ctx.strokePath()
    ctx.restoreGState()
    // Bright seam along the split.
    ctx.setStrokeColor(color(0xFFFFFF, 0.95))
    ctx.setLineWidth(6)
    ctx.setShadow(offset: .zero, blur: 18, color: color(0xFFFFFF, 0.9))
    ctx.move(to: CGPoint(x: picture.minX + picture.width * 0.62, y: picture.maxY + 40))
    ctx.addLine(to: CGPoint(x: picture.minX + picture.width * 0.38, y: picture.minY - 40))
    ctx.strokePath()
    ctx.restoreGState()

    // Sparkles.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30, color: color(0xFFE9A8, 0.9))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.addPath(sparkle(center: CGPoint(x: 776, y: 752), radius: 96))
    ctx.addPath(sparkle(center: CGPoint(x: 676, y: 826), radius: 40))
    ctx.fillPath()
    ctx.restoreGState()

    // Subtle inner edge highlight.
    ctx.addPath(continuousRect(tileRect.insetBy(dx: 1.5, dy: 1.5), radius: tileRadius - 1.5))
    ctx.setStrokeColor(color(0xFFFFFF, 0.18))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

func resized(_ image: CGImage, to px: Int) -> CGImage {
    let ctx = makeContext(px, px)
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
    return ctx.makeImage()!
}

func pngData(_ image: CGImage) -> Data {
    NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

/// Builds an .icns container directly in memory (PNG-encoded entries), so no iconset folder is needed.
func icnsData(_ master: CGImage) -> Data {
    let entries: [(String, Int)] = [
        ("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256),
        ("ic09", 512), ("ic10", 1024), ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512),
    ]
    var body = Data()
    for (type, px) in entries {
        let png = pngData(px == 1024 ? master : resized(master, to: px))
        body.append(type.data(using: .ascii)!)
        withUnsafeBytes(of: UInt32(png.count + 8).bigEndian) { body.append(contentsOf: $0) }
        body.append(png)
    }
    var file = "icns".data(using: .ascii)!
    withUnsafeBytes(of: UInt32(body.count + 8).bigEndian) { file.append(contentsOf: $0) }
    file.append(body)
    return file
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: MakeIcon.swift <output.icns> [preview.png]\n".data(using: .utf8)!)
    exit(1)
}
let master = renderMaster()
try icnsData(master).write(to: URL(fileURLWithPath: args[1]))
if args.count >= 3 { try pngData(master).write(to: URL(fileURLWithPath: args[2])) }
