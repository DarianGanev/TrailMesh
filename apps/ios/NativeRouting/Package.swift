// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "TrailMeshNativeRouting",
    platforms: [.iOS("16.4")],
    products: [.library(name: "TrailMeshNativeRouting", targets: ["TrailMeshNativeRouting"])],
    targets: [
        .binaryTarget(name: "TrailMeshValhalla", path: "Artifacts/TrailMeshValhalla.xcframework"),
        .target(name: "TrailMeshNativeRouting", dependencies: ["TrailMeshValhalla"], resources: [.copy("Resources/default.json")])
    ]
)
