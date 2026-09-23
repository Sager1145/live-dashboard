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
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "LiveDashboardKitTests",
            dependencies: ["LiveDashboardKit"],
            path: "Tests/LiveDashboardKitTests"
        )
    ]
)
