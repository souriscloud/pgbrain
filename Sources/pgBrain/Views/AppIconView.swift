import AppKit
import SwiftUI

/// Uses the same native icon representations as Finder, Dock and the installer.
struct AppIconView: View {
  var size: CGFloat = 80

  private var icon: NSImage {
    if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
      let image = NSImage(contentsOf: url) {
      return image
    }

    return NSImage()
  }

  var body: some View {
    Image(nsImage: icon)
      .resizable()
      .interpolation(.high)
      .scaledToFit()
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}
