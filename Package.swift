// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pgBrain",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "pgBrain", targets: ["pgBrain"])
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
    ],
    targets: [
        .executableTarget(
            name: "pgBrain",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio")
            ],
            path: "Sources/pgBrain",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
