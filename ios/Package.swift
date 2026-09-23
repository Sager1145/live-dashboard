// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveDashboardKit",
    defaultLocalization: "zh-Hans",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "LiveDashboardKit", targets: ["LiveDashboardKit"])
    ],
    targets: [
        .target(
            name: "LiveDashboardKit",
            path: "Sources/LiveDashboardKit",
            // Older local copies must not redeclare the active view types.
            exclude: [
                "Features/CardSettings/CardSettingsView 2.swift",
                "Features/LiveDetail/OfficialMediaView 2.swift",
                "Features/Settings/SettingsView 2.swift"
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "LiveDashboardKitTests",
            dependencies: ["LiveDashboardKit"],
            path: "Tests/LiveDashboardKitTests"
        )
    ]
)
