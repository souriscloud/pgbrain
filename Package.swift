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
        // PostgresNIO is added in iter-2 when we actually connect to a server.
        // .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
    ],
    targets: [
        .executableTarget(
            name: "pgBrain",
            dependencies: [],
            path: "Sources/pgBrain",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
