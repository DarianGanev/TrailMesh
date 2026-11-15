import Foundation
import Combine
import NearbyConnections
import UIKit

/// Main-queue owner of the shared durable journal and a bounded cluster of links.
final class ProbeModel: ObservableObject, ProbeLinkHost {
    @Published private(set) var status = "Ready to start"
    @Published private(set) var sessionActive = false
    @Published private(set) var awaitingResume = false
    @Published private(set) var successfulAttempts = 0
    @Published private(set) var failedAttempts = 0
    @Published private(set) var receivedAttempts = 0
    @Published private(set) var duplicateAttempts = 0
    @Published private(set) var completedPeers = 0
    @Published private(set) var activePeers = 0
    @Published private(set) var waitingPeers = 0
    @Published private(set) var logs: [String] = []
    @Published private(set) var backgroundPolicy = "Saved progress and automatic foreground recovery"

    private var state: ProbeSessionState?
    var sessionState: ProbeSessionState? { state }
    private let store: ProbeCheckpointStore
    private let serviceID = "org.trailmesh.clusterprobe"
    private var connectionManager: ConnectionManager?
    private var discoverer: Discoverer?
    private var advertiser: Advertiser?
    private var discoveryRunning = false
    private var advertisingRunning = false
    private var pool = ProbePeerPool()
    private var links: [String: ProbeLink] = [:]
    private var retryCounts: [String: Int] = [:]
    private var eligibleAfter: [String: TimeInterval] = [:]
    private var catchUpLinks: [String: Int] = [:]
    private var catchUpRequests: [String: Int] = [:]
    private var refillWork: DispatchWorkItem?
    private var restartWork: DispatchWorkItem?
    private var sessionGeneration = 0
    private var transportGeneration = 0
    private var foreground = UIApplication.shared.applicationState != .background
    private(set) var finishingInBackground = false
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var backgroundTaskGeneration = 0
    private var activityObject: AnyObject?
    private var activitySuppressed = false

    init(store: ProbeCheckpointStore = .applicationStore) {
        self.store = store
        do {
            state = try store.load()
            awaitingResume = state?.intendedActive == true
            refreshPublishedState()
            if awaitingResume {
                endActivity()
                status = "Interrupted session saved. Tap Resume to continue."
            }
        } catch {
            endActivity()
            status = "Saved checkpoint could not be read. Start a new session."
        }
    }

    var selectedPayloadSize: Int { state?.payloadSize ?? 2048 }
    private var localContext: ProbePeerContext? {
        state.map { ProbePeerContext(platform: .ios, sessionID: $0.sessionID, payloadSize: $0.payloadSize) }
    }

