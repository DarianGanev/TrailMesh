import MapLibre
import SwiftUI
import TrailMeshMaps

struct ExploreView: View {
    @State private var model = ExploreModel()
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingCredits = false
    @State private var creditedStyleURL: URL?
    @State private var showingSearch = false
    @State private var selectedPlace: Place?
    @State private var confirmingReplacement = false
    @State private var cameraRequest: ExploreCameraRequest?
    @State private var loadedStyleURL: URL?
    #if TRAILMESH_DEVELOPMENT
    @Environment(\.scenePhase) private var phase
    @StateObject private var diagnostics = ReportDevelopmentModel()
    @State private var showingDiagnostics = false
    #endif

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .checking:
                    ProgressView("Opening Rila")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .needsDownload:
                    messagePage(
                        title: "Rila · Рила",
                        detail: "Hiking trails, huts and peaks on a map you can use offline. About 64 MB.",
                        action: "Download Rila"
                    ) { model.download() }
                case .downloading:
                    VStack(alignment: .leading, spacing: 20) {
                        ProgressView("Downloading and checking map files")
                        Button("Cancel download", role: .cancel) { model.cancel() }
                            .frame(minHeight: 44)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(24)
                case .ready(let resources):
                    mapPage(resources)
                case .needsRepair(let message):
                    messagePage(
                        title: "Rila needs a new download",
                        detail: message,
                        action: "Replace download"
                    ) { confirmingReplacement = true }
                case .downloadFailed(let message):
                    messagePage(title: "Rila couldn’t download", detail: message, action: "Try again") {
                        model.download()
                    }
                case .mapFailed:
                    messagePage(title: "Rila couldn’t open", detail: "Try opening the saved map again.", action: "Reopen map") {
                        Task { await model.reopen() }
                    }
                }
            }
            .background(surface)
            .navigationTitle("Explore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(showsMap ? .hidden : .visible, for: .navigationBar)
            .task { await model.reopen() }
            .confirmationDialog("Replace the saved Rila map?", isPresented: $confirmingReplacement, titleVisibility: .visible) {
                Button("Replace and download", role: .destructive) { model.download(replacing: true) }
            } message: {
                Text("TrailMesh will remove the saved copy before downloading a replacement.")
            }
            #if TRAILMESH_DEVELOPMENT
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Developer tools", systemImage: "ellipsis.circle") {
                        Button("Research diagnostics") { showingDiagnostics = true }
                    }
                }
            }
            .sheet(isPresented: $showingDiagnostics, onDismiss: refreshAfterDiagnostics) {
                ReportDevelopmentView(model: diagnostics)
            }
            .onChange(of: phase, initial: true) { _, value in diagnostics.setForeground(value == .active) }
            #endif
        }
    }

    private var showsMap: Bool {
        if case .ready = model.state { return true }
        return false
    }

    #if TRAILMESH_DEVELOPMENT
    private func refreshAfterDiagnostics() {
        if case .ready = model.state { return }
        Task { await model.reopen() }
    }
    #endif

    private var surface: Color {
        colorScheme == .light ? Color(red: 0.99, green: 0.98, blue: 0.95) : Color(uiColor: .systemBackground)
    }

    private func mapPage(_ resources: ExploreMapResources) -> some View {
        let mapLoaded = loadedStyleURL == resources.styleURL
        return ZStack {
            InteractiveRilaMap(
                resources: resources, cameraRequest: cameraRequest,
                onLoaded: { loadedStyleURL = resources.styleURL },
                onFailure: { model.mapDidFail(resources) }
            )
            .id(resources.styleURL)
            .ignoresSafeArea()
        }
        .overlay(alignment: .topTrailing) {
            #if TRAILMESH_DEVELOPMENT
            Menu {
                Button("Research diagnostics") { showingDiagnostics = true }
            } label: {
                Label("Developer tools", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .exploreGlass(in: Circle())
            }
            .foregroundStyle(.primary)
            .padding(12)
            #endif
        }
        .overlay(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                if !mapLoaded {
                    ProgressView("Opening map…")
                        .padding(12)
                        .background(.regularMaterial, in: Capsule())
                }
                if let selectedPlace {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(selectedPlace.name)
                                .font(.title3.bold())
                            Text(ExplorePlaceSearch.kindName(selectedPlace.kind))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button {
                            self.selectedPlace = nil
                        } label: {
                            Label("Dismiss place", systemImage: "xmark")
                                .labelStyle(.iconOnly)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 8)
                    .padding(.vertical, 8)
                    .background(.background, in: RoundedRectangle(cornerRadius: 22))
                    .accessibilityElement(children: .contain)
                }
                HStack(spacing: 8) {
                    Button {
                        showingSearch = true
                    } label: {
                        Label("Search Rila", systemImage: "magnifyingglass")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            .padding(.horizontal, 16)
                            .exploreGlass(in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!mapLoaded)

                    Menu {
                        Button("Rila overview", systemImage: "viewfinder") {
                            selectedPlace = nil
                            cameraRequest = ExploreCameraRequest(command: .overview)
                        }
                        Button("Zoom in", systemImage: "plus.magnifyingglass") {
                            cameraRequest = ExploreCameraRequest(command: .zoom(1))
                        }
                        Button("Zoom out", systemImage: "minus.magnifyingglass") {
                            cameraRequest = ExploreCameraRequest(command: .zoom(-1))
                        }
                    } label: {
                        Label("Map controls", systemImage: "slider.horizontal.3")
                            .labelStyle(.iconOnly)
                            .frame(width: 48, height: 48)
                            .exploreGlass(in: Circle())
                    }
                    .foregroundStyle(.primary)
                    .disabled(!mapLoaded)
                }
                Button {
                    showingCredits = true
                } label: {
                    Group {
                        if creditedStyleURL == resources.styleURL {
                            Image(systemName: "info.circle")
                                .font(.body)
                        } else {
                            Text("© OpenStreetMap")
                                .font(.caption)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(creditedStyleURL == resources.styleURL ? "Map credits" : "© OpenStreetMap")
                .accessibilityHint("Opens map credits")
            }
            .padding(.horizontal, 16)
        }
        .task(id: mapLoaded) {
            guard mapLoaded, creditedStyleURL != resources.styleURL else { return }
            do {
                try await Task.sleep(for: .seconds(5))
                creditedStyleURL = resources.styleURL
            } catch {}
        }
        .sheet(isPresented: $showingSearch) {
            ExplorePlaceSearch(index: resources.places) { place in
                selectedPlace = place
                cameraRequest = ExploreCameraRequest(command: .place(place))
                showingSearch = false
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingCredits) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(resources.region.manifest.attribution)
                        Link("OpenStreetMap licence", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                }
                .navigationTitle("Map credits")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingCredits = false }
                    }
                }
            }
        }
    }

    private func messagePage(title: String, detail: String, action: String, perform: @escaping () -> Void) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.system(.largeTitle, design: .serif).weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: perform) {
                    Text(action)
                        .fontWeight(.semibold)
                        .frame(minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.12, green: 0.32, blue: 0.65))
            }
            .frame(maxWidth: 420, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 40)
        }
    }
}

