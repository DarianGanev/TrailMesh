import CoreLocation
import Observation
import SwiftUI
import TrailMeshMaps

extension MapPoint {
    init?(coordinate: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        self.init(latE7: Int64((coordinate.latitude * 1e7).rounded()), lonE7: Int64((coordinate.longitude * 1e7).rounded()))
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: Double(latE7) / 1e7, longitude: Double(lonE7) / 1e7)
    }
}

@MainActor
@Observable
final class ExploreLocation: NSObject, @preconcurrency CLLocationManagerDelegate {
    enum Issue: Equatable { case denied, unavailable }
    enum FixOwner: Equatable, Sendable { case map, planner, composer }

    // Core Location uses the run loop of the main-actor creation thread for its delegate.
    private let manager = CLLocationManager()
    private var foreground = true
    private var following = false
    private var requester: FixOwner?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    private(set) var fix: CLLocation?
    private(set) var issue: Issue?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        manager.distanceFilter = 5
    }

    #if TRAILMESH_DEVELOPMENT && targetEnvironment(simulator)
    func capture(point: MapPoint? = nil, issue: Issue? = nil) {
        self.issue = issue
        fix = point.map { CLLocation(coordinate: .init(latitude: Double($0.latE7) / 1e7, longitude: Double($0.lonE7) / 1e7),
                                     altitude: 1700, horizontalAccuracy: 8, verticalAccuracy: 10, timestamp: Date()) }
    }
    #endif

    func requestFix(for owner: FixOwner) {
        deadline?.cancel()
        requester = owner
        issue = nil
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) }
            catch { return }
            guard let self, self.requester == owner else { return }
            self.cancelFix(for: owner)
            self.issue = .unavailable
        }
        updateRequest()
    }

    func follow(_ value: Bool) {
        guard value != following else { return }
        following = value
        if value { issue = nil }
        else { manager.stopUpdatingLocation() }
        updateRequest()
    }

    func setForeground(_ value: Bool) {
        guard foreground != value else { return }
        foreground = value
        if value { updateRequest() }
        else { manager.stopUpdatingLocation() }
    }

    func cancelFix(for owner: FixOwner) {
        guard requester == owner else { return }
        finishFix()
        if !following { manager.stopUpdatingLocation() }
    }

    private func finishFix() {
        requester = nil
        deadline?.cancel()
        deadline = nil
    }

    var recentFix: CLLocation? {
        guard let fix, abs(fix.timestamp.timeIntervalSinceNow) <= 30,
              (0...100).contains(fix.horizontalAccuracy) else { return nil }
        return fix
    }

    private func updateRequest() {
        guard foreground, following || requester != nil else { return }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            if following { manager.startUpdatingLocation() }
            else { manager.requestLocation() }
        case .denied, .restricted:
            issue = .denied
            fix = nil
            finishFix()
        @unknown default:
            issue = .unavailable
            finishFix()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateRequest()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard foreground, let latest = locations.last, following || requester != nil else { return }
        fix = latest
        if recentFix != nil {
            issue = nil
            finishFix()
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard foreground, following || requester != nil else { return }
        let denied = (error as? CLError)?.code == .denied
        if following, !denied { return }
        finishFix()
        fix = nil
        issue = denied ? .denied : .unavailable
    }
}

@MainActor
@Observable
final class ExploreRoute {
    private(set) var result: HikingRoute?
    private(set) var destination = ""
    private(set) var navigating = false
    private(set) var loading = false
    private(set) var error: String?
    private(set) var geometryID: UUID?
    private(set) var maximumTrailGrade = 2
    private(set) var turnInstruction: String?
    private var lastMatch: (fixAt: Date, match: HikingRoute.Progress)?
    private var requestID: UUID?

    #if TRAILMESH_DEVELOPMENT && targetEnvironment(simulator)
    func captureLoading() { loading = true }
    #endif

    func setMaximumTrailGrade(_ grade: Int) {
        guard grade != maximumTrailGrade else { return }
        maximumTrailGrade = grade
        clear()
    }

    func calculate(region: InstalledRegion, from: MapPoint, to: MapPoint, destination: String) async {
        let id = UUID()
        let grade = maximumTrailGrade
        requestID = id
        result = nil
        geometryID = nil
        error = nil
        loading = true
        defer { if requestID == id { loading = false } }

        let router = OfflineHikingRouter()
        do {
            try Task.checkCancellation()
            let lease = try await RilaRegion.makeStore().lease(region)
            guard requestID == id, !Task.isCancelled else { lease.close(); return }
            try await router.open(region, lease: lease)
            guard requestID == id, !Task.isCancelled else { await router.close(); return }
            let route = try await router.route(from: from, to: to, maximumHikingDifficulty: grade)
            await router.close()
            try Task.checkCancellation()
            guard requestID == id else { return }
            result = route
            geometryID = id
            self.destination = destination
        } catch {
            await router.close()
            guard requestID == id, !Task.isCancelled else { return }
            switch error {
            case MapFailure.outsideCoverage: self.error = "Both places must be within the downloaded map."
            case MapFailure.noRoute: self.error = "No route at grade \(grade). Check the endpoints and trail grade."
            default: self.error = "The route couldn’t be calculated. Try again."
            }
        }
    }