    var exportJSON: String {
        let device = UIDevice.current
        let document: [String: Any] = [
            "schema": "trailmesh.foreground-probe-log", "version": 2, "probe_protocol": 2, "platform": "ios",
            "session_id": state?.sessionID ?? "",
            "device": ["model": device.model, "os_version": device.systemVersion,
                       "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                       "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"],
            "transport": "Google Nearby Connections", "strategy": "cluster",
            "pairing_mode": "automatic", "transport_role": "advertiser-and-discoverer", "requested_medium": "ble",
            "underlying_medium": "SDK selected within BLE policy; physical validation required",
            "maximum_active_peers": ProbePeerPool.maximumLinks, "maximum_candidates": ProbePeerPool.maximumCandidates,
            "maximum_journal_peers": 8, "active_peers": activePeers, "waiting_peers": waitingPeers,
            "automatic_test_acceptance": true, "internet_disabled": NSNull(),
            "session_intended_active": state?.intendedActive ?? false, "background_policy": backgroundPolicy,
            "completed_peers": completedPeers, "sent_successful": successfulAttempts, "sent_failed": failedAttempts,
            "received_unique": receivedAttempts, "received_duplicates": duplicateAttempts,
            "evicted_records": state?.evictedRecords ?? 0, "attempts": state?.records.map(\.exported) ?? []
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{\"error\":\"Log export failed\"}" }
        return text
    }

    func start(payloadSize: Int) {
        guard [256, 2048, 8192].contains(payloadSize) else { return }
        sessionGeneration &+= 1
        tearDownTransport()
        endActivity()
        activitySuppressed = false
        retryCounts.removeAll(); eligibleAfter.removeAll()
        catchUpLinks.removeAll(); catchUpRequests.removeAll()
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var next = ProbeSessionState(sessionID: id, payloadSize: payloadSize)
        append("session_started", fields: ["payload_size_bytes": "\(payloadSize)", "pairing_mode": "automatic"], to: &next)
        guard commit(next) else { return }
        awaitingResume = false
        if foreground { startTransport() }
        else { pauseTransport(reason: "Session saved; return to TrailMesh to connect.") }
    }

    func resume() {
        guard state?.intendedActive == true, foreground else { return }
        awaitingResume = false
        retryCounts.removeAll(); eligibleAfter.removeAll()
        guard record("session_resumed") else { return }
        if connectionManager == nil { startTransport() }
        else { fillSlots() }
    }

    func stop() {
        sessionGeneration &+= 1
        if var next = state {
            next.intendedActive = false
            append("session_stopped", fields: ["reason": "user_stopped"], to: &next)
            if !commit(next) {
                // A write failure must still stop this process and prohibit automatic recovery.
                state?.intendedActive = false
                refreshPublishedState()
                tearDownTransport()
                endActivity()
                status = "Stopped. The checkpoint could not be saved; the next launch may offer the previous session."
                awaitingResume = false
                return
            }
        }
        tearDownTransport()
        endActivity()
        awaitingResume = false
        status = "Stopped by user. Progress and redacted log saved."
    }

    func sceneBecameActive() {
        foreground = true
        finishingInBackground = false
        endBackgroundTask()
        guard state?.intendedActive == true, !awaitingResume else { return }
        if connectionManager == nil {
            guard record("foreground_recovery") else { return }
            startTransport()
        } else {
            startPresence()
            startActivityIfAvailable()
            for link in Array(links.values) { link.resumeWork() }
            fillSlots()
        }
    }

    func sceneEnteredBackground() {
        foreground = false
        guard state?.intendedActive == true, !awaitingResume, record("entered_background") else { return }
        if backgroundBluetoothAllowed {
            backgroundPolicy = "Live Activity Bluetooth is best effort; concurrent screen-off delivery is unverified"
            status = "Session saved and available for Bluetooth events; background delivery is best effort."
            updateActivity()
        } else { finishCurrentAttemptOrPause() }
    }

    func enableBackgroundActivity() {
        activitySuppressed = false
        startActivityIfAvailable()
    }

    private var backgroundBluetoothAllowed: Bool {
        if #available(iOS 26.0, *), let activity = activityObject as? ProbeLiveActivity { return activity.allowsBackgroundBluetooth }
        return false
    }
    var mayStartWork: Bool {
        state?.intendedActive == true && !awaitingResume && (foreground || backgroundBluetoothAllowed)
    }

    private func startTransport() {
        guard mayStartWork, connectionManager == nil, restartWork == nil else { return }
        transportGeneration &+= 1
        let manager = ConnectionManager(serviceID: serviceID, strategy: .cluster, queue: .main)
        manager.delegate = self
        let scanner = Discoverer(connectionManager: manager)
        scanner.delegate = self
        let broadcaster = Advertiser(connectionManager: manager)
        broadcaster.delegate = self
        connectionManager = manager
        discoverer = scanner
        advertiser = broadcaster
        status = "Searching for compatible phones. Up to four peer links; generated bytes only."
        startPresence()
    }

    private func startPresence() {
        guard mayStartWork, !finishingInBackground, let localContext, let manager = connectionManager else { return }
        if !discoveryRunning, let scanner = discoverer {
            discoveryRunning = true
            scanner.startDiscovery(mediums: [.ble]) { [weak self, weak scanner, weak manager] error in
                DispatchQueue.main.async {
                    guard let self, let manager, let scanner, self.connectionManager === manager,
                          self.discoverer === scanner, self.mayStartWork else { return }
                    if let error { self.transportFailed("discovery_failed", error: error) }
                    else if self.record("discovery_started", fields: ["requested_medium": "ble"]) {
                        // Nearby has instantiated its CBManagers. The Live Activity starts locally in the foreground.
                        self.startActivityIfAvailable()
                    }
                }
            }
        }
        if !advertisingRunning, let broadcaster = advertiser {
            advertisingRunning = true
            broadcaster.startAdvertising(using: Data(localContext.encoded.utf8), mediums: [.ble]) { [weak self, weak broadcaster, weak manager] error in
                DispatchQueue.main.async {
                    guard let self, let manager, let broadcaster, self.connectionManager === manager,
                          self.advertiser === broadcaster, self.mayStartWork else { return }
                    if let error { self.transportFailed("advertising_failed", error: error) }
                    else { _ = self.record("advertising_started", fields: ["requested_medium": "ble"]) }
                }
            }
        }
    }

    private func transportFailed(_ event: String, error: Error) {
        guard recordSDKError(event, error: error) else { return }
        awaitingResume = true
        pauseTransport(reason: "Bluetooth discovery could not start. Check permissions and radios, then tap Resume.")
    }

    func isCurrent(_ link: ProbeLink) -> Bool {
        state?.intendedActive == true && !awaitingResume && links[link.endpointID] === link && pool.contains(link.reservation)
    }

    private func candidateIsEligible(_ candidate: ProbePeerCandidate) -> Bool {
        guard let state,
              (retryCounts[candidate.context.sessionID] ?? 0) <= 5,
              (eligibleAfter[candidate.context.sessionID] ?? 0) <= ProcessInfo.processInfo.systemUptime else { return false }
        guard let peer = state.peer(candidate.context.sessionID) else { return state.peers.count < 8 }
        guard let completed = peer.completedAt else { return true }
        let age = Date().timeIntervalSince(completed)
        return age >= 0 && age < 60 && (catchUpLinks[peer.sessionID] ?? 0) < 1 && (catchUpRequests[peer.sessionID] ?? 0) < 3
    }

    private func fillSlots() {
        guard mayStartWork, !finishingInBackground, restartWork == nil, let scanner = discoverer,
              let manager = connectionManager, let localContext else { return }
        while let reservation = pool.reserveNext(eligible: { self.candidateIsEligible($0) }) {
            guard let link = makeLink(reservation, manager: manager) else { continue }
            scanner.requestConnection(to: link.endpointID, using: Data(localContext.encoded.utf8), mediums: [.ble]) { [weak self, weak manager, weak link] error in
                DispatchQueue.main.async {
                    guard let self, let manager, let link, self.connectionManager === manager,
                          self.isCurrent(link), let error else { return }
                    self.recordSDKError("connection_request_failed", error: error, peer: link.remote)
                    self.linkFailed(link, reason: "connection_request_failed")
                }
            }
        }
        refreshPublishedState()
        // Replacing the shared SDK only after every other peer drains preserves
        // healthy links and gives ambiguous old endpoint callbacks no new owner.
        if links.isEmpty, journalCannotContinue {
            awaitingResume = true
            pauseTransport(reason: "Eight-peer test journal is full. Export logs and start a new session, or Resume to retry saved peers.")
            return
        }
        if links.isEmpty, pool.retiredCount > 0 { restartTransportWhenIdle(); return }
        refillWork?.cancel(); refillWork = nil
        let now = ProcessInfo.processInfo.systemUptime
        if let next = eligibleAfter.values.filter({ $0 > now }).min() {
            let work = DispatchWorkItem { [weak self] in self?.fillSlots() }
            refillWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, next - now), execute: work)
        }
    }

