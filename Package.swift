// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Strata",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Strata", targets: ["Strata"]),
    ],
    targets: [
        // Scanning a volume and holding the result: no UI, no AppKit.
        .target(name: "ScanCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        // Geometry of the two map views (bubbles, flow): pure functions over sizes.
        .target(name: "MapLayout", swiftSettings: [.swiftLanguageMode(.v5)]),
        // The app.
        .executableTarget(
            name: "Strata",
            dependencies: ["ScanCore", "MapLayout"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "ScanCoreTests", dependencies: ["ScanCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MapLayoutTests", dependencies: ["MapLayout"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "StrataTests", dependencies: ["Strata", "ScanCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
