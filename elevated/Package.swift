// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "elevated",
    platforms: [.macOS("26.0"), .iOS("26.0"), .tvOS("26.0"), .visionOS("26.0")],
    products: [
        .library(name: "ElevatedCore",   targets: ["ElevatedCore"]),
        .library(name: "ElevatedMac",    targets: ["ElevatedMac"]),
        .library(name: "ElevatedIOS",    targets: ["ElevatedIOS"]),
        .library(name: "ElevatedTV",     targets: ["ElevatedTV"]),
        .library(name: "ElevatedVision", targets: ["ElevatedVision"]),
    ],
    targets: [
        // ── C synth (shared) ──────────────────────────────────────────────
        .target(
            name: "CSynth",
            path: "CSynth",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-O3", "-ffast-math"], .when(platforms: [.macOS])),
                .unsafeFlags(["-O3", "-ffast-math"], .when(platforms: [.iOS, .tvOS, .visionOS])),
            ],
            linkerSettings: [
                .linkedFramework("Accelerate")
            ]
        ),

        // ── Shared Metal renderer + sync + audio (macOS + iOS + tvOS) ─────
        .target(
            name: "ElevatedCore",
            dependencies: ["CSynth"],
            path: "ElevatedCore",
            exclude: [
                "SHADER_NOTES.md"
            ],
            resources: [
                .process("Shaders.metal"),
                .copy("ShadersBaseline.txt")
            ],
            swiftSettings: [
                .unsafeFlags(["-framework", "Metal",
                              "-framework", "MetalKit",
                              "-framework", "AVFoundation"])
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("AVFoundation"),
            ]
        ),

        // ── macOS app library (AppKit, debug overlay, transport bar) ─────
        .target(
            name: "ElevatedMac",
            dependencies: ["ElevatedCore"],
            path: "ElevatedMac",
            swiftSettings: [
                .unsafeFlags(["-framework", "Cocoa"])
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
            ]
        ),

        // ── macOS CLI executable (thin wrapper for `make app`) ───────────
        .executableTarget(
            name: "ElevatedMacCLI",
            dependencies: ["ElevatedMac"],
            path: "ElevatedMacCLI",
            swiftSettings: [
                .unsafeFlags(["-framework", "Cocoa"])
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
            ]
        ),

        // ── iOS/iPadOS app (UIKit, fullscreen playback) ───────────────────
        .target(
            name: "ElevatedIOS",
            dependencies: ["ElevatedCore"],
            path: "ElevatedIOS",
            swiftSettings: [
                .unsafeFlags(["-framework", "UIKit"])
            ],
            linkerSettings: [
                .linkedFramework("UIKit"),
            ]
        ),

        // ── tvOS app (UIKit, fullscreen, loops on end) ────────────────────
        .target(
            name: "ElevatedTV",
            dependencies: ["ElevatedCore"],
            path: "ElevatedTV",
            swiftSettings: [
                .unsafeFlags(["-framework", "UIKit"])
            ],
            linkerSettings: [
                .linkedFramework("UIKit"),
            ]
        ),

        // ── visionOS app (UIKit window, loops on end) ─────────────────────
        .target(
            name: "ElevatedVision",
            dependencies: ["ElevatedCore"],
            path: "ElevatedVision",
            swiftSettings: [
                .unsafeFlags(["-framework", "UIKit"])
            ],
            linkerSettings: [
                .linkedFramework("UIKit"),
            ]
        ),

        // ── Tests ────────────────────────────────────────────────────────
        .testTarget(
            name: "ElevatedCoreTests",
            dependencies: ["ElevatedCore"],
            path: "Tests/ElevatedCoreTests"
        ),
    ]
)
