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
final class ExploreLocation: NSObject, CLLocationManagerDelegate {
    enum Issue: Equatable { case denied, unavailable }

    private let manager = CLLocationManager()
    private var following = false
    private var requesting = false
    private(set) var fix: CLLocation?
    private(set) var issue: Issue?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
        manager.distanceFilter = 5
    }

    func requestFix() {
        requesting = true
        issue = nil
        updateRequest()
    }

    func follow(_ value: Bool) {
        following = value
        if value {
            issue = nil
            updateRequest()
        } else {
            manager.stopUpdatingLocation()
        }
    }

    var recentFix: CLLocation? {
        guard let fix, abs(fix.timestamp.timeIntervalSinceNow) <= 30,
              (0...100).contains(fix.horizontalAccuracy) else { return nil }
        return fix
    }

    private func updateRequest() {
        guard following || requesting else { return }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            if following { manager.startUpdatingLocation() }
            else { manager.requestLocation() }
        case .denied, .restricted:
            issue = .denied
            fix = nil
            requesting = false
        @unknown default:
            issue = .unavailable
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateRequest()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last, following || requesting else { return }
        requesting = false
        fix = latest
        issue = recentFix == nil ? .unavailable : nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        requesting = false
        fix = nil
        issue = (error as? CLError)?.code == .denied ? .denied : .unavailable
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
    private var requestID: UUID?

    func calculate(region: InstalledRegion, from: MapPoint, to: MapPoint, destination: String) async {
        let id = UUID()
        requestID = id
        result = nil
        geometryID = nil
        error = nil
        loading = true
        defer { if requestID == id { loading = false } }

        let router = OfflineHikingRouter()
        do {
            let lease = try await RilaRegion.makeStore().lease(region)
            try await router.open(region, lease: lease)
            let route = try await router.route(from: from, to: to)
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
            case MapFailure.noRoute: self.error = "No hiking route found. Try another start or destination."
            default: self.error = "The route couldn’t be calculated. Try again."
            }
        }
    }

    func start() {
        guard result != nil else { return }
        navigating = true
    }

    func clear() {
        requestID = nil
        geometryID = nil
        result = nil
        error = nil
        loading = false
        navigating = false
    }

    func directions(using fix: CLLocation?) -> String {
        guard let result, let fix else { return "Waiting for your location" }
        guard result.points.count > 1 else { return "Follow the trail shown on the map" }

        // Project the location onto the trail, not just the nearest route vertex.
        // All routes here are local to Rila, so a local tangent plane is sufficient.
        let latitudeScale = 111_195.0 / 1e7
        let longitudeScale = latitudeScale * cos(fix.coordinate.latitude * .pi / 180)
        let originLatitude = fix.coordinate.latitude * 1e7
        let originLongitude = fix.coordinate.longitude * 1e7
        func offset(_ point: MapPoint) -> (Double, Double) {
            ((Double(point.lonE7) - originLongitude) * longitudeScale,
             (Double(point.latE7) - originLatitude) * latitudeScale)
        }
        var closestDistance = Double.infinity
        var progress = 0.0
        var previous = offset(result.points[0])
        for index in 1..<result.points.count {
            let next = offset(result.points[index])
            let x = next.0 - previous.0
            let y = next.1 - previous.1
            let lengthSquared = x*x + y*y
            let fraction = lengthSquared == 0 ? 0 : min(1, max(0, -(previous.0*x + previous.1*y) / lengthSquared))
            let distance = hypot(previous.0 + x*fraction, previous.1 + y*fraction)
            if distance < closestDistance {
                closestDistance = distance
                progress = Double(index - 1) + fraction
            }
            previous = next
        }
        guard closestDistance <= max(30, fix.horizontalAccuracy) else {
            return "You’re away from the planned trail. Check the map."
        }
        let end = offset(result.points[result.points.count - 1])
        if progress >= Double(result.points.count - 2), hypot(end.0, end.1) <= max(12, fix.horizontalAccuracy) {
            return "You’re near \(destination)"
        }
        return result.maneuvers.first { Double($0.pointIndex) >= progress }?.instruction
            ?? "Follow the trail shown on the map"
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
                        Button("Use current location") { start = nil; route.clear(); location.requestFix() }
                    }
                    Button { selecting = .destination } label: {
                        LabeledContent("To", value: destination?.name ?? "Choose a place")
                    }
                }
                if start == nil, location.recentFix == nil {
                    Section {
                        Button("Get current location") { location.requestFix() }
                        if let issue = location.issue {
                            Text(issue == .denied ? "Location access is off. Choose a starting place or enable access in Settings." : "Location isn’t precise enough. Try again or choose a place.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let routeResult = route.result {
                    Section("Hike") {
                        LabeledContent("Distance", value: routeResult.distanceKm.formatted(.number.precision(.fractionLength(1))) + " km")
                        LabeledContent("Estimated time", value: Duration.seconds(routeResult.timeSeconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                        Button("Show on map") { showRoute(); dismiss() }
                    }
                } else {
                    Section {
                        if route.loading { ProgressView("Finding a trail…") }
                        else {
                            Button("Find route", action: calculate)
                                .disabled(destination == nil || (start == nil && location.recentFix == nil))
                        }
                        if let error = route.error { Text(error).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("Plan a route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .sheet(item: $selecting) { endpoint in
                ExplorePlaceSearch(index: index) { place in
                    if endpoint == .start { start = place }
                    else { destination = place }
                    route.clear()
                    selecting = nil
                }
            }
            .onAppear { if destination == nil { destination = initialDestination } }
            .onDisappear { request?.cancel() }
        }
    }

    private func calculate() {
        guard let destination else { return }
        let from: MapPoint?
        if let start { from = MapPoint(latE7: start.latE7, lonE7: start.lonE7) }
        else { from = location.recentFix.flatMap { MapPoint(coordinate: $0.coordinate) } }
        guard let from else { location.requestFix(); return }
        request = Task {
            await route.calculate(region: region, from: from,
                to: MapPoint(latE7: destination.latE7, lonE7: destination.lonE7), destination: destination.name)
        }
    }
}
