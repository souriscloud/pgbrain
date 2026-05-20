import SwiftUI

/// Shared visual tokens. Keep this small — it's a paint job aid, not a design system.
enum Tokens {
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 20
        static let xl: CGFloat = 32
    }

    enum Corner {
        static let card: CGFloat = 10
        static let chip: CGFloat = 6
    }

    enum Window {
        static let welcomeSize = CGSize(width: 820, height: 540)
        static let aboutSize = CGSize(width: 460, height: 380)
    }

    enum Brand {
        /// pgBrain accent — a deep violet that survives macOS Sequoia icon tinting.
        static let primary = Color(red: 0.42, green: 0.32, blue: 0.86)
        static let primaryDim = Color(red: 0.30, green: 0.23, blue: 0.62)
        static let danger = Color(red: 0.86, green: 0.24, blue: 0.28)
    }
}
