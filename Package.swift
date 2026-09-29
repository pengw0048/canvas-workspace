// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CanvasWorkspace",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CanvasWorkspace", targets: ["CanvasHost"]),
    ],
    dependencies: [
        .package(url: "https://github.com/automerge/automerge-swift", from: "0.7.2"),
    ],
    targets: [
        .target(
            name: "CanvasCore",
            dependencies: [.product(name: "Automerge", package: "automerge-swift")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "CanvasHost",
            dependencies: ["CanvasCore"]
        ),
        .testTarget(name: "CanvasCoreTests", dependencies: ["CanvasCore"]),
    ],
    swiftLanguageModes: [.v5]
)
