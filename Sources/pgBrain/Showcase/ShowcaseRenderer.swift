#if DEBUG
import AppKit

/// Off-screen rendering for the screenshot harness: windows live at
/// (-30000, -30000) below the desktop level, and pixels come from
/// `cacheDisplay(in:to:)` on the window's frame view (title bar and traffic
/// lights included) — no screen-capture API, no permission prompt, nothing
/// drawn on a real display.
@MainActor
enum ShowcaseRenderer {
    static let scale: CGFloat = 2

    /// Far outside any display arrangement.
    static let parkingOrigin = NSPoint(x: -30_000, y: -30_000)

    /// SwiftUI scroll content only draws into layers the window server has
    /// committed, so windows are ordered in — but far off every display,
    /// below the desktop level, skipped by Mission Control and the window
    /// cycle, and never key. NSWindow would normally pull a titled window
    /// back on-screen when ordering it in; that constraint is disabled for
    /// showcase runs.
    static func orderInOffscreen(_ window: NSWindow) {
        disableFrameConstraint()
        window.setFrameOrigin(parkingOrigin)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.collectionBehavior = [.stationary, .ignoresCycle, .transient, .fullScreenNone]
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        window.setFrameOrigin(parkingOrigin)
    }

    /// Hard stop if anything ever moved a visible window onto a display:
    /// the run must never show up on the user's screen.
    static func guardOffscreen(_ window: NSWindow) {
        guard window.isVisible else { return }
        let onScreen = NSScreen.screens.contains { $0.frame.intersects(window.frame) }
        if onScreen {
            window.orderOut(nil)
            ShowcaseLog.write("ABORT: window \(window.title) reached a display at \(window.frame)")
            exit(3)
        }
    }

    private static var frameConstraintDisabled = false

    private static func disableFrameConstraint() {
        guard !frameConstraintDisabled else { return }
        frameConstraintDisabled = true
        let sel = #selector(NSWindow.constrainFrameRect(_:to:))
        guard let method = class_getInstanceMethod(NSWindow.self, sel) else { return }
        let unchanged: @convention(block) (AnyObject, NSRect, NSScreen?) -> NSRect = { _, rect, _ in rect }
        method_setImplementation(method, imp_implementationWithBlock(unchanged))
    }