    private var journalCannotContinue: Bool {
        guard let state, state.peers.count == 8 else { return false }
        return state.peers.allSatisfy { peer in
            peer.completedAt != nil || (retryCounts[peer.sessionID] ?? 0) > 5
        }
    }

    private func makeLink(_ reservation: ProbePeerReservation, manager: ConnectionManager) -> ProbeLink? {
        guard var next = state else { _ = pool.release(reservation); return nil }
        let candidate = reservation.candidate
        do {
            try next.bindPeer(candidate.context.sessionID)
            try next.prepareLink(to: candidate.context.sessionID)
        } catch {
            _ = pool.release(reservation)
            _ = record("unknown_peer_skipped_journal_full", fields: ["peer_session_id": candidate.context.sessionID])
            return nil
        }
        guard commit(next) else { return nil }
        let catchUp = next.peer(candidate.context.sessionID)?.completedAt != nil
        if catchUp { catchUpRequests[candidate.context.sessionID, default: 0] += 1 }
        eligibleAfter.removeValue(forKey: candidate.context.sessionID)
        let link = ProbeLink(reservation: reservation, catchUp: catchUp, host: self) { [weak self, weak manager] bytes, id, completion in
            guard let self, let manager, self.connectionManager === manager,
                  self.links[candidate.endpointID]?.reservation == reservation else { return }
            _ = manager.send(bytes, to: [candidate.endpointID], id: id) { [weak self, weak manager] error in
                DispatchQueue.main.async {
                    guard let self, let manager, self.connectionManager === manager,
                          self.links[candidate.endpointID]?.reservation == reservation else { return }
                    completion(error)
                }
            }
        }
        links[candidate.endpointID] = link
        link.beginConnecting()
        guard record("peer_discovered", fields: ["peer_session_id": link.remote]) else { return nil }
        refreshPublishedState()
        return link
    }

