// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Xnap",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Xnap", targets: ["Xnap"]),
    ],
    targets: [
        // Pure image logic (scroll stitching). No AppKit, fully unit-tested.
        .target(
            name: "XnapCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The menu bar app itself.
        .executableTarget(
            name: "Xnap",
            dependencies: ["XnapCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("Vision"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "XnapCoreTests",
            dependencies: ["XnapCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "XnapTests",
            dependencies: ["Xnap"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
