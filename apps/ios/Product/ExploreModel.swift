import Foundation
import Observation
import TrailMeshMaps

enum RilaRegion {
    static let releaseDirectory = URL(string: "https://github.com/DarianGanev/TrailMesh/releases/download/maps-rila-osm-2026-11-16-v1/")!
    static let manifestHash = "862f354fa7ee81ba88c841767773607efc91f5c875c564e9faedcb196ac2c10f"
    static let id = "rila"
    static let revision = "osm-2026-11-16-v1"

    static func makeStore() -> RegionStore {
        let root = URL.applicationSupportDirectory.appendingPathComponent("OfflineRegions")
        return RegionStore(root: root)
    }
}

/// Keeps both the temporary style and the verified files alive for the native map.
final class ExploreMapResources: Sendable {
    let region: InstalledRegion
    let styleURL: URL
    let places: PlaceIndex
    private let lease: PackLease

    init(region: InstalledRegion, lease: PackLease) throws {
        let style = try LocalStyle.resolve(
            Data(contentsOf: region.root.appendingPathComponent("style.json")),
            root: region.root,
            files: Set(region.manifest.files.map(\.path))
        )
        places = try PlaceIndex(data: Data(contentsOf: region.root.appendingPathComponent("places.json")))
        styleURL = URL.temporaryDirectory.appendingPathComponent("trailmesh-explore-\(UUID().uuidString).json")
        try Self.exploreStyle(style).write(to: styleURL, options: .atomic)
        self.region = region
        self.lease = lease
    }

    // Presentation changes are applied only after resolving the verified local sources.
    private static func exploreStyle(_ resolved: Data) throws -> Data {
        guard var style = try JSONSerialization.jsonObject(with: resolved) as? [String: Any],
              let layers = style["layers"] as? [[String: Any]] else { return resolved }
        style["layers"] = layers.map { source in
            var layer = source
            var paint = layer["paint"] as? [String: Any] ?? [:]
            switch layer["id"] as? String {
            case "mountain-relief":
                paint["hillshade-shadow-color"] = "#586664"
                paint["hillshade-exaggeration"] = 0.49
            case "footpaths":
                paint["line-color"] = "#4b5350"
            case "streams":
                paint["line-color"] = "#357f9e"
            case "huts", "peaks":
                guard var layout = layer["layout"] as? [String: Any] else { return source }
                if let field = layout["text-field"] as? [Any], field.count == 3,
                   field.first as? String == "concat" {
                    layout["text-field"] = field[2]
                }
                layout["icon-image"] = (layer["id"] as? String) == "huts" ? "trailmesh-hut" : "trailmesh-peak"
                layout["text-anchor"] = "left"
                layout["text-offset"] = [0.8, 0]
                layout["text-optional"] = true
                paint["text-color"] = "#252c26"
                layer["layout"] = layout
            default:
                return source
            }
            layer["paint"] = paint
            return layer
        }
        return try JSONSerialization.data(withJSONObject: style, options: [.sortedKeys])
    }

    deinit { try? FileManager.default.removeItem(at: styleURL) }
}

@MainActor
@Observable
final class ExploreModel {
    enum State {
        case checking
        case needsDownload
        case downloading
        case ready(ExploreMapResources)
        case needsRepair(String)
        case downloadFailed(String)
        case mapFailed
    }

    private let store: RegionStore
    private let manifestHash: String
    private(set) var state: State = .checking
    @ObservationIgnored private var opening = false
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var cancellation: InstallCancellation?

    init(store: RegionStore = RilaRegion.makeStore(), manifestHash: String = RilaRegion.manifestHash) {
        self.store = store
        self.manifestHash = manifestHash
    }

    func reopen() async {
        guard operation == nil, !opening else { return }
        opening = true
        defer { opening = false }
        state = .checking
        do {
            let region = try await store.openInstalled(
                id: RilaRegion.id, revision: RilaRegion.revision, expectedSHA256: manifestHash
            )
            await prepareMap(region)
        } catch MapFailure.unavailable {
            state = .needsDownload
        } catch MapFailure.corrupt {
            state = .needsRepair("The saved map couldn’t be verified.")
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            state = .needsRepair("Part of the saved map is missing.")
        } catch {
            state = .mapFailed
        }
    }

    func download(replacing: Bool = false) {
        guard operation == nil, !opening else { return }
        state = .downloading
        let token = InstallCancellation()
        cancellation = token
        operation = Task {
            defer { operation = nil; cancellation = nil }
            var needsReplacement = replacing
            do {
                let manifest = try await HTTPSPackTransport().fetchManifest(from: RilaRegion.releaseDirectory, cancellation: token)
                _ = try RegionManifest.parse(manifest, expectedSHA256: manifestHash)
                try token.check()
                if replacing {
                    do { try await store.remove(id: RilaRegion.id, revision: RilaRegion.revision) }
                    catch MapFailure.unavailable {}
                    needsReplacement = false
                }
                let region = try await store.install(
                    manifestData: manifest, expectedSHA256: manifestHash,
                    releaseDirectory: RilaRegion.releaseDirectory, cancellation: token
                )
                await prepareMap(region)
            } catch MapFailure.space {
                downloadDidFail("Free up some storage, then try again.", needsReplacement: needsReplacement)
            } catch MapFailure.corrupt {
                downloadDidFail("The download couldn’t be verified. Try again.", needsReplacement: needsReplacement)
            } catch MapFailure.busy {
                downloadDidFail("Close other views using Rila, then try again.", needsReplacement: needsReplacement)
            } catch {
                if Task.isCancelled || (error as? MapFailure) == .cancelled {
                    state = needsReplacement ? .needsRepair("The saved map couldn’t be verified.") : .needsDownload
                } else {
                    downloadDidFail("Check your connection, then try again.", needsReplacement: needsReplacement)
                }
            }
        }
    }

    func cancel() {
        cancellation?.cancel()
        operation?.cancel()
    }

    func mapDidFail(_ resources: ExploreMapResources) {
        guard case .ready(let current) = state, current === resources else { return }
        state = .mapFailed
    }

    private func downloadDidFail(_ message: String, needsReplacement: Bool) {
        state = needsReplacement ? .needsRepair(message) : .downloadFailed(message)
    }

    private func prepareMap(_ region: InstalledRegion) async {
        do {
            let lease = try await store.lease(region)
            let resources = try await Task.detached(priority: .userInitiated) {
                try ExploreMapResources(region: region, lease: lease)
            }.value
            state = .ready(resources)
        } catch {
            state = .mapFailed
        }
    }
}
