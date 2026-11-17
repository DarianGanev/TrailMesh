// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "TrailMeshReports",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "TrailMeshReports", targets: ["TrailMeshReports"]), .library(name: "TrailMeshMaps", targets: ["TrailMeshMaps"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")
    ],
    targets: [
        .systemLibrary(name: "CMapZlib", pkgConfig: "zlib"),
        .target(name: "TrailMeshMaps", dependencies: ["CMapZlib"]),
        .testTarget(name: "TrailMeshMapsTests", dependencies: ["TrailMeshMaps"], resources: [.copy("Fixtures/region-v1-vectors.json")]),
        .target(name: "TrailMeshReports", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "TrailMeshReportsTests", dependencies: ["TrailMeshReports", .product(name: "GRDB", package: "GRDB.swift")], resources: [.copy("Fixtures/report-v1-vectors.json"), .copy("Fixtures/exchange-v1-vectors.json"), .copy("Fixtures/relevance-v1-vectors.json"), .copy("Fixtures/session-v1-profile.json")])
    ]
)
