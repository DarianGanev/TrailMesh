// swift-tools-version: 6.1
import PackageDescription

let routingBinary: Target =
    Context.environment["TRAILMESH_LOCAL_ROUTING_SDK"] == "1"
    ? .binaryTarget(name: "TrailMeshValhalla", path: "Artifacts/TrailMeshValhalla.xcframework")
    : .binaryTarget(
        name: "TrailMeshValhalla",
        url: "https://github.com/DarianGanev/TrailMesh/releases/download/ios-router-valhalla-0.6.6-v1/TrailMeshValhalla.xcframework.zip",
        checksum: "becc4a307412edd01bb432863113c92cf36fdebefc81caa995a5e1def019145b"
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
