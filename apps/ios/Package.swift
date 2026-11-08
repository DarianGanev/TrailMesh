// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "TrailMeshReports",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "TrailMeshReports", targets: ["TrailMeshReports"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")
    ],
    targets: [
        .target(name: "TrailMeshReports", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "TrailMeshReportsTests", dependencies: ["TrailMeshReports", .product(name: "GRDB", package: "GRDB.swift")], resources: [.copy("Fixtures/report-v1-vectors.json"), .copy("Fixtures/exchange-v1-vectors.json")])
    ]
)
