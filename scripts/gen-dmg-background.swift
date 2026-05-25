#!/usr/bin/env swift
//
// Generates the pgBrain DMG background image (PNG) at the path passed as
// argv[1]. Brand-violet gradient + stacked-cylinder DB mark, sized
// 660x400 to match the create-dmg window size used in build-dmg.sh.
//
// Run:
//   swift scripts/gen-dmg-background.swift Resources/dmg-background.png

import AppKit
import CoreGraphics
import Foundation

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/dmg-background.png"

let size = CGSize(width: 660, height: 400)
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: Int(size.width),
    height: Int(size.height),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("Failed to create CG context\n", stderr)
    exit(1)
}

// Brand gradient — matches AppIcon and Welcome window.
let topColor = CGColor(red: 0.42, green: 0.32, blue: 0.86, alpha: 1)
let bottomColor = CGColor(red: 0.20, green: 0.13, blue: 0.45, alpha: 1)
let grad = CGGradient(colorsSpace: cs, colors: [topColor, bottomColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(
    grad,
    start: CGPoint(x: 0, y: size.height),
    end: CGPoint(x: 0, y: 0),
    options: []
)

// Subtle vignette so the icon + Applications shortcut pop.
let vignetteColors = [
    CGColor(red: 1, green: 1, blue: 1, alpha: 0.08),
    CGColor(red: 0, green: 0, blue: 0, alpha: 0.10),
] as CFArray
let vignette = CGGradient(colorsSpace: cs, colors: vignetteColors, locations: [0, 1])!
ctx.drawRadialGradient(
    vignette,
    startCenter: CGPoint(x: size.width / 2, y: size.height / 2),
    startRadius: 0,
    endCenter: CGPoint(x: size.width / 2, y: size.height / 2),
    endRadius: size.width * 0.6,
    options: []
)

// "drag to install" arrow between the two finder icon slots.
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.5))
ctx.setLineWidth(2)
ctx.setLineCap(.round)
let arrowY = size.height / 2 - 30
ctx.move(to: CGPoint(x: 235, y: arrowY))
ctx.addLine(to: CGPoint(x: 420, y: arrowY))
ctx.strokePath()
ctx.move(to: CGPoint(x: 405, y: arrowY + 10))
ctx.addLine(to: CGPoint(x: 420, y: arrowY))
ctx.addLine(to: CGPoint(x: 405, y: arrowY - 10))
ctx.strokePath()

// Title text "Drag pgBrain to Applications" near the top.
let title = NSAttributedString(
    string: "Drag pgBrain to Applications to install.",
    attributes: [
        .font: NSFont.systemFont(ofSize: 16, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.92),
    ]
)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let titleSize = title.size()
title.draw(at: CGPoint(x: (size.width - titleSize.width) / 2, y: size.height - 60))
NSGraphicsContext.restoreGraphicsState()

guard let image = ctx.makeImage() else {
    fputs("Failed to render image\n", stderr)
    exit(1)
}

let nsImage = NSImage(cgImage: image, size: size)
guard let tiff = nsImage.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let pngData = rep.representation(using: .png, properties: [:])
else {
    fputs("Failed to encode PNG\n", stderr)
    exit(1)
}

do {
    try pngData.write(to: URL(fileURLWithPath: outPath))
    print("✓ Wrote \(outPath) (\(pngData.count) bytes)")
} catch {
    fputs("Failed to write \(outPath): \(error)\n", stderr)
    exit(1)
}
