#if TRAILMESH_DEVELOPMENT
import Foundation
import SwiftUI
import TrailMeshReports
import UIKit
import Darwin

/// Controls for the development product target, not the hiking/map interface.
@MainActor
final class ReportDevelopmentModel: ObservableObject {
    @Published var consent = false
    @Published private(set) var status = "Opening protected report storage..."
    @Published private(set) var records: [SavedTestReportEvidence] = []
    @Published private(set) var exportURL: URL?
    @Published private(set) var ready = false
    @Published private(set) var activeLinks = 0
    @Published private(set) var waitingPeers = 0
    @Published private(set) var needsResume = UserDefaults.standard.bool(forKey: "publicReportSessionIntended")
    @Published private(set) var notice = ""
    private var repository: ReportRepository?
    private var identity: ReportIdentity?
    private var coordinator: ReportSessionCoordinator?
    private var loading = false
    private var foreground = true
    private var refreshing = false, refreshAgain = false, authoring = false
    private var lastRevision: UInt64 = 0
    private let area = RelevanceContext(manualArea: RelevanceArea(center: RelevancePoint(latitude: 426977000, longitude: 233219000), radius: 5000))
    private var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    func load() async {
        guard repository == nil, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("TrailMeshReports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            let opened = try await ReportRepository.open(path: directory.appendingPathComponent("reports.sqlite").path)
            let identityWasEstablished = UserDefaults.standard.bool(forKey: "reportIdentityEstablished")
            let protectedIdentity = try await Task.detached {
                let keychain = KeychainIdentityStore(service: "org.trailmesh.ios.report-identity.v1", account: "signing")
                do { return try ReportIdentity.load(store: keychain) }
                catch IdentityError.missing {
                    guard !identityWasEstablished else { throw IdentityError.missing }
                    return try ReportIdentity.create(store: keychain)
                }
                // Corruption/keychain failures propagate; never replace an existing key.
            }.value
            UserDefaults.standard.set(true, forKey: "reportIdentityEstablished")
            repository = opened; identity = protectedIdentity
            let coordinator = ReportSessionCoordinator(repository: opened, radio: ProductNearbyRadio())
            self.coordinator = coordinator
            coordinator.onChange = { [weak self] in self?.synchronize() }
            ready = true
            status = needsResume ? "Interrupted session. Review consent and tap Resume." : "Ready for foreground exchange"
            await refresh()
        } catch { status = "Storage or signing identity unavailable. Existing identity was preserved." }
    }
    func start() {
        guard let coordinator, consent else { notice = "Review and enable public sharing consent first."; return }
        UserDefaults.standard.set(true, forKey: "publicReportSessionIntended")
        needsResume = false
        coordinator.setForeground(foreground)
        coordinator.start(context: area, publicSharingConsent: consent)
        synchronize()
    }
    func stop() {
        coordinator?.stop()
        UserDefaults.standard.set(false, forKey: "publicReportSessionIntended")
        needsResume = false; synchronize()
    }
    func setForeground(_ active: Bool) { foreground = active; coordinator?.setForeground(active); synchronize() }
    func consentChanged() { if !consent { stop() } }
    private func synchronize() {
        guard let coordinator else { return }
        status = coordinator.state.label
        activeLinks = coordinator.activeLinkCount; waitingPeers = coordinator.waitingCandidateCount
        if coordinator.revision != lastRevision {
            lastRevision = coordinator.revision
            if ["report_stored", "report_duplicate", "report_authored"].contains(coordinator.events.last?.code ?? "") { requestRefresh() }
        }
    }
    private func requestRefresh() {
        refreshAgain = true
        guard !refreshing else { return }
        refreshing = true
        Task { [weak self] in
            guard let self else { return }
            repeat { self.refreshAgain = false; await self.refresh() } while self.refreshAgain
            self.refreshing = false
        }
    }
    private func refresh() async {
        guard let repository else { return }
        do { records = try await repository.savedTestReportEvidence(clock: { Int64(Date().timeIntervalSince1970 * 1000) }) }
        catch { notice = "Reports could not be verified. Check device clock and storage." }
    }
    func createTestReport() {
        guard !authoring, let repository, let identity else { return }
        authoring = true
        Task {
            defer { authoring = false }
            do {
                let outcome = try await repository.authorSyntheticTestReport(identity: identity, clock: { Int64(Date().timeIntervalSince1970 * 1000) })
                await refresh()
                if case let .stored(id) = outcome, let evidence = records.first(where: { $0.bundleID == id }) {
                    coordinator?.noteAuthoredTestReport(evidence)
                    notice = "Signed synthetic report saved locally. This does not establish peer receipt or delivery."
                } else { notice = "Synthetic report was not saved. Check clock and storage limits." }
            } catch { notice = "Synthetic report could not be saved. Check clock and storage." }
        }
    }
    private static var hardwareModel: String {
        var system = utsname()
        guard uname(&system) == 0 else { return UIDevice.current.model }
        let machine = withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        #if targetEnvironment(simulator)
        let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine
        return "Simulator (" + simulated + ")"
        #else
        return machine.isEmpty ? UIDevice.current.model : machine
        #endif
    }
    func exportDiagnostics() {
        guard let repository, let coordinator else { return }
        guard ReportAdvertisement.parse(Data("TMR1|\(coordinator.sessionID)".utf8)) != nil else { notice = "Diagnostics need a valid temporary session identifier."; return }
        Task {
            do {
                let verified = try await repository.savedTestReportEvidence(clock: { Int64(Date().timeIntervalSince1970 * 1000) })
                let device = UIDevice.current
                let document = ReportSessionExport(deviceModel: Self.hardwareModel, osVersion: device.systemVersion,
                    appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
                    sourceCommit: nil,
                    sessionID: coordinator.sessionID, state: coordinator.state.exportValue, events: coordinator.events, savedTestReports: verified)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("trailmesh-report-session-" + document.exportID + ".json")
                try encoder.encode(document).write(to: url, options: [.atomic, .completeFileProtection])
                exportURL = url; notice = "Redacted verified test evidence is ready to share. No report text, coordinates, routes or signing secrets are included."
            } catch { notice = "Diagnostics could not be verified or exported." }
        }
    }
    func recoverClockAfterConfirmation() {
        guard let repository else { return }
        stop()
        Task {
            do { _ = try await repository.recoverClockAfterUserConfirmation(now: now); await refresh(); notice = "Earlier reports are quarantined history. Review before storage cleanup." }
            catch { notice = "Clock recovery was not applied. It requires a confirmed backward clock correction." }
        }
    }
    func cleanupAfterConfirmation() {
        guard let repository else { return }
        Task {
            do { _ = try await repository.reclaimExpiredReportsAfterUserConfirmation(now: now); await refresh(); notice = "Confirmed expired-history cleanup finished." }
            catch { notice = "Cleanup could not finish. Check device clock and storage." }
        }
    }
}
#endif
