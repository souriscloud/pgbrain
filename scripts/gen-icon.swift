#!/usr/bin/env swift
//
// Generate AppIcon.icns from a programmatic CoreGraphics drawing.
// Designed to render cleanly through macOS Sequoia icon tinting — uses a single
// monochromatic shape on a flat background, no gradients on the foreground.
//
// Usage:
//   swift scripts/gen-icon.swift <output.icns>

import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: gen-icon.swift <output.icns>\n".data(using: .utf8)!)
    exit(2)
}
let outputPath = CommandLine.arguments[1]
let outputURL = URL(fileURLWithPath: outputPath)

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

// Brand colors (match Tokens.Brand in code).
let brandTop   = CGColor(red: 0.42, green: 0.32, blue: 0.86, alpha: 1.0)
let brandBot   = CGColor(red: 0.30, green: 0.23, blue: 0.62, alpha: 1.0)
let foreground = CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)

func renderIcon(size: Int) -> Data? {
    let s = CGFloat(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // macOS app icons follow a "squircle" outline at ~0.225 of the side length.
    let corner = s * 0.225
    let inset = s * 0.10
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = CGPath(roundedRect: rect, cornerWidth: corner * (rect.width / s), cornerHeight: corner * (rect.height / s), transform: nil)

    // Background gradient (purple → deeper purple).
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    if let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [brandTop, brandBot] as CFArray,
        locations: [0.0, 1.0]
    ) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }
    ctx.restoreGState()

    // Foreground: stylized "stacked database cylinder" mark — three ellipses
    // separated by short straight runs, white, centered, balanced for tinting.
    ctx.setFillColor(foreground)
    ctx.setStrokeColor(foreground)
    ctx.setLineWidth(s * 0.06)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    let cx = s / 2
    let bodyW = s * 0.46
    let bodyH = s * 0.52
    let ellipseH = bodyW * 0.32
    let bodyTop = (s - bodyH) / 2
    let bodyLeft = cx - bodyW / 2

    // Top ellipse
    let topRect = CGRect(x: bodyLeft, y: bodyTop, width: bodyW, height: ellipseH)
    ctx.fillEllipse(in: topRect)

    // Body sides as a filled rect minus the top-ellipse top half.
    let bodyRect = CGRect(x: bodyLeft, y: bodyTop + ellipseH / 2, width: bodyW, height: bodyH - ellipseH)
    ctx.fill(bodyRect)

    // Bottom ellipse (drawn on top so the curvature is correct)
    let botRect = CGRect(x: bodyLeft, y: bodyTop + bodyH - ellipseH, width: bodyW, height: ellipseH)
    ctx.fillEllipse(in: botRect)

    // Middle separator ring — drawn as a thin ellipse stroke to suggest the "split" tier.
    let midRect = CGRect(x: bodyLeft, y: bodyTop + (bodyH - ellipseH) / 2, width: bodyW, height: ellipseH)
    ctx.setStrokeColor(brandTop)
    ctx.setLineWidth(s * 0.025)
    ctx.strokeEllipse(in: midRect)

    guard let cgImage = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])
}

// Create temp .iconset folder.
let fm = FileManager.default
let tmpDir = fm.temporaryDirectory.appendingPathComponent("pgBrain-AppIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)

for (name, px) in sizes {
    guard let png = renderIcon(size: px) else {
        FileHandle.standardError.write("failed to render \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    try png.write(to: tmpDir.appendingPathComponent(name))
}

// iconutil to convert to .icns
try? fm.removeItem(at: outputURL)
try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", tmpDir.path, "-o", outputURL.path]
let pipe = Pipe()
proc.standardOutput = pipe
proc.standardError = pipe
try proc.run()
proc.waitUntilExit()

try? fm.removeItem(at: tmpDir)

if proc.terminationStatus == 0 {
    print("Wrote \(outputURL.path)")
} else {
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    FileHandle.standardError.write(out)
    exit(Int32(proc.terminationStatus))
}
