import CoreBluetooth
import Observation
import SwiftUI
import TrailMeshMaps
import TrailMeshReports
import UIKit

@MainActor
@Observable
final class FieldNearbySession: NSObject, @preconcurrency CBCentralManagerDelegate {
    enum Scope: Equatable { case route, area }

    private static let intentKey = "fieldReportSessionIntended"
    private(set) var scope: Scope = .route
    private(set) var area: MapPoint?
    private(set) var intended = false
    private(set) var didStop = false
    private(set) var wasInterrupted = UserDefaults.standard.bool(forKey: FieldNearbySession.intentKey)
    private(set) var state: ReportSessionState = .stopped
    private(set) var bluetooth: CBManagerState = .unknown
    private(set) var received = 0
    private(set) var receiptRevision: UInt64 = 0
    private(set) var opening = false

    @ObservationIgnored private var foreground = false
    @ObservationIgnored private var context: RelevanceContext?
    @ObservationIgnored private var session: ReportSessionCoordinator?
    @ObservationIgnored private var bluetoothManager: CBCentralManager?
    @ObservationIgnored private var startTask: Task<Void, Never>?

    func selectRoute() {
        guard !intended else { return }
        scope = .route
    }

    func chooseArea(_ point: MapPoint) {
        guard !intended else { return }
        area = point
        scope = .area
    }

    func canStart(route: HikingRoute?) -> Bool {
        configuration(for: route) != nil
    }

    func start(route: HikingRoute?, consent: Bool) {
        guard consent, !intended, foreground, let configuration = configuration(for: route) else { return }
        // Capture the route or area only at the user’s explicit start.
        context = configuration
        intended = true
        didStop = false
        wasInterrupted = false
        received = 0
        UserDefaults.standard.set(true, forKey: Self.intentKey)
        bluetoothManager = CBCentralManager(delegate: self, queue: .main,
                                             options: [CBCentralManagerOptionShowPowerAlertKey: false])
        openStorage()
    }

    func stop() {
        didStop = intended
        intended = false
        startTask?.cancel()
        startTask = nil
        opening = false
        session?.stop()
        session = nil
        bluetoothManager?.delegate = nil
        bluetoothManager = nil
        bluetooth = .unknown
        context = nil
        state = .stopped
        area = nil
        wasInterrupted = false
        UserDefaults.standard.removeObject(forKey: Self.intentKey)
    }

    func setForeground(_ active: Bool) {
        guard foreground != active else { return }
        foreground = active
        synchronizeRadio()
    }

