#if TRAILMESH_DEVELOPMENT
import SwiftUI
import TrailMeshMaps

/// Diagnostic inputs are explicit. No catalog pin is invented for unbuilt data.
struct MapDevelopmentView: View {
    @State private var directory = ""
    @State private var manifestHash = ""
    @State private var regionID = "rila"
    @State private var revision = ""
    @State private var query = ""
    @State private var status = "No offline region installed"
    @State private var installed: InstalledRegion?
    @State private var places: [Place] = []
    @State private var image: UIImage?
    @State private var busy = false
    @State private var installing = false
    @State private var start: Place?
    @State private var finish: Place?
    @State private var selectedRoute: HikingRoute?
    @State private var operation: Task<Void, Never>?
    @State private var cancellation = InstallCancellation()
    @State private var store = RegionStore(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OfflineRegions"))
    var body: some View {
        Form {
            Section("Offline backend diagnostics") {
                Text("Development only. Download a separately generated, trusted Rila pack. Routes and names then use local data. OSM coverage and conditions are not safety guarantees.")
                TextField("HTTPS release directory", text: $directory).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Pinned manifest SHA-256", text: $manifestHash).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Region ID", text: $regionID).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Installed revision", text: $revision).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Open installed region offline") { operation = Task { await openInstalled() } }.disabled(busy)
                Text("After restart, enter the region ID, revision and pinned hash to reopen saved data without a connection.")
                Button("Install verified region") { operation = Task { await install() } }.disabled(busy)
                Button("Cancel install") { cancellation.cancel(); operation?.cancel() }.disabled(!installing)
                Text(status).accessibilityAddTraits(.updatesFrequently)
            }
            if let installed {
                Section("Local places") {
                    Text(installed.manifest.attribution)
                    TextField("Search mountain names", text: $query)
                    Button("Search offline") { operation = Task { await search(installed) } }.disabled(busy)
                    ForEach(places, id: \.id) { place in
                        VStack(alignment: .leading) {
                            Text("\(place.name) · \(place.kind)")
                            HStack {
                                Button("Set start") { start = place }.buttonStyle(.borderless)
                                Button("Set finish") { finish = place }.buttonStyle(.borderless)
                            }.disabled(busy)
                        }
                    }
                    Text("Start: \(start?.name ?? "unset"); finish: \(finish?.name ?? "unset")")
                    Button("Calculate new route offline") { operation = Task { await route(installed) } }.disabled(start == nil || finish == nil || busy)
                    Button("Snapshot region center offline") { operation = Task { await snapshot(installed) } }.disabled(busy)
                    Text("Full geometry remains local. The relevance bridge explicitly rejects routes above 2048 points instead of truncating them.")
                }
            }
            if let image { Image(uiImage: image).resizable().scaledToFit() }
        }.navigationTitle("Offline maps")
            .onDisappear { cancellation.cancel(); operation?.cancel() }
    }
    @MainActor private func install() async {
        busy = true
        installing = true
        cancellation = InstallCancellation()
        defer { busy = false; installing = false }
        do {
            guard let url = URL(string: directory), url.scheme == "https" else { throw MapFailure.corrupt }
            let request = URLRequest(url: url.appendingPathComponent("manifest.json"))
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MapFailure.unavailable }
            var data = Data()
            for try await byte in bytes { try cancellation.check(); guard data.count < 262144 else { throw MapFailure.corrupt }; data.append(byte) }
            installed = try await store.install(manifestData: data, expectedSHA256: manifestHash, releaseDirectory: url, cancellation: cancellation)
            if let installed { regionID = installed.manifest.id; revision = installed.manifest.revision }
            start = nil; finish = nil; selectedRoute = nil; places = []; image = nil
            status = "Verified and saved locally. Disable networking before smoke checks."
        } catch { status = "Install failed: \(error)" }
    }
    @MainActor private func openInstalled() async {
        busy = true; defer { busy = false }
        do {
            installed = try await store.openInstalled(id: regionID, revision: revision, expectedSHA256: manifestHash)
            start = nil; finish = nil; selectedRoute = nil; places = []; image = nil
            status = "Reopened and revalidated installed region entirely offline."
        } catch { status = "Offline open failed: \(error)" }
    }
    @MainActor private func search(_ region: InstalledRegion) async {
        busy = true; defer { busy = false }
        do { places = try await store.search(query, in: region) }
        catch { status = "Search failed: \(error)" }
    }
    @MainActor private func snapshot(_ region: InstalledRegion) async {
        busy = true; defer { busy = false }
        do {
            let b = region.manifest.boundsE7
            let worker = OfflineMapSnapshot()
            image = try await worker.render(region: region, lease: try await store.lease(region), center: MapPoint(latE7: (b[1] + b[3]) / 2, lonE7: (b[0] + b[2]) / 2))
            status = "Snapshot rendered. Review trails, Cyrillic names and attribution visually."
        } catch { status = "Snapshot failed: \(error)" }
    }
    @MainActor private func route(_ region: InstalledRegion) async {
        guard let start, let finish else { return }
        busy = true; defer { busy = false }
        let router = OfflineHikingRouter()
        do {
            try await router.open(region, lease: try await store.lease(region))
            let result = try await router.route(from: MapPoint(latE7: start.latE7, lonE7: start.lonE7), to: MapPoint(latE7: finish.latE7, lonE7: finish.lonE7))
            selectedRoute = result
            do {
                _ = try result.reportRelevance()
                status = "Local route: \(result.distanceKm) km, \(result.points.count) points; relevance corridor accepted."
            } catch MapFailure.relevanceTooComplex {
                status = "Local route calculated (\(result.points.count) points); too complex for report relevance. Full geometry retained."
            }
        } catch { status = "Route failed: \(error)" }
        await router.close()
    }
}
#endif
