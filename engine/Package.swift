// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "passthru",
    platforms: [.macOS(.v14)],
    targets: [
        // Single owner of the Passthru control-plane client (discovery,
        // process facts, 'lapv' gain channel).
        .target(
            name: "GainChannel",
            path: "Sources/GainChannel"
        ),
        // Host-testable engine ring plus fill governor - pins pipeline
        // latency without audio hardware.
        .target(
            name: "LatencyCore",
            path: "Sources/LatencyCore"
        ),
        // Standalone CLI tool driving the driver's 'lapv' custom property
        // without any UI.
        .executableTarget(
            name: "PassthruGain",
            dependencies: ["GainChannel"],
            path: "Sources/PassthruGain"
        ),
        // Aggregate-lockstep probe (standalone, no UI). Verifies the
        // engine IOProc is in lockstep with the physical output's clock
        // domain when sitting on a private Core Audio aggregate.
        .executableTarget(
            name: "AggregateSpike",
            dependencies: ["GainChannel"],
            path: "Sources/AggregateSpike"
        ),
        // Engine-on-aggregate probe: same IOProc shape, but with the
        // engine's GovernedRing in the loop. Verifies the governor stays
        // dormant (drops/repeats/corrections = 0) when the ring sits on the
        // aggregate between capture and render. Built only after AggregateSpike
        // returns LOCKSTEP.
        .executableTarget(
            name: "EngineOnAggregate",
            dependencies: ["GainChannel", "LatencyCore"],
            path: "Sources/EngineOnAggregate"
        ),
        // Owns all UserDefaults-backed persistence. Siblings:
        // PersistedLastOutput (single-UID last-output store) and
        // PersistedGains (per-app gain store, 30-day expiry, 200-entry cap).
        // Shared `defaults: UserDefaults = .standard` injection. Host-
        // testable without dragging in the executable's SwiftUI surface.
        .target(
            name: "PassthruPersistence",
            path: "Sources/PassthruPersistence"
        ),
        .executableTarget(
            name: "Passthru",
            dependencies: ["GainChannel", "LatencyCore", "PassthruPersistence"],
            path: "Sources/Passthru"
        ),
        // Host-side tests for payload encode/decode and constants (no audio
        // hardware involved).
        .testTarget(
            name: "GainChannelTests",
            dependencies: ["GainChannel"],
            path: "Tests/GainChannelTests"
        ),
        // Governor policy and ring contract under injected rate mismatch.
        .testTarget(
            name: "LatencyCoreTests",
            dependencies: ["LatencyCore"],
            path: "Tests/LatencyCoreTests"
        ),
        // Single-UID last-output store round-trip and key isolation.
        .testTarget(
            name: "PassthruPersistenceTests",
            dependencies: ["PassthruPersistence"],
            path: "Tests/PassthruPersistenceTests"
        )
    ]
)