    func retry() {
        guard intended, foreground else { return }
        if let session {
            if bluetooth == .poweredOn, session.state != .running { session.resume() }
        } else {
            openStorage()
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === bluetoothManager, intended else { return }
        bluetooth = central.state
        synchronizeRadio()
    }

    private func configuration(for route: HikingRoute?) -> RelevanceContext? {
        switch scope {
        case .route:
            guard let route, let corridor = try? route.reportRelevance() else { return nil }
            return RelevanceContext(route: corridor)
        case .area:
            guard let area else { return nil }
            let center = RelevancePoint(latitude: area.latE7, longitude: area.lonE7)
            return RelevanceContext(manualArea: RelevanceArea(center: center, radius: 5_000))
        }
    }

    private func openStorage() {
        guard startTask == nil else { return }
        opening = true
        startTask = Task { [weak self] in
            do {
                let repository = try await ProductReportStorage.shared.repository(.field)
                guard !Task.isCancelled, let self, self.intended else { return }
                defer { self.opening = false; self.startTask = nil }
                let radio = ProductNearbyRadio(serviceID: ReportAdvertisement.fieldServiceID)
                let session = ReportSessionCoordinator(repository: repository, radio: radio)
                self.session = session
                session.onChange = { [weak self, weak session] in
                    guard let self, let session, session === self.session else { return }
                    self.state = session.state
                }
                session.onReportStored = { [weak self, weak session] in
                    guard let self else { return }
                    self.receiptRevision &+= 1
                    if let session, session === self.session, self.intended { self.received += 1 }
                }
                session.setForeground(self.foreground && self.bluetooth == .poweredOn)
                session.start(context: self.context ?? RelevanceContext(), publicSharingConsent: true)
            } catch {
                guard !Task.isCancelled, let self, self.intended else { return }
                self.opening = false
                self.startTask = nil
                self.state = .paused(.storageFailure)
            }
        }
    }

    private func synchronizeRadio() {
        guard let session else { return }
        let canRun = foreground && bluetooth == .poweredOn
        if !canRun, session.state != .paused(.foregroundRequired) {
            session.setForeground(false)
        } else if canRun, session.state == .paused(.foregroundRequired) {
            session.setForeground(true)
        }
    }
}

struct FieldNearbyView: View {
    let nearby: FieldNearbySession
    let route: HikingRoute?
    let pickArea: () -> Void
    @State private var consent = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                if nearby.intended {
                    Section {
                        Label(status, systemImage: nearby.state == .running ? "antenna.radiowaves.left.and.right" : "pause.circle")
                        Text(nearby.scope == .route ? "Using the route selected at start" : "Using the area within 5 km of your selected point")
                        if nearby.received > 0 {
                            Text("Reports saved on this phone: \(nearby.received)")
                        }
                    } footer: {
                        Text("Keep TrailMesh open for Nearby to work.")
                    }
                    if nearby.state == .paused(.storageFailure) || (nearby.state == .paused(.radioUnavailable) && nearby.bluetooth == .poweredOn) {
                        Button("Try again") { nearby.retry() }
                    }
                    if nearby.bluetooth == .unauthorized || nearby.state == .paused(.radioUnavailable) {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                    Button("Stop sharing", role: .destructive) { nearby.stop(); consent = false }
                } else {
                    if nearby.wasInterrupted {
                        Text("Your previous session ended when TrailMesh closed. Start again to share.")
                        Button("Dismiss previous session") { nearby.stop() }
                    } else if nearby.didStop {
                        Label("Sharing stopped", systemImage: "stop.circle")
                    }
                    Section("Choose where to share") {
                        Button {
                            nearby.selectRoute()
                        } label: {
                            Label("Selected route", systemImage: nearby.scope == .route ? "checkmark.circle.fill" : "circle")
                        }
                        Button {
                            pickArea()
                        } label: {
                            Label(nearby.area == nil ? "Choose area on map" : "Change map area",
                                  systemImage: nearby.scope == .area ? "checkmark.circle.fill" : "mappin")
                        }
                        if nearby.scope == .route && !nearby.canStart(route: route) {
                            Text("Plan a route first, or choose an area on the map.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Toggle("Share public reports this session", isOn: $consent)
                        Button("Start sharing") { nearby.start(route: route, consent: consent) }
                            .disabled(!consent || !nearby.canStart(route: route))
                    } footer: {
                        Text("Nearby phones can relay signed public reports, including the location, time and note attached to each report. Your route and live location stay on this phone. Sharing pauses when TrailMesh leaves the foreground.")
                    }
                }
            }
            .navigationTitle("Nearby")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var status: String {
        if nearby.opening { return "Opening report storage…" }
        if nearby.state == .paused(.storageFailure) { return "Report storage is unavailable. Check the device clock and try again." }
        if nearby.state == .paused(.configurationRequired) { return "The selected route is unavailable. Stop sharing to choose an area." }
        switch nearby.bluetooth {
        case .poweredOff: return "Bluetooth is off. Turn it on to share."
        case .unauthorized: return "Allow Bluetooth in Settings to share."
        case .unsupported: return "Bluetooth sharing is unavailable on this device."
        case .poweredOn:
            switch nearby.state {
            case .running: return "Sharing while TrailMesh is open"
            case .paused(.radioUnavailable): return "Nearby stopped. Check Bluetooth and Local Network access, then try again."
            default: return "Sharing paused"
            }
        default: return "Waiting for Bluetooth…"
        }
    }
}