    func linkChanged(_ link: ProbeLink, successfulAttempt: Bool) {
        guard isCurrent(link) else { return }
        status = "\(links.count) peer links. Sent \(successfulAttempts); received \(receivedAttempts) generated payloads."
        if successfulAttempt { retryCounts[link.remote] = 0 }
        updateActivity()
        if finishingInBackground, !links.values.contains(where: { $0.pendingAttempt != nil }) {
            pauseTransport(reason: "Current attempts finished; session saved until TrailMesh is active.")
        }
    }

    func linkFailed(_ link: ProbeLink, reason: String) {
        guard isCurrent(link), record("connection_interrupted", fields: ["peer_session_id": link.remote, "failure_reason": reason]) else { return }
        let retry = link.catchUp ? 1 : min(6, (retryCounts[link.remote] ?? 0) + 1)
        if !link.catchUp { retryCounts[link.remote] = retry }
        eligibleAfter[link.remote] = ProcessInfo.processInfo.systemUptime + ProbeRecoveryPolicy.delay(forRetry: retry)
        release(link)
        status = "One peer interrupted; other links continue. Waiting phones receive the next slots."
        fillSlots()
    }

    func linkCompleted(_ link: ProbeLink) {
        guard isCurrent(link) else { return }
        if link.catchUp { catchUpLinks[link.remote, default: 0] += 1 }
        retryCounts[link.remote] = 0
        eligibleAfter[link.remote] = ProcessInfo.processInfo.systemUptime + 2
        release(link)
        status = "Peer batch complete. Other links and discovery continue."
        updateActivity()
        fillSlots()
    }

    private func release(_ link: ProbeLink) {
        links.removeValue(forKey: link.endpointID)
        _ = pool.release(link.reservation)
        link.cancel()
        connectionManager?.disconnect(from: link.endpointID)
        refreshPublishedState()
    }

    private func restartTransportWhenIdle() {
        guard links.isEmpty, restartWork == nil else { return }
        tearDownTransport()
        guard mayStartWork else { return }
        let session = sessionGeneration
        let generation = transportGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.sessionGeneration == session, self.transportGeneration == generation else { return }
            self.restartWork = nil
            self.startTransport()
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func tearDownTransport() {
        transportGeneration &+= 1
        refillWork?.cancel(); refillWork = nil
        restartWork?.cancel(); restartWork = nil
        let previous = Array(links.values)
        links.removeAll()
        pool.reset()
        for link in previous { link.cancel() }
        discoverer?.delegate = nil
        advertiser?.delegate = nil
        connectionManager?.delegate = nil
        discoverer?.stopDiscovery()
        advertiser?.stopAdvertising()
        for link in previous { connectionManager?.disconnect(from: link.endpointID) }
        discoverer = nil
        advertiser = nil
        connectionManager = nil
        discoveryRunning = false
        advertisingRunning = false
        finishingInBackground = false
        endBackgroundTask()
        refreshPublishedState()
    }

    private func pauseTransport(reason: String) {
        tearDownTransport()
        status = reason
        backgroundPolicy = "Progress saved; automatic foreground recovery"
        updateActivity()
    }

    private func finishCurrentAttemptOrPause() {
        finishingInBackground = true
        discoverer?.stopDiscovery(); discoveryRunning = false
        advertiser?.stopAdvertising(); advertisingRunning = false
        refillWork?.cancel(); refillWork = nil
        backgroundPolicy = "Finishing current attempts, then saving for foreground recovery"
        if links.values.contains(where: { $0.pendingAttempt != nil }) {
            beginBackgroundTaskIfNeeded()
            status = "Finishing current attempts before pausing every link…"
            _ = record("background_finishing_current_attempt")
        } else {
            guard record("background_transport_paused") else { return }
            pauseTransport(reason: "Session saved; exchanges resume when TrailMesh is active.")
        }
        updateActivity()
    }

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTask == .invalid else { return }
        let generation = sessionGeneration
        backgroundTaskGeneration &+= 1
        let assertion = backgroundTaskGeneration
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish TrailMesh test exchanges") { [weak self] in
            // UIKit invokes expiration synchronously on main. A stale assertion was already ended;
            // it must never release a newer task. End this assertion before checkpoint cleanup.
            guard let self, self.backgroundTaskGeneration == assertion, self.backgroundTask != .invalid else { return }
            let currentOwner = self.sessionGeneration == generation
            self.endBackgroundTask()
            guard currentOwner else { return }
            guard self.record("background_time_expired") else { return }
            self.pauseTransport(reason: "Background time ended. Pending attempts saved for automatic foreground recovery.")
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        let old = backgroundTask
        backgroundTask = .invalid
        backgroundTaskGeneration &+= 1
        UIApplication.shared.endBackgroundTask(old)
    }

