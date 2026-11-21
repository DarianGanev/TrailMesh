import CoreLocation
import MapLibre
import SwiftUI
import TrailMeshMaps
import TrailMeshReports

struct ExploreView: View {
    private enum ReportDestination: Identifiable {
        case list, compose, details(StoredReport)
        var id: String {
            switch self {
            case .list: "reports"
            case .compose: "compose"
            case .details(let report): report.bundleID
            }
        }
    }

    @State private var model = ExploreModel()
    @State private var route = ExploreRoute()
    @State private var location = ExploreLocation()
    @State private var showingRoutes = false
    @State private var followsHikePosition = true
    @State private var locating = false
    @State private var locationNotice: String?
    @State private var reports = ExploreReports()
    @State private var reportDraft = ExploreReportDraft()
    @State private var reportDestination: ReportDestination?
    @State private var pickingReportLocation = false
    @State private var pickCenterRequest: UUID?
    @State private var reportNotice: String?
    @State private var reportClock = Date.now
    @State private var showingOfflineMaps = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingCredits = false
    @State private var creditedStyleURL: URL?
    @State private var showingSearch = false
    @State private var selectedPlace: Place?
    @State private var confirmingReplacement = false
    @State private var cameraRequest: ExploreCameraRequest?
    @State private var loadedStyleURL: URL?
    #if TRAILMESH_DEVELOPMENT
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
            .onChange(of: scenePhase) { _, phase in
                location.follow(phase == .active && route.navigating)
                if phase == .active, case .ready(let resources) = model.state {
                    Task { await reports.page(in: resources.region.manifest) }
                }
            }
            .onChange(of: showsMap) { _, ready in
                if !ready {
                    clearRoute()
                    pickingReportLocation = false
                }
            }
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
            .onChange(of: scenePhase, initial: true) { _, value in diagnostics.setForeground(value == .active) }
            #endif
        }
    }

    private var showsMap: Bool {
        if case .ready = model.state { return true }
        return false
    }

    #if TRAILMESH_DEVELOPMENT
    private func refreshAfterDiagnostics() {
        if case .ready(let resources) = model.state {
            Task { await reports.page(in: resources.region.manifest) }
            return
        }
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
                route: route.result, routeID: route.geometryID,
                currentPosition: location.recentFix.flatMap { MapPoint(coordinate: $0.coordinate) },
                reports: reports.entries.filter { ExploreReports.current($0, at: reportClock) },
                pickingReportLocation: pickingReportLocation,
                pickCenterRequest: pickCenterRequest,
                onReport: { reportDestination = .details($0) },
                onPickReportLocation: { point in
                    guard resources.region.manifest.contains(point) else {
                        reportNotice = "Pick a point within the downloaded map."
                        return
                    }
                    reportDraft.position = .init(point: point, accuracy: 100, isGPS: false)
                    reportNotice = nil
                    pickingReportLocation = false
                    pickCenterRequest = nil
                    reportDestination = .compose
                },
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
                if pickingReportLocation {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tap the map at the observation").font(.headline)
                        if let reportNotice { Text(reportNotice).font(.subheadline) }
                        Button("Use map center") { pickCenterRequest = UUID() }
                            .frame(minHeight: 44)
                        Button("Back to report") {
                            pickingReportLocation = false
                            pickCenterRequest = nil
                            reportNotice = nil
                            reportDestination = .compose
                        }
                        .frame(minHeight: 44)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.background, in: RoundedRectangle(cornerRadius: 16))
                } else if route.result != nil {
                    routeCard
                } else if let selectedPlace {
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
                            showingRoutes = true
                        } label: {
                            Label("Plan a route here", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                                .labelStyle(.iconOnly)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.borderless)
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
                if let locationNotice, !pickingReportLocation {
                    HStack {
                        Text(locationNotice).font(.subheadline)
                        Spacer(minLength: 0)
                        Button {
                            self.locationNotice = nil
                        } label: {
                            Image(systemName: "xmark").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Dismiss location message")
                    }
                    .padding(.leading, 12)
                    .background(.background, in: RoundedRectangle(cornerRadius: 16))
                }
                if let reportNotice, !pickingReportLocation {
                    Text(reportNotice)
                        .font(.subheadline)
                        .padding(12)
                        .background(.background, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityAddTraits(.updatesFrequently)
                        .onTapGesture { self.reportNotice = nil }
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
                        Button("My location", systemImage: "location") {
                            locationNotice = nil
                            if let fix = location.recentFix, let point = MapPoint(coordinate: fix.coordinate) {
                                cameraRequest = ExploreCameraRequest(command: .location(point))
                            } else {
                                locating = true
                                location.requestFix()
                                if let issue = location.issue { showLocationIssue(issue) }
                            }
                        }
                        Button("Offline maps", systemImage: "arrow.down.circle") { showingOfflineMaps = true }
                        Button("New report", systemImage: "plus") {
                            reportNotice = nil
                            reportDraft = ExploreReportDraft()
                            reportDestination = .compose
                        }
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
                .disabled(pickingReportLocation)
                if !pickingReportLocation {
                    ViewThatFits {
                        HStack(spacing: 12) { fieldActions(resources) }
                        VStack(alignment: .leading, spacing: 4) { fieldActions(resources) }
                    }
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
        .task(id: resources.styleURL) {
            await reports.page(in: resources.region.manifest)
            while !Task.isCancelled {
                guard (try? await Task.sleep(for: .seconds(15))) != nil else { return }
                reportClock = .now
            }
        }
        .sheet(isPresented: $showingOfflineMaps) { offlineMaps(resources.region.manifest) }
        .onChange(of: location.fix) { _, fix in
            guard locating || (route.navigating && followsHikePosition),
                  let fix, location.recentFix != nil,
                  let point = MapPoint(coordinate: fix.coordinate) else { return }
            cameraRequest = ExploreCameraRequest(command: .location(point))
            locating = false
        }
        .onChange(of: location.issue) { _, issue in
            guard locating, let issue else { return }
            showLocationIssue(issue)
        }
        .sheet(item: $reportDestination) { destination in
            switch destination {
            case .list:
                ExploreReportsList(entries: reports, manifest: resources.region.manifest) {
                    reportDraft = ExploreReportDraft()
                    reportDestination = .compose
                } onMap: { report in
                    reportDestination = nil
                    cameraRequest = ExploreCameraRequest(command: .location(MapPoint(latE7: report.latitude, lonE7: report.longitude)))
                }
            case .compose:
                ExploreReportComposer(form: reportDraft, reports: reports, location: location, manifest: resources.region.manifest) {
                    reportDestination = nil
                    pickingReportLocation = true
                } saved: {
                    reportDestination = nil
                    reportNotice = "Report saved on this phone."
                    if let point = reportDraft.position?.point {
                        cameraRequest = ExploreCameraRequest(command: .location(point))
                    }
                    Task { await reports.page(in: resources.region.manifest) }
                }
            case .details(let report):
                NavigationStack {
                    ExploreReportDetails(report: report)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { reportDestination = nil }
                            }
                        }
                }
            }
        }
        .sheet(isPresented: $showingRoutes) {
            ExploreRoutePlanner(index: resources.places, initialDestination: selectedPlace, region: resources.region,
                                route: route, location: location) {
                if let result = route.result {
                    cameraRequest = ExploreCameraRequest(command: .route(result.points))
                }
            }
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

    private func showLocationIssue(_ issue: ExploreLocation.Issue) {
        locationNotice = issue == .denied ? "Location access is off. You can still search the map." : "Couldn’t get your location."
        locating = false
    }

    private func offlineMaps(_ manifest: RegionManifest) -> some View {
        NavigationStack {
            List {
                Section("Downloaded") {
                    LabeledContent(manifest.name,
                                   value: ByteCountFormatter.string(fromByteCount: manifest.files.reduce(0) { $0 + $1.bytes }, countStyle: .file))
                    Text("Includes hiking trails, place search, and routes.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Offline maps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showingOfflineMaps = false } }
            }
        }
    }

    @ViewBuilder
    private func fieldActions(_ resources: ExploreMapResources) -> some View {
        Button {
            showingRoutes = true
        } label: {
            Label("Route", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: 44)
                .padding(.horizontal, 12)
                .exploreGlass(in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(route.navigating)
        Button {
            reportNotice = nil
            reportDestination = .list
            Task { await reports.page(in: resources.region.manifest) }
        } label: {
            Label("Reports", systemImage: "text.bubble")
                .fixedSize(horizontal: true, vertical: false)
                .frame(minHeight: 44)
                .padding(.horizontal, 12)
                .exploreGlass(in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var routeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(route.destination).font(.headline)
            if route.navigating {
                Text(location.issue == .denied
                    ? "Location access is off. The route is still visible on the map."
                    : route.directions(using: location.recentFix))
                    .font(.subheadline)
                ViewThatFits {
                    HStack(spacing: 12) { hikeActions }
                    VStack(alignment: .leading) { hikeActions }
                }
            } else {
                HStack {
                    Button("Start hike") {
                        route.start()
                        followsHikePosition = true
                        location.follow(true)
                        centerOnHikePosition()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Clear route", action: clearRoute)
                }
                .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var hikeActions: some View {
        Button(followsHikePosition ? "Pause centering" : "Follow location") {
            followsHikePosition.toggle()
            centerOnHikePosition()
        }
        .frame(minHeight: 44)
        Button("End hike", role: .destructive, action: clearRoute)
            .frame(minHeight: 44)
    }

    private func centerOnHikePosition() {
        guard followsHikePosition, let fix = location.recentFix,
              let point = MapPoint(coordinate: fix.coordinate) else { return }
        cameraRequest = ExploreCameraRequest(command: .location(point))
    }

    private func clearRoute() {
        route.clear()
        location.follow(false)
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

struct ExplorePlaceSearch: View {
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
    case location(MapPoint)
    case route([MapPoint])
    case zoom(Double)
}

private struct ExploreCameraRequest {
    let id = UUID()
    let command: ExploreCameraCommand
}

private struct InteractiveRilaMap: UIViewRepresentable {
    let resources: ExploreMapResources
    let cameraRequest: ExploreCameraRequest?
    let route: HikingRoute?
    let routeID: UUID?
    let currentPosition: MapPoint?
    let reports: [StoredReport]
    let pickingReportLocation: Bool
    let pickCenterRequest: UUID?
    let onReport: (StoredReport) -> Void
    let onPickReportLocation: (MapPoint) -> Void
    let onLoaded: () -> Void
    let onFailure: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(resources: resources, onLoaded: onLoaded, onFailure: onFailure)
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
        let picker = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pickReportLocation(_:)))
        picker.isEnabled = false
        for gesture in map.gestureRecognizers ?? [] {
            if let tap = gesture as? UITapGestureRecognizer, tap.numberOfTapsRequired > 1 { picker.require(toFail: tap) }
        }
        map.addGestureRecognizer(picker)
        context.coordinator.locationPicker = picker
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        context.coordinator.updateRoute(route, id: routeID, on: map)
        context.coordinator.updatePosition(currentPosition, on: map)
        context.coordinator.updateReports(reports, on: map)
        context.coordinator.onReport = onReport
        context.coordinator.onPickReportLocation = onPickReportLocation
        context.coordinator.locationPicker?.isEnabled = pickingReportLocation
        if pickingReportLocation, let request = pickCenterRequest,
           context.coordinator.centerRequestID != request {
            context.coordinator.centerRequestID = request
            if let point = MapPoint(coordinate: map.centerCoordinate) {
                DispatchQueue.main.async { onPickReportLocation(point) }
            }
        }
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
        case .location(let point):
            map.setCenter(point.coordinate, zoomLevel: max(map.zoomLevel, 14),
                          animated: !UIAccessibility.isReduceMotionEnabled)
        case .route(let points):
            if let south = points.map(\.latE7).min(), let north = points.map(\.latE7).max(),
               let west = points.map(\.lonE7).min(), let east = points.map(\.lonE7).max(),
               south != north || west != east {
                map.setVisibleCoordinateBounds(
                    MLNCoordinateBounds(sw: MapPoint(latE7: south, lonE7: west).coordinate,
                                        ne: MapPoint(latE7: north, lonE7: east).coordinate),
                    edgePadding: UIEdgeInsets(top: 76, left: 30, bottom: 186, right: 30),
                    animated: !UIAccessibility.isReduceMotionEnabled, completionHandler: nil
                )
            }
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
        // Retain the verified pack until MapLibre has released this renderer.
        private let resources: ExploreMapResources
        private let onLoaded: () -> Void
        private let onFailure: () -> Void
        var cameraRequestID: UUID?
        var centerRequestID: UUID?
        private var renderedRouteID: UUID?
        private var line: MLNPolyline?
        private var locationPoint: MapPoint?
        private var locationMarker: MLNPointAnnotation?
        private var reportMarkers: [String: MLNPointAnnotation] = [:]
        private var visibleReports: [ObjectIdentifier: StoredReport] = [:]
        weak var locationPicker: UITapGestureRecognizer?
        var onReport: ((StoredReport) -> Void)?
        var onPickReportLocation: ((MapPoint) -> Void)?

        init(resources: ExploreMapResources, onLoaded: @escaping () -> Void, onFailure: @escaping () -> Void) {
            self.resources = resources
            self.onLoaded = onLoaded
            self.onFailure = onFailure
        }

        func updateRoute(_ route: HikingRoute?, id: UUID?, on map: MLNMapView) {
            guard id != renderedRouteID else { return }
            renderedRouteID = id
            if let line { map.removeAnnotation(line) }
            line = nil
            guard var coordinates = route?.points.map(\.coordinate), coordinates.count >= 2 else { return }
            let overlay = MLNPolyline(coordinates: &coordinates, count: UInt(coordinates.count))
            line = overlay
            map.addAnnotation(overlay)
        }

        func updatePosition(_ point: MapPoint?, on map: MLNMapView) {
            guard point != locationPoint else { return }
            locationPoint = point
            if let locationMarker { map.removeAnnotation(locationMarker) }
            locationMarker = nil
            guard let point else { return }
            let marker = MLNPointAnnotation()
            marker.coordinate = point.coordinate
            marker.title = "My location"
            locationMarker = marker
            map.addAnnotation(marker)
        }

        func updateReports(_ reports: [StoredReport], on map: MLNMapView) {
            let ids = Set(reports.map(\.bundleID))
            for id in Array(reportMarkers.keys) where !ids.contains(id) {
                if let marker = reportMarkers.removeValue(forKey: id) {
                    visibleReports.removeValue(forKey: ObjectIdentifier(marker))
                    map.removeAnnotation(marker)
                }
            }
            for report in reports where reportMarkers[report.bundleID] == nil {
                let marker = MLNPointAnnotation()
                marker.coordinate = MapPoint(latE7: report.latitude, lonE7: report.longitude).coordinate
                marker.title = ReportCategory.title(for: report)
                reportMarkers[report.bundleID] = marker
                visibleReports[ObjectIdentifier(marker)] = report
                map.addAnnotation(marker)
            }
        }

        @objc func pickReportLocation(_ recognizer: UITapGestureRecognizer) {
            guard let map = recognizer.view as? MLNMapView,
                  let point = MapPoint(coordinate: map.convert(recognizer.location(in: map), toCoordinateFrom: map)) else { return }
            onPickReportLocation?(point)
        }

        func mapView(_ mapView: MLNMapView, didSelect annotation: any MLNAnnotation) {
            guard let point = annotation as? MLNPointAnnotation,
                  locationPicker?.isEnabled == false,
                  let report = visibleReports[ObjectIdentifier(point)], ExploreReports.current(report) else { return }
            mapView.deselectAnnotation(annotation, animated: false)
            DispatchQueue.main.async { [weak self] in self?.onReport?(report) }
        }

        func mapView(_ mapView: MLNMapView, strokeColorForShapeAnnotation annotation: MLNShape) -> UIColor {
            UIColor.systemBlue
        }

        func mapView(_ mapView: MLNMapView, lineWidthForPolylineAnnotation annotation: MLNPolyline) -> CGFloat {
            5
        }

        func mapView(_ mapView: MLNMapView, imageFor annotation: any MLNAnnotation) -> MLNAnnotationImage? {
            guard let point = annotation as? MLNPointAnnotation else { return nil }
            let isLocation = point === locationMarker
            guard isLocation || visibleReports[ObjectIdentifier(point)] != nil else { return nil }
            let reuseID = isLocation ? "user-position" : "trail-report"
            if let image = mapView.dequeueReusableAnnotationImage(withIdentifier: reuseID) { return image }
            let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
                context.cgContext.setFillColor(UIColor.white.cgColor)
                context.cgContext.fillEllipse(in: CGRect(x: 1, y: 1, width: 22, height: 22))
                context.cgContext.setFillColor((isLocation ? UIColor.systemBlue : UIColor.systemOrange).cgColor)
                context.cgContext.fillEllipse(in: CGRect(x: 4, y: 4, width: 16, height: 16))
                if !isLocation {
                    context.cgContext.setFillColor(UIColor.white.cgColor)
                    context.cgContext.fill(CGRect(x: 8, y: 9, width: 8, height: 2))
                    context.cgContext.fill(CGRect(x: 8, y: 13, width: 6, height: 2))
                }
            }
            return MLNAnnotationImage(image: image, reuseIdentifier: reuseID)
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
