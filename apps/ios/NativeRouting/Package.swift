// swift-tools-version: 6.1
import PackageDescription

let routingBinary: Target =
    Context.environment["TRAILMESH_LOCAL_ROUTING_SDK"] == "1"
    ? .binaryTarget(name: "TrailMeshValhalla", path: "Artifacts/TrailMeshValhalla.xcframework")
    : .binaryTarget(
        name: "TrailMeshValhalla",
        url: "https://github.com/DarianGanev/TrailMesh/releases/download/ios-router-valhalla-0.6.6-v2/TrailMeshValhalla.xcframework.zip",
        checksum: "b939d08fe0301608fd5d78922a2fae6ae62de7bf9e216f67e8e52c19f3cb069e"
    )
let package = Package(
    name: "TrailMeshNativeRouting",
    platforms: [.iOS("17.0")],
    products: [.library(name: "TrailMeshNativeRouting", targets: ["TrailMeshNativeRouting"])],
    targets: [
        routingBinary,
        .target(name: "TrailMeshNativeRouting", dependencies: ["TrailMeshValhalla"], resources: [.copy("Resources/default.json")])
    ]
)
