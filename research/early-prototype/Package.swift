// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DifyCollab",
    products: [
        .library(name: "CollabCore", targets: ["CollabCore"]),
        .library(name: "CollabSim", targets: ["CollabSim"]),
        .executable(name: "collab-sim", targets: ["collab-sim"]),
    ],
    targets: [
        // Pure protocol logic: document model, ops, server sequencer, client state machine. No I/O.
        .target(name: "CollabCore"),
        // Deterministic simulator: seeded PRNG, lossy network, fault injection, invariant oracle.
        .target(name: "CollabSim", dependencies: ["CollabCore"]),
        .executableTarget(name: "collab-sim", dependencies: ["CollabSim"]),
        .testTarget(name: "CollabTests", dependencies: ["CollabCore", "CollabSim"]),
    ]
)
