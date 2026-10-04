// swift-tools-version:5.9
import PackageDescription

// The sand simulation, container shapes, palettes and renderer, kept out of the app so they can be
// tested with `swift test` and previewed on the Mac (`swift run sandpreview`) without a watch.
let package = Package(
    name: "HourGlassCore",
    platforms: [.watchOS(.v10), .macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "HourGlassCore", targets: ["HourGlassCore"]),
    ],
    targets: [
        .target(
            name: "HourGlassCore",
            swiftSettings: [
                // The simulation moves thousands of grains 60 times a second; even Debug builds on
                // the watch need the optimizer to keep up.
                .unsafeFlags(["-O"]),
            ]
        ),
        // Renders scripted scenes to PNG and GIF, and benchmarks the simulation.
        .executableTarget(name: "sandpreview", dependencies: ["HourGlassCore"]),
        .testTarget(name: "HourGlassCoreTests", dependencies: ["HourGlassCore"]),
    ]
)
