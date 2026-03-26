// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "elevated",
    platforms: [.macOS(.v13), .iOS("26.0"), .tvOS("26.0"), .visionOS("2.0")],
    products: [
        .library(name: "ElevatedCore",   targets: ["ElevatedCore"]),
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
                .unsafeFlags(["-O3", "-ffast-math", "-march=native"], .when(platforms: [.macOS])),
                .unsafeFlags(["-O3", "-ffast-math"],                  .when(platforms: [.iOS, .tvOS, .visionOS])),
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
            resources: [
                .process("Shaders.metal")
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

        // ── macOS app (AppKit, debug overlay, transport bar) ──────────────
        .executableTarget(
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
    ]
)
