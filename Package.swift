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
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.33.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.0"),
        // Imported directly by the scratchpad wire client and the logging
        // bridge; declared so they don't ride on PostgresNIO's transitive graph.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "pgBrain",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/pgBrain",
            swiftSettings: [
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
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