    func start(using fix: CLLocation?) {
        guard result != nil else { return }
        navigating = true
        updateGuidance(using: fix)
    }

    func clear() {
        requestID = nil
        geometryID = nil
        result = nil
        error = nil
        loading = false
        navigating = false
        turnInstruction = nil
        lastMatch = nil
    }

    func updateGuidance(using fix: CLLocation?) {
        guard navigating, let result, let fix, let point = MapPoint(coordinate: fix.coordinate) else { return }
        let age = lastMatch.map { fix.timestamp.timeIntervalSince($0.fixAt) } ?? -1
        let previous = age >= 0 ? lastMatch?.match : nil
        let threshold = max(30, fix.horizontalAccuracy)
        guard let match = result.match(point, following: previous, useMovement: age <= 30,
                                       offRouteThreshold: threshold), match.offset <= threshold else {
            turnInstruction = "You’re away from the planned trail. Check the map."
            return
        }
        lastMatch = (fix.timestamp, match)
        if result.isAtDestination(match, tolerance: max(12, fix.horizontalAccuracy)) {
            turnInstruction = "You’re near \(destination)"
        } else {
            turnInstruction = result.nextInstruction(at: match) ?? "Follow the trail shown on the map"
        }
    }
}

struct ExploreRoutePlanner: View {
    let index: PlaceIndex
    let initialDestination: Place?
    let region: InstalledRegion
    let route: ExploreRoute
    let location: ExploreLocation
    let showRoute: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var start: Place?
    @State private var destination: Place?
    @State private var selecting: Endpoint?
    @State private var request: Task<Void, Never>?

    enum Endpoint: String, Identifiable {
        case start, destination
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Route") {
                    Button { selecting = .start } label: {
                        LabeledContent("From", value: start?.name ?? "Current location")
                    }
                    if start != nil {
                        Button("Use current location") { start = nil; route.clear(); location.requestFix(for: .planner) }
                    }
                    Button { selecting = .destination } label: {
                        LabeledContent("To", value: destination?.name ?? "Choose a place")
                    }
                    Picker("Maximum trail grade", selection: Binding(
                        get: { route.maximumTrailGrade },
                        set: { route.setMaximumTrailGrade($0) }
                    )) {
                        ForEach(0...6, id: \.self) { grade in
                            Text("Grade \(grade)").tag(grade)
                        }
                    }
                    .disabled(route.loading)
                }
                if start == nil, location.recentFix == nil {
                    Section {
                        Button("Get current location") { location.requestFix(for: .planner) }
                        if let issue = location.issue {
                            Text(issue == .denied ? "Location access is off. Choose a starting place or enable access in Settings." : "Location isn’t precise enough. Try again or choose a place.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let routeResult = route.result {
                    Section("Last calculated route") {
                        LabeledContent("Destination", value: route.destination)
                        LabeledContent("Distance", value: routeResult.distanceKm.formatted(.number.precision(.fractionLength(1))) + " km")
                        LabeledContent("Estimated time", value: Duration.seconds(routeResult.timeSeconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                        Button("Show this route on map") { showRoute(); dismiss() }
                    }
                }
                Section {
                    if route.loading { ProgressView("Finding a trail…") }
                    else {
                        Button("Find route", action: calculate)
                            .disabled(destination == nil || (start == nil && location.recentFix == nil))
                    }
                    if let error = route.error { Text(error).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Plan a route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .sheet(item: $selecting) { endpoint in
                ExplorePlaceSearch(index: index) { place in
                    if endpoint == .start {
                        start = place
                        location.cancelFix(for: .planner)
                    } else { destination = place }
                    route.clear()
                    selecting = nil
                }
            }
            .onAppear {
                if destination == nil { destination = initialDestination }
                #if TRAILMESH_DEVELOPMENT && targetEnvironment(simulator)
                if ScreenCapture.name == "route-start-picker" { selecting = .start }
                if ScreenCapture.name == "route-destination-picker" { selecting = .destination }
                #endif
            }
            .onDisappear {
                request?.cancel()
                location.cancelFix(for: .planner)
            }
        }
    }

    private func calculate() {
        guard let destination else { return }
        let from: MapPoint?
        if let start { from = MapPoint(latE7: start.latE7, lonE7: start.lonE7) }
        else { from = location.recentFix.flatMap { MapPoint(coordinate: $0.coordinate) } }
        guard let from else { location.requestFix(for: .planner); return }
        request = Task {
            await route.calculate(region: region, from: from,
                to: MapPoint(latE7: destination.latE7, lonE7: destination.lonE7), destination: destination.name)
        }
    }
}
