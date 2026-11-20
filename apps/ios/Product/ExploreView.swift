import MapLibre
import SwiftUI

struct ExploreView: View {
    @State private var model = ExploreModel()
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingCredits = false
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
        .overlay(alignment: .top) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rila").font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(mapLoaded ? "Saved offline" : "Opening map…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(surface, in: RoundedRectangle(cornerRadius: 12))

                Spacer(minLength: 0)
                #if TRAILMESH_DEVELOPMENT
                Menu {
                    Button("Research diagnostics") { showingDiagnostics = true }
                } label: {
                    Label("Developer tools", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(.primary)
                .background(surface, in: RoundedRectangle(cornerRadius: 12))
                #endif
            }
            .padding(12)
        }
        .overlay(alignment: .bottom) {
            HStack(alignment: .bottom, spacing: 12) {
                Button {
                    showingCredits = true
                } label: {
                    Text("© OpenStreetMap")
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(surface, in: RoundedRectangle(cornerRadius: 6))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens map credits")
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    mapButton("Show Rila overview", icon: "viewfinder", command: .overview)
                    Divider()
                    mapButton("Zoom in", icon: "plus", command: .zoom(1))
                    Divider()
                    mapButton("Zoom out", icon: "minus", command: .zoom(-1))
                }
                .frame(width: 44)
                .background(surface, in: RoundedRectangle(cornerRadius: 12))
                .disabled(!mapLoaded)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .sheet(isPresented: $showingCredits) {
            NavigationStack {
                ScrollView {
                    Text(resources.region.manifest.attribution)
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

    private func mapButton(_ title: String, icon: String, command: ExploreCameraCommand) -> some View {
        Button {
            cameraRequest = ExploreCameraRequest(command: command)
        } label: {
            Label(title, systemImage: icon)
                .labelStyle(.iconOnly)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                .tint(Color(red: 0.14, green: 0.27, blue: 0.18))
            }
            .frame(maxWidth: 420, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 40)
        }
    }
}

private enum ExploreCameraCommand {
    case overview
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
        map.setCenter(trailArea, zoomLevel: 11.6, animated: false)
        map.showsAttributionButton = false
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        guard let cameraRequest, context.coordinator.cameraRequestID != cameraRequest.id else { return }
        context.coordinator.cameraRequestID = cameraRequest.id
        switch cameraRequest.command {
        case .overview: showOverview(on: map)
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

        func mapViewDidFinishLoadingMap(_ mapView: MLNMapView) {
            DispatchQueue.main.async { self.onLoaded() }
        }

        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            DispatchQueue.main.async { self.onFailure() }
        }
    }
}
