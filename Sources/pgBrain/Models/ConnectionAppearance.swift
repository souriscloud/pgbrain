import AppKit
import SwiftUI

/// Single chokepoint for "what colour is this connection?" used everywhere
/// pgBrain has to paint a connection — Welcome row, tab strip, sidebar
/// header, status footer, menu bar window list. Keeps the rules in one
/// place so a future redesign is a single-file change.
struct ConnectionAppearance {
    let connection: Connection

    /// Brand violet when no per-connection colour is set; the connection's
    /// own colour otherwise. Used for active tab underlines and the sidebar
    /// header strip.
    var accent: Color {
        if connection.colorTag == .none { return Tokens.Brand.primary }
        return connection.colorTag.swiftUIColor
    }

    /// Production overrides everything else — a hot connection is always red.
    var danger: Color { Tokens.Brand.danger }

    /// The colour to draw a "you are here" emphasis with. Production wins.
    var emphasized: Color {
        connection.isProduction ? danger : accent
    }

    /// Window background tint. Production gets a faint red wash so the
    /// entire chrome reads as hot at a glance.
    var windowTintNS: NSColor? {
        if connection.isProduction { return NSColor(danger).withAlphaComponent(0.06) }
        if connection.colorTag != .none { return NSColor(accent).withAlphaComponent(0.04) }
        return nil
    }

    /// Short title-bar suffix string e.g. " · PROD" used by the menu bar
    /// window list so the user can spot prod connections without colour
    /// (e.g. when scanning the dropdown with reduced contrast on).
    var suffix: String {
        connection.isProduction ? " · PROD" : ""
    }
}
