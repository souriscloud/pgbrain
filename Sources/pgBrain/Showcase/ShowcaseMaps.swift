#if DEBUG
import AppKit
import MapKit

/// MapKit draws its tiles with Metal straight to the window server, so an
/// off-screen view render leaves the map area blank. For every map on
/// screen, MKMapSnapshotter renders the same region, size and appearance,
/// and the map's own annotations are drawn on top as pins at their real
/// coordinates.
@MainActor
enum ShowcaseMaps {
    static func patch(_ image: CGImage, root: NSView, appearance: NSAppearance?) async -> CGImage {
        let maps = mapViews(in: root)
        guard !maps.isEmpty,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let s = CGFloat(image.width) / root.bounds.width
        for map in maps {
            let options = MKMapSnapshotter.Options()
            options.region = map.region
            options.size = map.bounds.size
            options.appearance = appearance
            options.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
            guard let snapshot = try? await MKMapSnapshotter(options: options).start(),
                  let tiles = snapshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else {
                ShowcaseLog.write("map snapshot failed (offline?) — map area left as rendered")
                continue
            }
            var rect = map.convert(map.bounds, to: root)
            if root.isFlipped { rect.origin.y = root.bounds.height - rect.maxY }
            let target = CGRect(x: rect.minX * s, y: rect.minY * s, width: rect.width * s, height: rect.height * s)
            ctx.saveGState()
            ctx.clip(to: target)
            ctx.draw(tiles, in: target)
            for annotation in map.annotations {
                let p = snapshot.point(for: annotation.coordinate)
                let title = (annotation.title ?? nil) ?? ""
                drawPin(in: ctx, at: CGPoint(x: target.minX + p.x * s, y: target.minY + p.y * s),
                        title: title, scale: s, dark: appearance?.name == .darkAqua)
            }
            ctx.restoreGState()
        }
        return ctx.makeImage() ?? image
    }

    private static func mapViews(in view: NSView) -> [MKMapView] {
        if let map = view as? MKMapView { return view.isHiddenOrHasHiddenAncestor ? [] : [map] }
        return view.subviews.flatMap(mapViews(in:))
    }

    /// A balloon marker in the brand violet with the feature's label.
    private static func drawPin(in ctx: CGContext, at tip: CGPoint, title: String, scale s: CGFloat, dark: Bool) {
        let violet = NSColor(red: 0.42, green: 0.32, blue: 0.86, alpha: 1)
        let r = 9 * s
        let center = CGPoint(x: tip.x, y: tip.y + 13 * s)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5 * s), blur: 4 * s,
                      color: NSColor.black.withAlphaComponent(0.35).cgColor)
        let balloon = CGMutablePath()
        balloon.addArc(center: center, radius: r, startAngle: -.pi / 4, endAngle: .pi * 5 / 4, clockwise: false)
        balloon.addLine(to: tip)
        balloon.closeSubpath()
        ctx.addPath(balloon)
        ctx.setFillColor(violet.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(balloon)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1.2 * s)
        ctx.strokePath()
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - 3.2 * s, y: center.y - 3.2 * s, width: 6.4 * s, height: 6.4 * s))

        guard !title.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: 10.5 * s, weight: .semibold)
        let text = NSAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: dark ? NSColor.white : NSColor(white: 0.12, alpha: 1),
            .strokeColor: dark ? NSColor.black.withAlphaComponent(0.8) : NSColor.white,
            .strokeWidth: -3,
        ])
        let size = text.size()
        let origin = CGPoint(x: tip.x - size.width / 2, y: tip.y - size.height - 2 * s)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        text.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
    }
}
#endif
