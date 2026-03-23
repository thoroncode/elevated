// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ElevatedMac",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CSynth",
            path: "CSynth",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-O2"])
            ]
        ),
        .executableTarget(
            name: "ElevatedMac",
            dependencies: ["CSynth"],
            path: "ElevatedMac",
            resources: [
                .process("Shaders.metal")
            ],
            swiftSettings: [
                .unsafeFlags(["-framework", "Metal",
                              "-framework", "MetalKit",
                              "-framework", "Cocoa",
                              "-framework", "AVFoundation"])
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Cocoa"),
                .linkedFramework("AVFoundation"),
            ]
        )
    ]
)
