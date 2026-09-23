// Post-processes raw showcase renders (scripts/screenshots.sh).
//
//   swift scripts/showcase/frame.swift <raw-dir> <out-dir>
//
// For every <name>.png in raw-dir writes to out-dir:
//   <name>.png            the window with macOS 26 rounded corners (@2x)
//   <name>-framed.png     rounded + soft drop shadow on transparent (@1x)
//   <name>-marketing.png  16:9 on the brand-violet gradient (1920x1080)

import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: frame.swift <raw-dir> <out-dir>\n".utf8))
    exit(2)
}
let rawDir = URL(fileURLWithPath: args[1], isDirectory: true)
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// Window corner radius in points; macOS 26 windows use ~12pt.
let cornerRadius: CGFloat = 12

func context(width: Int, height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func load(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func write(_ image: CGImage, _ name: String) throws {
    let url = outDir.appendingPathComponent(name)
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "frame", code: 1, userInfo: [NSLocalizedDescriptionKey: "encode \(name)"])
    }
    try data.write(to: url, options: .atomic)
}

/// `image` (at `scale` px/pt) clipped to rounded window corners and drawn
/// into `rect` of `ctx`, with an optional shadow underneath.
func drawWindow(_ image: CGImage, in rect: CGRect, ctx: CGContext, radius: CGFloat, shadow: (blur: CGFloat, y: CGFloat, alpha: CGFloat)?) {
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    if let shadow {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -shadow.y), blur: shadow.blur,
                      color: CGColor(gray: 0, alpha: shadow.alpha))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(image, in: rect)
    ctx.restoreGState()
    // Hairline edge, like the window server draws around every window.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.18))
    ctx.setLineWidth(max(1, radius / 12))
    ctx.strokePath()
    ctx.restoreGState()
}

/// Brand violet (AppearanceTokens.Brand.primary ≈ #6B52DB) fading to a
/// deeper shade, with a soft light bloom behind the window.
func brandBackground(_ ctx: CGContext, size: CGSize) {
    let colors = [
        CGColor(srgbRed: 0.53, green: 0.43, blue: 0.93, alpha: 1),
        CGColor(srgbRed: 0.42, green: 0.32, blue: 0.86, alpha: 1),
        CGColor(srgbRed: 0.24, green: 0.17, blue: 0.55, alpha: 1),
    ] as CFArray
    let gradient = CGGradient(colorsSpace: sRGB, colors: colors, locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let bloom = CGGradient(colorsSpace: sRGB, colors: [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
    ] as CFArray, locations: [0, 1])!
    let c = CGPoint(x: size.width * 0.5, y: size.height * 0.62)
    ctx.drawRadialGradient(bloom, startCenter: c, startRadius: 0, endCenter: c, endRadius: size.width * 0.55,
                           options: [])
}

let files = try FileManager.default.contentsOfDirectory(at: rawDir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "png" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
guard !files.isEmpty else {
    FileHandle.standardError.write(Data("no PNGs in \(rawDir.path)\n".utf8))
    exit(1)
}

for file in files {
    guard let raw = load(file) else {
        FileHandle.standardError.write(Data("unreadable: \(file.lastPathComponent)\n".utf8))
        exit(1)
    }
    let name = file.deletingPathExtension().lastPathComponent
    let w = CGFloat(raw.width), h = CGFloat(raw.height)

    // Rounded @2x, no padding.
    let rounded = context(width: raw.width, height: raw.height)
    drawWindow(raw, in: CGRect(x: 0, y: 0, width: w, height: h), ctx: rounded, radius: cornerRadius * 2, shadow: nil)
    try write(rounded.makeImage()!, "\(name).png")

    // Framed @1x: shadow needs room around the window.
    let pw = w / 2, ph = h / 2, pad: CGFloat = 60
    let framed = context(width: Int(pw + pad * 2), height: Int(ph + pad * 2))
    drawWindow(raw, in: CGRect(x: pad, y: pad + 8, width: pw, height: ph), ctx: framed, radius: cornerRadius,
               shadow: (blur: 44, y: 16, alpha: 0.38))
    try write(framed.makeImage()!, "\(name)-framed.png")

    // Marketing 16:9, 1920x1080, window ~78% of the width.
    let mw: CGFloat = 1920, mh: CGFloat = 1080
    let marketing = context(width: Int(mw), height: Int(mh))
    brandBackground(marketing, size: CGSize(width: mw, height: mh))
    let fit = min(mw * 0.8 / w, mh * 0.82 / h)
    let dw = (w * fit).rounded(), dh = (h * fit).rounded()
    let rect = CGRect(x: ((mw - dw) / 2).rounded(), y: ((mh - dh) / 2).rounded() + 6, width: dw, height: dh)
    drawWindow(raw, in: rect, ctx: marketing, radius: cornerRadius * fit * 2,
               shadow: (blur: 60, y: 24, alpha: 0.45))
    try write(marketing.makeImage()!, "\(name)-marketing.png")
    print("framed \(name)")
}
