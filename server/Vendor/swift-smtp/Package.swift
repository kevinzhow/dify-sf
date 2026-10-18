// swift-tools-version:6.4
// dify-sf: upstream swift-smtp 2.19.0's manifest reduced to the SwiftSMTP library (see PATCHES.md).
import PackageDescription

let swiftSettings: Array<SwiftSetting> = [
    .swiftLanguageMode(.v6),
    .strictMemorySafety(),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableExperimentalFeature("Lifetimes"),
    .enableExperimentalFeature("LifetimeDependence"),
]

let package = Package(
    name: "swift-smtp",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
        .tvOS(.v15),
        .watchOS(.v9),
    ],
    products: [
        .library(name: "SwiftSMTP", targets: ["SwiftSMTP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-algorithms", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.78.0"),
        .package(url: "https://github.com/apple/swift-nio-extras", from: "1.24.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl", from: "2.29.0"),
    ],
    targets: [
        .target(
            name: "SwiftSMTP",
            dependencies: [
                .product(name: "Algorithms", package: "swift-algorithms"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOExtras", package: "swift-nio-extras"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            swiftSettings: swiftSettings),
    ]
)
