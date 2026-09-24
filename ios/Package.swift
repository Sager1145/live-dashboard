// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveDashboardKit",
    defaultLocalization: "zh-Hans",
    platforms: [
        .iOS(.v18),
        .macOS(.v14)
    ],
    products: [
        .library(name: "LiveDashboardKit", targets: ["LiveDashboardKit"]),
        .executable(name: "OfficialAuditCLI", targets: ["OfficialAuditCLI"])
    ],
    targets: [
        .target(
            name: "SwiftSoup",
            path: "Vendor/SwiftSoup",
            exclude: ["LICENSE"]
        ),
        .target(
            name: "LiveIngestionCore",
            dependencies: ["SwiftSoup"],
            path: "Sources/LiveIngestionCore"
        ),
        .executableTarget(
            name: "OfficialAuditCLI",
            dependencies: ["LiveIngestionCore"],
            path: "Sources/OfficialAuditCLI"
        ),
        .target(
            name: "LiveDashboardKit",
            dependencies: ["LiveIngestionCore"],
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
