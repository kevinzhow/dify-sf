// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DifySF",
    products: [
        .library(name: "CollabCore", targets: ["CollabCore"]),
        .executable(name: "collab-server", targets: ["collab-server"]),
        .executable(name: "collab-sim", targets: ["collab-sim"]),
        .executable(name: "collab-bench", targets: ["collab-bench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", exact: "5.0.0-beta.4"),
        // Vendored copy of postgres-nio 1.33.1 with a one-line Swift 6.4 build fix (see Vendor/postgres-nio/PATCHES.md).
        .package(path: "Vendor/postgres-nio"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", exact: "2.13.0"),
        .package(url: "https://github.com/apple/swift-configuration.git", exact: "1.2.2"),
        .package(url: "https://github.com/swift-server/async-http-client.git", exact: "1.35.0"),
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
        // Already in the graph through Vapor (same version as Package.resolved): SHA-256 for token hashes, PBKDF2 for passwords.
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
    ],
    targets: [
        // Pure protocol logic: document model, ops, wire format, sequencer, client state machine. No I/O.
        .target(name: "CollabCore"),
        // Independent oracle + invariant checks (I1-I5) over plain evidence; used by the simulator and the chaos harness.
        .target(name: "CollabInvariants", dependencies: ["CollabCore"]),
        // Deterministic simulator: seeded PRNG, lossy network, fault injection.
        .target(name: "CollabSim", dependencies: ["CollabCore", "CollabInvariants"]),
        .executableTarget(name: "collab-sim", dependencies: ["CollabSim"]),
        // Dify workflow files (DSL, YAML) <-> documents.
        .target(name: "CollabDSL", dependencies: ["CollabCore", .product(name: "Yams", package: "Yams")]),
        // Postgres persistence (plain SQL via postgres-nio).
        .target(name: "CollabStore", dependencies: [
            "CollabCore",
            .product(name: "PostgresNIO", package: "postgres-nio"),
        ]),
        // The Vapor application: HTTP routes, per-document sequencer actors, SSE hub, configuration.
        .target(name: "CollabServer", dependencies: [
            "CollabCore", "CollabStore", "CollabDSL",
            .product(name: "Vapor", package: "vapor"),
            .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            .product(name: "Configuration", package: "swift-configuration"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "CryptoExtras", package: "swift-crypto"),
        ]),
        .executableTarget(name: "collab-server", dependencies: ["CollabServer"]),
        // Real HTTP/SSE driver around the pure client state machine (used by the chaos/storm harness).
        .target(name: "CollabClientKit", dependencies: [
            "CollabCore",
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
        ]),
        // Chaos + storm harness: real processes, fault proxy, ground-truth ledgers, invariant checks.
        .target(name: "CollabHarness", dependencies: [
            "CollabCore", "CollabInvariants", "CollabClientKit", "CollabStore",
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
            .product(name: "PostgresNIO", package: "postgres-nio"),
        ]),
        .executableTarget(name: "collab-bench", dependencies: ["CollabHarness"]),
        .testTarget(name: "CollabTests", dependencies: [
            "CollabCore", "CollabInvariants", "CollabSim", "CollabClientKit", "CollabStore", "CollabServer", "CollabDSL",
            .product(name: "PostgresNIO", package: "postgres-nio"),
            .product(name: "Configuration", package: "swift-configuration"),
            .product(name: "VaporTesting", package: "vapor"),
        ]),
    ]
)
