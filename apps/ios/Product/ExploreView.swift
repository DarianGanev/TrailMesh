import MapLibre
import SwiftUI

struct ExploreView: View {
    @State private var model = ExploreModel()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var showingCredits = false
    @State private var confirmingReplacement = false
    @State private var overviewRequest = 0
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
                        detail: "About 64 MB. Once downloaded, the map works without internet.",
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
        return InteractiveRilaMap(
            resources: resources, overviewRequest: overviewRequest,
            onLoaded: { loadedStyleURL = resources.styleURL },
            onFailure: { model.mapDidFail(resources) }
        )
        .id(resources.styleURL)
        .overlay(alignment: .topTrailing) {
            Button {
                overviewRequest += 1
            } label: {
                Label("Show Rila overview", systemImage: "scope")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!mapLoaded)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .padding(12)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            let layout = textSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                : AnyLayout(HStackLayout(spacing: 12))
            layout {
                if mapLoaded {
                    Label("Rila available offline", systemImage: "checkmark.circle")
                } else {
                    ProgressView("Opening Rila")
                }
                if !textSize.isAccessibilitySize { Spacer(minLength: 0) }
                Button {
                    showingCredits = true
                } label: {
                    Text("© OpenStreetMap").frame(minHeight: 44)
                }
                .accessibilityHint("Opens map credits")
            }
            .font(.footnote)
            .padding(.horizontal, 16)
            .background(.background)
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

private struct InteractiveRilaMap: UIViewRepresentable {
    let resources: ExploreMapResources
    let overviewRequest: Int
    let onLoaded: () -> Void
    let onFailure: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(resources: resources, overviewRequest: overviewRequest, onLoaded: onLoaded, onFailure: onFailure)
    }

    func makeUIView(context: Context) -> MLNMapView {
        OfflineHTTPBlocker.configureRenderer()
        let map = MLNMapView(frame: .zero, styleURL: resources.styleURL)
        map.delegate = context.coordinator
        map.minimumZoomLevel = 8
        map.maximumZoomLevel = Double(resources.region.manifest.maxZoom) + 2
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        let trailArea = CLLocationCoordinate2D(latitude: 42.181, longitude: 23.369)
        map.setCenter(trailArea, zoomLevel: 11.6, animated: false)
        map.showsAttributionButton = false
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        guard context.coordinator.overviewRequest != overviewRequest else { return }
        context.coordinator.overviewRequest = overviewRequest
        showOverview(on: map)
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
        var overviewRequest: Int

        init(resources: ExploreMapResources, overviewRequest: Int, onLoaded: @escaping () -> Void, onFailure: @escaping () -> Void) {
            self.resources = resources
            self.overviewRequest = overviewRequest
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
