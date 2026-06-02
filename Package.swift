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
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "pgBrain",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/pgBrain",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                // Required so dyld finds the embedded Sparkle.framework that
                // bundle.sh copies into Contents/Frameworks/. Without this
                // rpath, the app crashes at launch with
                //   Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
                // because the SPM-built executable only carries
                // @loader_path + /usr/lib/swift rpaths.
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ])
            ]
        ),
        .testTarget(
            name: "pgBrainTests",
            dependencies: [
                "pgBrain",
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ],
            path: "Tests/pgBrainTests",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