    private func startActivityIfAvailable() {
        guard foreground, connectionManager != nil, state?.intendedActive == true, !activitySuppressed,
              #available(iOS 26.0, *), let state else { return }
        let activity: ProbeLiveActivity
        if let existing = activityObject as? ProbeLiveActivity { activity = existing }
        else { activity = ProbeLiveActivity(); activityObject = activity }
        let generation = sessionGeneration
        activity.availabilityChanged = { [weak self, weak activity] allowed in
            guard let self, let activity, self.activityObject === activity,
                  self.sessionGeneration == generation, self.state?.intendedActive == true else { return }
            if !allowed {
                self.activitySuppressed = true
                self.backgroundPolicy = "Live Activity ended or unavailable; automatic foreground recovery"
                guard self.record("background_activity_unavailable") else { return }
                if !self.foreground { self.finishCurrentAttemptOrPause() }
            }
        }
        let content = ProbeActivityAttributes.ContentState(status: status, sent: successfulAttempts, failed: failedAttempts, received: receivedAttempts)
        if activity.start(sessionID: state.sessionID, content: content) {
            backgroundPolicy = "Live Activity Bluetooth is best effort; concurrent screen-off delivery is unverified"
        } else { _ = record("background_activity_start_unavailable") }
    }

    private func updateActivity() {
        if #available(iOS 16.1, *), let activity = activityObject as? ProbeLiveActivity {
            activity.update(ProbeActivityAttributes.ContentState(status: status, sent: successfulAttempts, failed: failedAttempts, received: receivedAttempts))
        }
    }

    private func endActivity() {
        if #available(iOS 16.1, *), let activity = activityObject as? ProbeLiveActivity { activity.end() }
        // The system can retain activities across process termination, before a new controller exists.
        if #available(iOS 16.2, *) { ProbeLiveActivity.endAllOwnedActivities() }
        activityObject = nil
    }

    @discardableResult
    func commit(_ next: ProbeSessionState) -> Bool {
        do {
            try store.save(next)
            state = next
            refreshPublishedState()
            return true
        } catch {
            awaitingResume = true
            tearDownTransport()
            status = "Checkpoint could not be saved. Transport paused; no success acknowledgement was sent."
            updateActivity()
            return false
        }
    }

    func append(_ event: String, fields: [String: String], to next: inout ProbeSessionState) {
        var fields = fields
        if event == "connected" { fields["lifecycle"] = foreground ? "foreground" : "background" }
        next.appendRecord(ProbeLogEntry(event: event, observedAt: ISO8601DateFormatter().string(from: Date()), fields: fields))
    }

    @discardableResult
    private func record(_ event: String, fields: [String: String] = [:]) -> Bool {
        guard var next = state else { return false }
        append(event, fields: fields, to: &next)
        return commit(next)
    }

    @discardableResult
    private func recordSDKError(_ event: String, error: Error, peer: String? = nil) -> Bool {
        let error = error as NSError
        var fields = ["error_domain": String(error.domain.prefix(120)), "error_code": "\(error.code)"]
        if let peer { fields["peer_session_id"] = peer }
        return record(event, fields: fields)
    }

    private func refreshPublishedState() {
        sessionActive = state?.intendedActive == true
        successfulAttempts = state?.peers.reduce(0) { $0 + $1.successful } ?? 0
        failedAttempts = state?.peers.reduce(0) { $0 + $1.failed } ?? 0
        receivedAttempts = state?.peers.reduce(0) { $0 + $1.receivedAttempts.count } ?? 0
        duplicateAttempts = state?.peers.reduce(0) { $0 + $1.duplicates } ?? 0
        completedPeers = state?.peers.filter { $0.completedAt != nil }.count ?? 0
        activePeers = links.count
        waitingPeers = pool.waitingCount
        logs = state?.records.map {
            let attempt = $0.fields["attempt_index"].map { " #\($0)" } ?? ""
            let result = $0.fields["success"].map { $0 == "true" ? ": success" : ": failed" } ?? ""
            return "\($0.event)\(attempt)\(result)"
        } ?? []
    }
}