private extension View {
    @ViewBuilder
    func exploreGlass<S: Shape>(in shape: S) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
        #else
        background(.regularMaterial, in: shape)
        #endif
    }
}

private struct ExplorePlaceSearch: View {
    let index: PlaceIndex
    let select: (Place) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Place] = []

    var body: some View {
        NavigationStack {
            Group {
                if results.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "Find a place in Rila" : "No matching places",
                        systemImage: "magnifyingglass",
                        description: Text(query.isEmpty ? "Try a hut, summit, or trailhead." : "Try another name.")
                    )
                } else {
                    List(results, id: \.id) { place in
                        Button {
                            select(place)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(place.name)
                                Text(Self.kindName(place.kind))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("Find a place")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Rila")
            .task(id: query) {
                let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !term.isEmpty else {
                    results = []
                    return
                }
                do {
                    try await Task.sleep(for: .milliseconds(120))
                    let matches = await Task.detached { [index] in index.search(term) }.value
                    try Task.checkCancellation()
                    results = matches
                } catch {}
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    static func kindName(_ kind: String) -> String {
        switch kind {
        case "hut": "Hut"
        case "peak": "Summit"
        case "shelter": "Shelter"
        case "water": "Water"
        case "trailhead": "Trailhead"
        default: "Place"
        }
    }
}

private enum ExploreCameraCommand {
    case overview
    case place(Place)
    case zoom(Double)
}

private struct ExploreCameraRequest {
    let id = UUID()
    let command: ExploreCameraCommand
}

private struct InteractiveRilaMap: UIViewRepresentable {
    let resources: ExploreMapResources
    let cameraRequest: ExploreCameraRequest?
    let onLoaded: () -> Void
    let onFailure: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(resources: resources, cameraRequestID: cameraRequest?.id, onLoaded: onLoaded, onFailure: onFailure)
    }

    func makeUIView(context: Context) -> MLNMapView {
        OfflineHTTPBlocker.configureRenderer()
        let map = MLNMapView(frame: .zero, styleURL: resources.styleURL)
        map.delegate = context.coordinator
        map.minimumZoomLevel = 8
        map.maximumZoomLevel = Double(resources.region.manifest.maxZoom) + 2
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.showsLogoView = false
        let trailArea = CLLocationCoordinate2D(latitude: 42.181, longitude: 23.369)
        map.setCenter(trailArea, zoomLevel: 12.3, animated: false)
        map.showsAttributionButton = false
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        guard let cameraRequest, context.coordinator.cameraRequestID != cameraRequest.id else { return }
        context.coordinator.cameraRequestID = cameraRequest.id
        switch cameraRequest.command {
        case .overview: showOverview(on: map)
        case .place(let place):
            map.setCenter(
                CLLocationCoordinate2D(latitude: Double(place.latE7) / 1e7, longitude: Double(place.lonE7) / 1e7),
                zoomLevel: max(map.zoomLevel, 13.5),
                animated: !UIAccessibility.isReduceMotionEnabled
            )
        case .zoom(let step): map.zoomLevel += step
        }
    }

    private func showOverview(on map: MLNMapView) {
        let bounds = resources.region.manifest.boundsE7.map { Double($0) / 1e7 }
        map.setVisibleCoordinateBounds(
            MLNCoordinateBounds(
                sw: CLLocationCoordinate2D(latitude: bounds[1], longitude: bounds[0]),
                ne: CLLocationCoordinate2D(latitude: bounds[3], longitude: bounds[2])
            ),
            edgePadding: UIEdgeInsets(top: 24, left: 20, bottom: 24, right: 20),
            animated: false,
            completionHandler: nil
        )
    }

    static func dismantleUIView(_ map: MLNMapView, coordinator: Coordinator) {
        map.delegate = nil
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        private let resources: ExploreMapResources
        private let onLoaded: () -> Void
        private let onFailure: () -> Void
        var cameraRequestID: UUID?

        init(resources: ExploreMapResources, cameraRequestID: UUID?, onLoaded: @escaping () -> Void, onFailure: @escaping () -> Void) {
            self.resources = resources
            self.cameraRequestID = cameraRequestID
            self.onLoaded = onLoaded
            self.onFailure = onFailure
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            let configuration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            for (name, symbol) in [("trailmesh-hut", "house.fill"), ("trailmesh-peak", "mountain.2.fill")] {
                if let icon = UIImage(systemName: symbol, withConfiguration: configuration) {
                    style.setImage(icon.withTintColor(.black, renderingMode: .alwaysOriginal), forName: name)
                }
            }
        }

        func mapViewDidFinishLoadingMap(_ mapView: MLNMapView) {
            DispatchQueue.main.async { self.onLoaded() }
        }

        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            DispatchQueue.main.async { self.onFailure() }
        }
    }
}
