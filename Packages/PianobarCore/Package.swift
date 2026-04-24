// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PianobarCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PianobarCore", targets: ["PianobarCore"]),
    ],
    targets: [
        .target(
            name: "PianobarCore",
            resources: [.copy("Resources/event_bridge.sh")]
        ),
        .testTarget(
            name: "PianobarCoreTests",
            dependencies: ["PianobarCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