extension ProbeModel: DiscovererDelegate, AdvertiserDelegate, ConnectionManagerDelegate {
    func discoverer(_ discoverer: Discoverer, didFind endpointID: EndpointID, with context: Data) {
        guard self.discoverer === discoverer, mayStartWork, !finishingInBackground,
              let remote = ProbePeerContext.parse(context), let localContext,
              localContext.isCompatible(with: remote), localContext.canInitiate(to: remote) else { return }
        _ = pool.offer(ProbePeerCandidate(endpointID: endpointID, context: remote))
        fillSlots()
    }

    func discoverer(_ discoverer: Discoverer, didLose endpointID: EndpointID) {
        guard self.discoverer === discoverer else { return }
        pool.removeWaiting(endpointID: endpointID)
        refreshPublishedState()
        // Discovery loss does not establish that an existing connection has failed.
    }

    func advertiser(_ advertiser: Advertiser, didReceiveConnectionRequestFrom endpointID: EndpointID,
                    with context: Data, connectionRequestHandler: @escaping (Bool) -> Void) {
        guard self.advertiser === advertiser, mayStartWork, !finishingInBackground,
              let manager = connectionManager, let localContext,
              let remote = ProbePeerContext.parse(context), remote.canInitiate(to: localContext) else {
            connectionRequestHandler(false); return
        }
        let candidate = ProbePeerCandidate(endpointID: endpointID, context: remote)
        guard candidateIsEligible(candidate), let reservation = pool.reserveIncoming(candidate),
              makeLink(reservation, manager: manager) != nil else { connectionRequestHandler(false); return }
        connectionRequestHandler(true)
    }

    func connectionManager(_ connectionManager: ConnectionManager, didReceive verificationCode: String,
                           from endpointID: EndpointID, verificationHandler: @escaping (Bool) -> Void) {
        guard self.connectionManager === connectionManager, let link = links[endpointID], isCurrent(link), mayStartWork else {
            verificationHandler(false); return
        }
        // Automatic verification remains limited to generated synthetic test bytes.
        let saved = record("sdk_verification_code_auto_accepted_test_mode", fields: ["peer_session_id": link.remote])
        verificationHandler(saved && isCurrent(link))
    }

    func connectionManager(_ connectionManager: ConnectionManager, didReceive data: Data,
                           withID payloadID: PayloadID, from endpointID: EndpointID) {
        guard self.connectionManager === connectionManager else { return }
        links[endpointID]?.receive(data)
    }

    func connectionManager(_ connectionManager: ConnectionManager, didReceive stream: InputStream, withID payloadID: PayloadID,
                           from endpointID: EndpointID, cancellationToken token: CancellationToken) {
        token.cancel()
        guard self.connectionManager === connectionManager else { return }
        links[endpointID]?.rejectUnsupportedPayload()
    }

    func connectionManager(_ connectionManager: ConnectionManager, didStartReceivingResourceWithID payloadID: PayloadID,
                           from endpointID: EndpointID, at localURL: URL, withName name: String, cancellationToken token: CancellationToken) {
        token.cancel()
        guard self.connectionManager === connectionManager else { return }
        links[endpointID]?.rejectUnsupportedPayload()
    }

    func connectionManager(_ connectionManager: ConnectionManager, didReceiveTransferUpdate update: TransferUpdate,
                           from endpointID: EndpointID, forPayload payloadID: PayloadID) {
        guard self.connectionManager === connectionManager, let link = links[endpointID] else { return }
        switch update {
        case .failure, .canceled: link.transferUpdated(payloadID: payloadID, succeeded: false)
        case .success: link.transferUpdated(payloadID: payloadID, succeeded: true)
        case .progress: break
        }
    }

    func connectionManager(_ connectionManager: ConnectionManager, didChangeTo state: ConnectionState, for endpointID: EndpointID) {
        guard self.connectionManager === connectionManager, let link = links[endpointID], isCurrent(link) else { return }
        switch state {
        case .connected: link.didConnect()
        case .connecting: break
        case .disconnected: linkFailed(link, reason: "peer_disconnected")
        case .rejected: linkFailed(link, reason: "connection_rejected")
        }
    }
}