    /// Settle SwiftUI + AppKit layout: SwiftUI commits its graph on runloop
    /// turns, and AppKit views driven by it (grids, outline) lay out after.
    static func settle(_ window: NSWindow, turns: Int = 4) async {
        for _ in 0..<turns {
            guardOffscreen(window)
            window.layoutIfNeeded()
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            if let frame = window.contentView?.superview {
                pinVisualEffects(in: frame)
                prepareTables(in: frame)
                replaceSidebarSelection(in: frame)
            }
            window.contentView?.needsDisplay = true
            window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(60))
        }
    }

    /// Render a view (usually a window's frame view) to an image. SwiftUI's
    /// `ScrollView` clip views draw only their background through
    /// `cacheDisplay` (their document lives in a separately committed
    /// layer), so each one's visible document area is rendered on its own
    /// and laid over the spot the clip view occupies.
    static func image(of root: NSView) -> CGImage? {
        let clips = hostingClipViews(in: root)
        // The one-shot render of a document can leave a partial or
        // misplaced copy behind; render everything around the documents
        // first, then each document on top.
        let docs = (clips.compactMap(\.documentView) + nestedHostingViews(in: root)).filter { !$0.isHidden }
        for doc in docs { doc.isHidden = true }
        let base = bitmap(of: root)?.cgImage
        for doc in docs { doc.isHidden = false }
        guard let base else { return nil }
        guard !docs.isEmpty,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return base }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        let s = CGFloat(base.width) / root.bounds.width
        for view in docs {
            let docRect = view.visibleRect.intersection(view.bounds)
            guard docRect.width >= 1, docRect.height >= 1 else { continue }
            // Rendering a sub-rect comes out empty; render whole and crop.
            guard let whole = composedImage(of: view) else { continue }
            let ds = CGFloat(whole.width) / view.bounds.width
            let cropY = view.isFlipped ? docRect.minY : view.bounds.height - docRect.maxY
            guard let patch = whole.cropping(to: CGRect(x: docRect.minX * ds, y: cropY * ds,
                                                         width: docRect.width * ds,
                                                         height: docRect.height * ds)) else { continue }
            var target = view.convert(docRect, to: root)
            if root.isFlipped { target.origin.y = root.bounds.height - target.maxY }
            ctx.draw(patch, in: CGRect(x: target.minX * s, y: target.minY * s,
                                       width: target.width * s, height: target.height * s))
        }
        drawSwitches(in: root, ctx: ctx, scale: s)
        return ctx.makeImage() ?? base
    }

    /// NSSwitch animates its knob in a Core Animation layer, so a cached
    /// render always shows the "off" position. Redraw switches that are on.
    private static func drawSwitches(in root: NSView, ctx: CGContext, scale s: CGFloat) {
        func collect(_ v: NSView) -> [NSSwitch] {
            if let sw = v as? NSSwitch { return v.isHiddenOrHasHiddenAncestor ? [] : [sw] }
            return v.subviews.flatMap(collect)
        }
        for sw in collect(root) where sw.state == .on {
            var r = sw.convert(sw.bounds, to: root)
            if root.isFlipped { r.origin.y = root.bounds.height - r.maxY }
            if let scroll = sw.enclosingScrollView {
                var clip = scroll.contentView.convert(scroll.contentView.bounds, to: root)
                if root.isFlipped { clip.origin.y = root.bounds.height - clip.maxY }
                guard clip.contains(r.insetBy(dx: 1, dy: 1)) else { continue }
            }
            let track = CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s)
                .insetBy(dx: 0.5 * s, dy: 0.5 * s)
            // SwiftUI's `.tint` reaches the switch as its content tint.
            let tint = sw.responds(to: NSSelectorFromString("contentTintColor"))
                ? sw.value(forKey: "contentTintColor") as? NSColor : nil
            var accent = (tint ?? .controlAccentColor).cgColor
            sw.effectiveAppearance.performAsCurrentDrawingAppearance {
                accent = (tint ?? .controlAccentColor).cgColor
            }
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: track, cornerWidth: track.height / 2, cornerHeight: track.height / 2,
                               transform: nil))
            ctx.setFillColor(accent)
            ctx.fillPath()
            let inset = 2 * s
            let knobH = track.height - inset * 2
            let knobW = min(knobH * 1.45, track.width * 0.6)
            let knob = CGRect(x: track.maxX - inset - knobW, y: track.minY + inset, width: knobW, height: knobH)
            ctx.setShadow(offset: CGSize(width: 0, height: -0.5 * s), blur: 1.5 * s,
                          color: NSColor.black.withAlphaComponent(0.3).cgColor)
            ctx.addPath(CGPath(roundedRect: knob, cornerWidth: knobH / 2, cornerHeight: knobH / 2, transform: nil))
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    /// Render `view` one level at a time: its own drawing with the children
    /// hidden, then each child on top at its frame. SwiftUI group
    /// containers inside scroll views lose their hosted AppKit children when
    /// cached in one go; rendered level by level they come out whole.
    static func composedImage(of view: NSView) -> CGImage? {
        let size = view.bounds.size
        guard size.width >= 1, size.height >= 1,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let children = view.subviews.filter { !$0.isHidden && $0.alphaValue > 0.01 }
        if !children.isEmpty && isSwiftUIContainer(view) {
            for child in children { child.isHidden = true }
            if let own = bitmap(of: view)?.cgImage {
                ctx.draw(own, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
            }
            for child in children { child.isHidden = false }
            for child in children {
                guard let img = composedImage(of: child) else { continue }
                var r = child.frame
                if view.isFlipped { r.origin.y = size.height - r.maxY }
                ctx.saveGState()
                ctx.setAlpha(child.alphaValue)
                ctx.draw(img, in: CGRect(x: r.minX * scale, y: r.minY * scale,
                                         width: r.width * scale, height: r.height * scale))
                ctx.restoreGState()
            }
        } else if let whole = bitmap(of: view)?.cgImage {
            ctx.draw(whole, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        }
        return ctx.makeImage()
    }

    private static func isSwiftUIContainer(_ view: NSView) -> Bool {
        let name = String(describing: type(of: view))
        return name.contains("PlatformGroupContainer") || name == "DocumentView"
            || name.contains("PlatformContainer")
    }

    private static func invalidateTree(_ view: NSView) {
        view.needsDisplay = true
        for sub in view.subviews { invalidateTree(sub) }
    }

    /// SwiftUI `List` rows host each cell in its own hosting view, which
    /// the one-shot render also leaves empty.
    private static func nestedHostingViews(in view: NSView) -> [NSView] {
        if String(describing: type(of: view)).hasPrefix("CellHostingView"), !view.isHiddenOrHasHiddenAncestor {
            return [view]
        }
        return view.subviews.flatMap(nestedHostingViews(in:))
    }

    private static func hostingClipViews(in view: NSView) -> [NSClipView] {
        var out: [NSClipView] = []
        if let clip = view as? NSClipView, let scroll = clip.superview,
           String(describing: type(of: scroll)).contains("HostingScrollView"), !view.isHiddenOrHasHiddenAncestor {
            out.append(clip)
        }
        for sub in view.subviews { out += hostingClipViews(in: sub) }
        return out
    }

    static func bitmap(of view: NSView) -> NSBitmapImageRep? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int((bounds.width * scale).rounded()),
                pixelsHigh: Int((bounds.height * scale).rounded()),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = bounds.size
        invalidateTree(view)
        // Rendered in isolation, a subtree would otherwise draw with the
        // system appearance instead of the one its window forces.
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: bounds, to: rep)
        }
        return rep
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw ShowcaseError("PNG encoding failed for \(url.lastPathComponent)")
        }
        try data.write(to: url, options: .atomic)
    }

    /// Draw `overlays` over `base` (both window-sized in points), dimming the
    /// base first when `dim` > 0 — how a sheet or the palette panel sits on
    /// the window it belongs to. Overlays get rounded corners and a shadow.
    static func composite(base: CGImage, dim: CGFloat, overlays: [(image: CGImage, originPoints: CGPoint)],
                          baseSizePoints: CGSize, dark: Bool, cornerRadius: CGFloat) -> CGImage? {
        let w = base.width, h = base.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.draw(base, in: full)
        if dim > 0 {
            ctx.setFillColor(NSColor.black.withAlphaComponent(dim).cgColor)
            ctx.fill(full)
        }
        let s = CGFloat(w) / baseSizePoints.width
        for overlay in overlays {
            let rect = CGRect(x: overlay.originPoints.x * s, y: overlay.originPoints.y * s,
                              width: CGFloat(overlay.image.width), height: CGFloat(overlay.image.height))
            let shape = CGPath(roundedRect: rect, cornerWidth: cornerRadius * s, cornerHeight: cornerRadius * s,
                               transform: nil)
            if cornerRadius > 0 {
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 44 * s,
                              color: NSColor.black.withAlphaComponent(dark ? 0.55 : 0.28).cgColor)
                ctx.addPath(shape)
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fillPath()
                ctx.restoreGState()
                ctx.saveGState()
                ctx.addPath(shape)
                ctx.clip()
            }
            ctx.draw(overlay.image, in: rect)
            if cornerRadius > 0 {
                ctx.restoreGState()
                if dark {
                    ctx.saveGState()
                    ctx.addPath(shape)
                    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
                    ctx.setLineWidth(s)
                    ctx.strokePath()
                    ctx.restoreGState()
                }
            }
        }
        return ctx.makeImage()
    }

    /// Table rows are only built for the part the window server says is
    /// visible; build them all so rows inside SwiftUI scroll views render.
    static func prepareTables(in view: NSView) {
        if let table = view as? NSTableView, table.numberOfRows > 0 {
            table.prepareContent(in: table.bounds)
            table.layoutSubtreeIfNeeded()
        }
        for sub in view.subviews { prepareTables(in: sub) }
    }

    /// Source-list selection pills are drawn by a private view that only the
    /// window server composites (it comes out black here). Swap in a plain
    /// rounded fill with the same system color.
    static func replaceSidebarSelection(in view: NSView) {
        if let row = view as? NSTableRowView {
            let marker = NSUserInterfaceItemIdentifier("showcase.selection")
            var pill: NSView?
            for sub in row.subviews {
                if String(describing: type(of: sub)).contains("SelectionView") {
                    sub.isHidden = true
                    pill = pill ?? sub
                }
            }
            row.subviews.first { $0.identifier == marker }?.removeFromSuperview()
            if row.isSelected, let pill {
                let box = NSBox(frame: pill.frame)
                box.identifier = marker
                box.boxType = .custom
                box.borderWidth = 0
                box.cornerRadius = 5
                box.fillColor = row.isEmphasized ? .selectedContentBackgroundColor
                    : .unemphasizedSelectedContentBackgroundColor
                row.addSubview(box, positioned: .below, relativeTo: nil)
            }
            return
        }
        for sub in view.subviews { replaceSidebarSelection(in: sub) }
    }

    /// Behind-window materials sample the desktop through the window
    /// server, which an off-screen render never reaches — they'd come out
    /// blank. Within-window blending renders from the view tree instead.
    static func pinVisualEffects(in view: NSView) {
        if let effect = view as? NSVisualEffectView {
            if effect.blendingMode != .withinWindow { effect.blendingMode = .withinWindow }
            if effect.state != .active { effect.state = .active }
        }
        for sub in view.subviews { pinVisualEffects(in: sub) }
    }

    /// Guard against the classic off-screen failure modes (missing chrome,
    /// blank sidebar): each probe rect (in points, top-left origin) must
    /// contain more than a flat fill.
    static func assertNotBlank(_ image: CGImage, pointSize: CGSize, probes: [(String, CGRect)]) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        let s = CGFloat(image.width) / pointSize.width
        for (label, rect) in probes {
            var minL: CGFloat = 1, maxL: CGFloat = 0
            var y = rect.minY
            while y < rect.maxY {
                var x = rect.minX
                while x < rect.maxX {
                    if let c = rep.colorAt(x: Int(x * s), y: Int(y * s))?.usingColorSpace(.sRGB) {
                        let l = (c.redComponent + c.greenComponent + c.blueComponent) / 3 * c.alphaComponent
                        minL = min(minL, l)
                        maxL = max(maxL, l)
                    }
                    x += 3
                }
                y += 3
            }
            if maxL - minL < 0.1 {
                throw ShowcaseError("\(label) region looks blank (luma \(minL)…\(maxL))")
            }
        }
    }
}

struct ShowcaseError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
#endif
