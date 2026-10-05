import Foundation
import Combine
import NearbyConnections
import UIKit

/// App-owned session intention and progress; SDK objects belong to one disposable transport link.
final class ProbeModel: ObservableObject {
    @Published private(set) var status = "Ready to start"
    @Published private(set) var sessionActive = false
    @Published private(set) var awaitingResume = false
    @Published private(set) var successfulAttempts = 0
    @Published private(set) var failedAttempts = 0
    @Published private(set) var receivedAttempts = 0
    @Published private(set) var duplicateAttempts = 0
    @Published private(set) var completedPeers = 0
    @Published private(set) var logs: [String] = []
    @Published private(set) var backgroundPolicy = "Saved progress and automatic foreground recovery"

    private var state: ProbeSessionState?
    private let store: ProbeCheckpointStore
    private let serviceID = "org.trailmesh.foregroundprobe"
    private var connectionManager: ConnectionManager?
    private var discoverer: Discoverer?
    private var endpointID: EndpointID?
    private var peerSessionID: String?
    private var sessionGeneration = 0
    private var linkGeneration = 0
    private var foreground = UIApplication.shared.applicationState != .background
    private var connected = false
    private var ready = false
    private var helloReceived = false
    private var helloSent = false
    private var helloTransmissions = 0
    private var finishTransmissions = 0
    private var connectionRetries = 0
    private var inboundFrames = 0
    private var catchUpLinks: [String: Int] = [:]
    private var catchUpRequests: [String: Int] = [:]
    private var currentLinkIsCatchUp = false
    private var pendingAttempt: Int?
    private var pendingDigest: Data?
    private var pendingPayloadID: PayloadID?
    private var finishAckPayloads: [PayloadID: String] = [:]
    private var connectionDeadline: DispatchWorkItem?
    private var helloDeadline: DispatchWorkItem?
    private var ackDeadline: DispatchWorkItem?
    private var finishDeadline: DispatchWorkItem?
    private var peerProgressDeadline: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?
    private var completionWork: DispatchWorkItem?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var backgroundTaskGeneration = 0
    private var finishingInBackground = false
    private var activityObject: AnyObject?
    private var activitySuppressed = false

    init(store: ProbeCheckpointStore = .applicationStore) {
        self.store = store
        do {
            state = try store.load()
            awaitingResume = state?.intendedActive == true
            refreshPublishedState()
            if awaitingResume { status = "Interrupted session saved. Tap Resume to continue." }
        } catch { status = "Saved checkpoint could not be read. Start a new session." }
    }

    var selectedPayloadSize: Int { state?.payloadSize ?? 2048 }

    var exportJSON: String {
        let device = UIDevice.current
        let document: [String: Any] = [
            "schema": "trailmesh.foreground-probe-log", "version": 2, "probe_protocol": 2, "platform": "ios",
            "session_id": state?.sessionID ?? "",
            "device": ["model": device.model, "os_version": device.systemVersion,
                       "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                       "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"],
            "transport": "Google Nearby Connections", "strategy": "pointToPoint",
            "pairing_mode": "automatic", "transport_role": "discoverer", "requested_medium": "ble",
            "underlying_medium": "SDK selected within BLE policy; physical validation required",
            "automatic_test_acceptance": true, "internet_disabled": NSNull(),
            "session_intended_active": state?.intendedActive ?? false, "background_policy": backgroundPolicy,
            "completed_peers": completedPeers, "sent_successful": successfulAttempts, "sent_failed": failedAttempts,
            "received_unique": receivedAttempts, "received_duplicates": duplicateAttempts,
            "attempts": state?.records.map(\.exported) ?? []
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
        catchUpLinks.removeAll()
        catchUpRequests.removeAll()
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var next = ProbeSessionState(sessionID: id, payloadSize: payloadSize)
        append("session_started", fields: ["payload_size_bytes": "\(payloadSize)", "pairing_mode": "automatic"], to: &next)
        guard commit(next) else { return }
        awaitingResume = false
        connectionRetries = 0
        if foreground { startTransport() }
        else { pauseTransport(reason: "Session saved; return to TrailMesh to connect.") }
    }

    func resume() {
        guard state?.intendedActive == true, foreground else { return }
        awaitingResume = false
        connectionRetries = 0
        guard record("session_resumed") else { return }
        if connectionManager == nil { startTransport() }
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
        if ProbeRecoveryPolicy.shouldResume(intendedActive: state?.intendedActive == true,
                                           foreground: foreground, transportRunning: connectionManager != nil) {
            connectionRetries = 0
            guard record("foreground_recovery") else { return }
            startTransport()
        } else {
            startActivityIfAvailable()
            if ready { sendNextAttempt(); sendFinishIfNeeded() }
        }
    }

    func sceneEnteredBackground() {
        foreground = false
        guard state?.intendedActive == true, !awaitingResume, record("entered_background") else { return }
        if backgroundBluetoothAllowed {
            backgroundPolicy = "Live Activity Bluetooth is best effort; screen-off delivery is unverified"
            status = "Session saved and available for Bluetooth events; background delivery is best effort."
            updateActivity()
        } else { finishCurrentAttemptOrPause() }
    }

    func enableBackgroundActivity() {
        activitySuppressed = false
        startActivityIfAvailable()
    }

    private var backgroundBluetoothAllowed: Bool {
        if #available(iOS 26.0, *), let activity = activityObject as? ProbeLiveActivity {
            return activity.allowsBackgroundBluetooth
        }
        return false
    }

    private var mayStartWork: Bool {
        state?.intendedActive == true && !awaitingResume && (foreground || backgroundBluetoothAllowed)
    }

    private func startTransport() {
        guard mayStartWork, connectionManager == nil else { return }
        linkGeneration &+= 1
        let manager = ConnectionManager(serviceID: serviceID, strategy: .pointToPoint)
        manager.delegate = self
        let scanner = Discoverer(connectionManager: manager)
        scanner.delegate = self
        connectionManager = manager
        discoverer = scanner
        status = "Searching for Android; Bluetooth only. Both phones exchange 20 attempts."
        let generation = sessionGeneration
        scanner.startDiscovery(mediums: [.ble]) { [weak self, weak scanner, weak manager] error in
            DispatchQueue.main.async {
                guard let self, let scanner, let manager, self.sessionGeneration == generation,
                      self.discoverer === scanner, self.connectionManager === manager, self.sessionActive else { return }
                if let error {
                    self.recordSDKError("discovery_failed", error: error)
                    self.recoverConnection(reason: "discovery_failed")
                } else if self.record("discovery_started", fields: ["requested_medium": "ble"]) {
                    // Nearby has instantiated its CBManagers. The Live Activity starts locally in the foreground.
                    self.startActivityIfAvailable()
                }
            }
        }
    }

    private func isCurrent(_ manager: ConnectionManager, endpoint: EndpointID? = nil) -> Bool {
        state?.intendedActive == true && !awaitingResume && connectionManager === manager
        && (endpoint == nil || endpointID == endpoint)
    }

    private func schedule(after delay: TimeInterval, action: @escaping (ProbeModel) -> Void) -> DispatchWorkItem {
        let session = sessionGeneration
        let link = linkGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.sessionGeneration == session, self.linkGeneration == link,
                  self.state?.intendedActive == true, !self.awaitingResume else { return }
            action(self)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return work
    }

    private func recoverConnection(reason: String) {
        guard state?.intendedActive == true, !awaitingResume,
              record("connection_interrupted", fields: ["failure_reason": reason]) else { return }
        let catchUp = currentLinkIsCatchUp
        tearDownTransport()
        guard mayStartWork else {
            status = "Session saved. Connections resume when TrailMesh is active."
            return
        }
        if catchUp {
            // Completed peers have their own bounded reconciliation budget. They cannot exhaust
            // normal recovery or prevent discovery of a new peer that still needs DATA.
            status = "Completion reconciliation interrupted; searching for another peer…"
            retryWork = schedule(after: 0.5) { $0.startTransport() }
            return
        }
        connectionRetries += 1
        guard ProbeRecoveryPolicy.canRetry(connectionRetries) else {
            _ = record("connection_retry_limit")
            awaitingResume = true
            status = "Connection recovery paused after five retries. Tap Resume to try again."
            updateActivity()
            return
        }
        let retry = connectionRetries
        let delay = ProbeRecoveryPolicy.delay(forRetry: retry)
        status = "Reconnecting in \(Int(delay)) seconds (retry \(retry)/5)…"
        guard record("connection_retry_scheduled", fields: ["retry": "\(retry)"]) else { return }
        retryWork = schedule(after: delay) { $0.startTransport() }
        updateActivity()
    }

    private func tearDownTransport() {
        linkGeneration &+= 1
        [connectionDeadline, helloDeadline, ackDeadline, finishDeadline, peerProgressDeadline, retryWork, completionWork].forEach { $0?.cancel() }
        connectionDeadline = nil; helloDeadline = nil; ackDeadline = nil
        finishDeadline = nil; peerProgressDeadline = nil; retryWork = nil; completionWork = nil
        let scanner = discoverer
        let manager = connectionManager
        let previousEndpoint = endpointID
        discoverer = nil; connectionManager = nil; endpointID = nil; peerSessionID = nil
        scanner?.delegate = nil
        manager?.delegate = nil
        scanner?.stopDiscovery()
        if let previousEndpoint { manager?.disconnect(from: previousEndpoint) }
        connected = false; ready = false; helloReceived = false; helloSent = false
        helloTransmissions = 0; finishTransmissions = 0; inboundFrames = 0
        pendingAttempt = nil; pendingDigest = nil; pendingPayloadID = nil
        finishAckPayloads.removeAll()
        finishingInBackground = false
        currentLinkIsCatchUp = false
        endBackgroundTask()
    }

    private func pauseTransport(reason: String) {
        tearDownTransport()
        status = reason
        backgroundPolicy = "Progress saved; automatic foreground recovery"
        updateActivity()
    }

    private func sendHello() {
        guard connected, let manager = connectionManager, let endpointID, let remote = peerSessionID, let state else { return }
        helloDeadline?.cancel()
        guard helloTransmissions < 3 else { recoverConnection(reason: "hello_timeout"); return }
        helloTransmissions += 1
        do {
            let message = try ForegroundFrame.encodeHelloMessage(sessionID: state.sessionID, peerSessionID: remote, payloadSize: state.payloadSize)
            sendControl(message, manager: manager, endpoint: endpointID) { model, error in
                if error != nil { model.recoverConnection(reason: "hello_send_failed"); return }
                model.helloSent = true
                model.becomeReadyIfPossible()
            }
            helloDeadline = schedule(after: 10) { model in if !model.ready { model.sendHello() } }
        } catch { recoverConnection(reason: "hello_encoding_failed") }
    }

    private func becomeReadyIfPossible() {
        guard !ready, helloSent, helloReceived, connected, let remote = peerSessionID else { return }
        ready = true
        helloDeadline?.cancel()
        guard record("peer_ready", fields: ["direction": "bidirectional"]) else { return }
        status = "Connected. Sending and receiving generated test bytes."
        if let peer = state?.peer(remote), peer.remoteFinished {
            sendRemoteFinishAcknowledgement(successful: peer.remoteSuccessful!, failed: peer.remoteFailed!)
        }
        sendNextAttempt()
        sendFinishIfNeeded()
        updateActivity()
    }

    private func sendNextAttempt() {
        guard mayStartWork, !finishingInBackground, ready, pendingAttempt == nil,
              let remote = peerSessionID, let endpointID, let manager = connectionManager,
              var next = state, let peer = next.peer(remote) else { return }
        guard !peer.outgoingComplete else { sendFinishIfNeeded(); return }
        if peer.transmissions >= 3 {
            finishAttempt(success: false, reason: "transmission_limit", attempt: peer.nextAttempt)
            return
        }
        do {
            let attempt = try next.beginTransmission(to: remote)
            let payload = try ForegroundFrame.makeTestPayload(size: next.payloadSize, attemptIndex: attempt)
            let digest = ForegroundFrame.digest(payload)
            let message = try ForegroundFrame.encodeSessionDataMessage(sessionID: next.sessionID, attemptIndex: attempt, payload: payload)
            append("payload_sent", fields: ["attempt_index": "\(attempt)", "payload_size_bytes": "\(next.payloadSize)",
                   "transmission": "\(next.peer(remote)!.transmissions)", "peer_session_id": remote,
                   "expected_sha256": ForegroundFrame.hex(digest), "direction": "iphone-to-android"], to: &next)
            guard commit(next) else { return }
            pendingAttempt = attempt; pendingDigest = digest
            let payloadID = Int64.random(in: 1...Int64.max)
            pendingPayloadID = payloadID
            let session = sessionGeneration; let link = linkGeneration
            _ = manager.send(message, to: [endpointID], id: payloadID) { [weak self, weak manager] error in
                DispatchQueue.main.async {
                    guard let self, let manager, self.isCurrent(manager, endpoint: endpointID),
                          self.sessionGeneration == session, self.linkGeneration == link,
                          self.pendingAttempt == attempt, self.pendingPayloadID == payloadID, error != nil else { return }
                    self.transmissionFailed(reason: "payload_send_failed")
                }
            }
            ackDeadline = schedule(after: 15) { model in
                if model.pendingAttempt == attempt, model.pendingPayloadID == payloadID { model.transmissionFailed(reason: "acknowledgement_timeout") }
            }
        } catch { recoverConnection(reason: "payload_encoding_failed") }
    }

    private func transmissionFailed(reason: String) {
        guard let attempt = pendingAttempt, let remote = peerSessionID, let peer = state?.peer(remote) else { return }
        ackDeadline?.cancel()
        pendingAttempt = nil; pendingDigest = nil; pendingPayloadID = nil
        endBackgroundTask()
        guard record("transmission_failed", fields: ["attempt_index": "\(attempt)", "peer_session_id": remote, "failure_reason": reason]) else { return }
        if peer.transmissions >= 3 { finishAttempt(success: false, reason: reason, attempt: attempt) }
        else if finishingInBackground || !mayStartWork { pauseTransport(reason: "Unacknowledged attempt saved; will resume when active.") }
        else {
            retryWork?.cancel()
            retryWork = schedule(after: 0.5) { $0.sendNextAttempt() }
        }
    }

    private func finishAttempt(success: Bool, reason: String?, attempt: Int, receivedDigest: Data? = nil) {
        guard let remote = peerSessionID, var next = state else { return }
        do {
            guard try next.finishAttempt(to: remote, attempt: attempt, success: success) else { return }
            let expected = try ForegroundFrame.makeTestPayload(size: next.payloadSize, attemptIndex: attempt)
            var fields = ["attempt_index": "\(attempt)", "success": "\(success)", "payload_size_bytes": "\(next.payloadSize)",
                          "peer_session_id": remote, "direction": "iphone-to-android", "expected_sha256": ForegroundFrame.digestHex(expected)]
            if let reason { fields["failure_reason"] = reason }
            if let receivedDigest { fields["received_sha256"] = ForegroundFrame.hex(receivedDigest) }
            append("attempt_result", fields: fields, to: &next)
            guard commit(next) else { return }
            ackDeadline?.cancel()
            pendingAttempt = nil; pendingDigest = nil; pendingPayloadID = nil
            endBackgroundTask()
            if success { connectionRetries = 0 }
            status = "Sent: \(successfulAttempts) succeeded, \(failedAttempts) failed. Received: \(receivedAttempts) unique."
            updateActivity()
            if finishingInBackground || !mayStartWork { pauseTransport(reason: "Current attempt finished; session saved until TrailMesh is active.") }
            else {
                retryWork?.cancel()
                retryWork = schedule(after: 0.1) { model in model.sendNextAttempt(); model.sendFinishIfNeeded() }
            }
        } catch { recoverConnection(reason: "attempt_state_invalid") }
    }

    private func receiveData(_ message: ProbeSessionDataMessage, manager: ConnectionManager, endpoint: EndpointID) {
        guard ready, let remote = peerSessionID, message.sessionID == remote, let state,
              message.frame.payload.count == state.payloadSize, (0..<20).contains(message.attemptIndex) else {
            _ = record("unexpected_session_data"); return
        }
        do {
            let expected = try ForegroundFrame.makeTestPayload(size: state.payloadSize, attemptIndex: message.attemptIndex)
            let accepted = expected == message.frame.payload
            var next = state
            let unique: Bool
            if accepted { unique = try next.recordReceived(from: remote, attempt: message.attemptIndex) }
            else { unique = false }
            append(unique ? "payload_received" : accepted ? "duplicate_payload_received" : "payload_rejected",
                   fields: ["attempt_index": "\(message.attemptIndex)", "payload_size_bytes": "\(state.payloadSize)",
                            "peer_session_id": remote, "expected_sha256": ForegroundFrame.digestHex(expected),
                            "received_sha256": ForegroundFrame.hex(message.frame.digest), "success": "\(accepted)", "direction": "android-to-iphone"], to: &next)
            // Commit deduplication before acknowledging. A failed write never emits a positive ACK.
            guard commit(next) else { return }
            if let peer = next.peer(remote), ProbeRecoveryPolicy.shouldRenewReciprocalDeadline(uniqueReceived: unique, peer: peer) {
                armReciprocalProgressDeadline()
            }
            let ack = try ForegroundFrame.encodeSessionAckMessage(sessionID: remote, attemptIndex: message.attemptIndex, accepted: accepted, digest: message.frame.digest)
            sendControl(ack, manager: manager, endpoint: endpoint) { model, error in
                if error != nil { _ = model.record("acknowledgement_send_failed") }
            }
            updateActivity()
        } catch { _ = record("invalid_session_data") }
    }

    private func receiveAck(_ message: ProbeSessionAckMessage) {
        guard ready, message.sessionID == state?.sessionID, message.attemptIndex == pendingAttempt, let expected = pendingDigest else {
            _ = record("unexpected_acknowledgement"); return
        }
        if message.accepted && message.digest == expected {
            finishAttempt(success: true, reason: nil, attempt: message.attemptIndex, receivedDigest: message.digest)
        } else { transmissionFailed(reason: "acknowledgement_or_checksum_mismatch") }
    }

    private func sendFinishIfNeeded() {
        guard mayStartWork, ready, let remote = peerSessionID, let peer = state?.peer(remote),
              peer.outgoingComplete, !peer.localFinishAcknowledged, finishDeadline == nil,
              let state, let manager = connectionManager, let endpointID else { return }
        guard finishTransmissions < 3 else { recoverConnection(reason: "finish_timeout"); return }
        finishTransmissions += 1
        do {
            let message = try ForegroundFrame.encodeFinishMessage(sessionID: state.sessionID, peerSessionID: remote,
                acknowledgement: false, successfulAttempts: peer.successful, failedAttempts: peer.failed)
            sendControl(message, manager: manager, endpoint: endpointID) { model, error in
                if error != nil { model.recoverConnection(reason: "finish_send_failed") }
            }
            finishDeadline = schedule(after: 10) { model in model.finishDeadline = nil; model.sendFinishIfNeeded() }
        } catch { recoverConnection(reason: "finish_encoding_failed") }
    }

    private func receiveFinish(_ message: ProbeFinishMessage) {
        guard ready, let remote = peerSessionID, message.sessionID == remote,
              message.peerSessionID == state?.sessionID, var next = state else { _ = record("unexpected_finish"); return }
        do {
            if message.acknowledgement {
                let wasAcknowledged = next.peer(remote)?.localFinishAcknowledged == true
                try next.recordLocalFinishAcknowledgement(from: remote, successful: message.successfulAttempts, failed: message.failedAttempts)
                append("local_finish_acknowledged", fields: ["peer_session_id": remote], to: &next)
                guard commit(next) else { return }
                finishDeadline?.cancel(); finishDeadline = nil
                if !wasAcknowledged { armReciprocalProgressDeadline() }
            } else {
                completionWork?.cancel(); completionWork = nil
                try next.recordRemoteFinish(from: remote, successful: message.successfulAttempts, failed: message.failedAttempts)
                append("remote_batch_finished", fields: ["peer_session_id": remote], to: &next)
                guard commit(next) else { return }
                if peerProgressDeadline == nil { armReciprocalProgressDeadline() }
                sendRemoteFinishAcknowledgement(successful: message.successfulAttempts, failed: message.failedAttempts)
            }
            completePeerIfPossible()
        } catch { _ = record("invalid_finish") }
    }

    private func sendRemoteFinishAcknowledgement(successful: Int, failed: Int) {
        guard let state, let remote = peerSessionID, let manager = connectionManager, let endpointID else { return }
        do {
            let message = try ForegroundFrame.encodeFinishMessage(sessionID: state.sessionID, peerSessionID: remote,
                acknowledgement: true, successfulAttempts: successful, failedAttempts: failed)
            let id = Int64.random(in: 1...Int64.max)
            finishAckPayloads[id] = remote
            sendControl(message, manager: manager, endpoint: endpointID, payloadID: id) { model, error in
                if error != nil {
                    model.finishAckPayloads.removeValue(forKey: id)
                    model.recoverConnection(reason: "finish_ack_send_failed")
                }
            }
        } catch { recoverConnection(reason: "finish_ack_encoding_failed") }
    }

    private func completePeerIfPossible() {
        guard let remote = peerSessionID, state?.peer(remote)?.complete == true,
              finishAckPayloads.isEmpty, completionWork == nil else { return }
        peerProgressDeadline?.cancel(); peerProgressDeadline = nil
        status = "Bidirectional batch complete. Finishing peer acknowledgement…"
        completionWork = schedule(after: 1) { model in
            guard model.state?.peer(remote)?.complete == true, model.finishAckPayloads.isEmpty else {
                model.completionWork = nil
                model.armReciprocalProgressDeadline()
                return
            }
            guard model.record("peer_batch_complete", fields: ["peer_session_id": remote]) else { return }
            if model.currentLinkIsCatchUp { model.catchUpLinks[remote] = (model.catchUpLinks[remote] ?? 0) + 1 }
            model.tearDownTransport()
            model.connectionRetries = 0
            model.status = "Peer batch complete. Searching for the next Android phone…"
            model.updateActivity()
            if model.mayStartWork { model.startTransport() }
        }
    }

    private func armReciprocalProgressDeadline() {
        guard let remote = peerSessionID, state?.peer(remote)?.needsReciprocalProgressDeadline == true else { return }
        peerProgressDeadline?.cancel()
        peerProgressDeadline = schedule(after: ProbeRecoveryPolicy.reciprocalProgressTimeout) { model in
            guard model.state?.peer(remote)?.needsReciprocalProgressDeadline == true else { return }
            model.recoverConnection(reason: "reciprocal_progress_timeout")
        }
    }

    private func sendControl(_ data: Data, manager: ConnectionManager, endpoint: EndpointID,
                             payloadID: PayloadID = Int64.random(in: 1...Int64.max),
                             completion: @escaping (ProbeModel, Error?) -> Void) {
        let session = sessionGeneration; let link = linkGeneration
        _ = manager.send(data, to: [endpoint], id: payloadID) { [weak self, weak manager] error in
            DispatchQueue.main.async {
                guard let self, let manager, self.isCurrent(manager, endpoint: endpoint),
                      self.sessionGeneration == session, self.linkGeneration == link else { return }
                completion(self, error)
            }
        }
    }

    private func finishCurrentAttemptOrPause() {
        finishingInBackground = true
        discoverer?.stopDiscovery()
        backgroundPolicy = "Finishing one attempt, then saving for foreground recovery"
        if pendingAttempt != nil {
            beginBackgroundTaskIfNeeded()
            status = "Finishing the current attempt before pausing transport…"
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
        let link = linkGeneration
        backgroundTaskGeneration &+= 1
        let assertion = backgroundTaskGeneration
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish TrailMesh test exchange") { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.sessionGeneration == generation, self.linkGeneration == link,
                      self.backgroundTaskGeneration == assertion, self.backgroundTask != .invalid else { return }
                _ = self.record("background_time_expired")
                self.pauseTransport(reason: "Background time ended. Pending attempt saved for automatic foreground recovery.")
            }
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
            backgroundPolicy = "Live Activity Bluetooth is best effort; screen-off delivery is unverified"
        } else {
            activitySuppressed = true
            backgroundPolicy = "Live Activity unavailable; automatic foreground recovery"
            _ = record("background_activity_start_unavailable")
        }
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
    private func commit(_ next: ProbeSessionState) -> Bool {
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

    private func append(_ event: String, fields: [String: String], to next: inout ProbeSessionState) {
        next.records.append(ProbeLogEntry(event: event, observedAt: ISO8601DateFormatter().string(from: Date()), fields: fields))
        if next.records.count > 512 { next.records.removeFirst(next.records.count - 512) }
    }

    @discardableResult
    private func record(_ event: String, fields: [String: String] = [:]) -> Bool {
        guard var next = state else { return false }
        append(event, fields: fields, to: &next)
        return commit(next)
    }

    private func recordSDKError(_ event: String, error: Error) {
        let error = error as NSError
        _ = record(event, fields: ["error_domain": String(error.domain.prefix(120)), "error_code": "\(error.code)"])
    }

    private func refreshPublishedState() {
        sessionActive = state?.intendedActive == true
        successfulAttempts = state?.peers.reduce(0) { $0 + $1.successful } ?? 0
        failedAttempts = state?.peers.reduce(0) { $0 + $1.failed } ?? 0
        receivedAttempts = state?.peers.reduce(0) { $0 + $1.receivedAttempts.count } ?? 0
        duplicateAttempts = state?.peers.reduce(0) { $0 + $1.duplicates } ?? 0
        completedPeers = state?.peers.filter { $0.completedAt != nil }.count ?? 0
        logs = state?.records.map {
            let attempt = $0.fields["attempt_index"].map { " #\($0)" } ?? ""
            let result = $0.fields["success"].map { $0 == "true" ? ": success" : ": failed" } ?? ""
            return "\($0.event)\(attempt)\(result)"
        } ?? []
    }
}

extension ProbeModel: DiscovererDelegate, ConnectionManagerDelegate {
    func discoverer(_ discoverer: Discoverer, didFind endpointID: EndpointID, with context: Data) {
        guard self.discoverer === discoverer, mayStartWork, self.endpointID == nil,
              let remote = ProbePeerContext.parse(context), let state else { return }
        let local = ProbePeerContext(platform: .ios, sessionID: state.sessionID, payloadSize: state.payloadSize)
        guard local.isCompatible(with: remote), local.canInitiate(to: remote) else { return }
        let catchUp = state.peer(remote.sessionID)?.completedAt != nil
        if catchUp, let completed = state.peer(remote.sessionID)?.completedAt {
            let age = Date().timeIntervalSince(completed)
            guard age >= 0, age < 60, (catchUpLinks[remote.sessionID] ?? 0) < 1,
                  (catchUpRequests[remote.sessionID] ?? 0) < 3 else { return }
            catchUpRequests[remote.sessionID] = (catchUpRequests[remote.sessionID] ?? 0) + 1
        }
        var next = state
        do { try next.bindPeer(remote.sessionID); try next.prepareLink(to: remote.sessionID) }
        catch {
            awaitingResume = true
            pauseTransport(reason: "Eight-peer journal is full. Export the log and start a new session.")
            return
        }
        guard commit(next), let manager = connectionManager else { return }
        self.endpointID = endpointID
        peerSessionID = remote.sessionID
        currentLinkIsCatchUp = catchUp
        linkGeneration &+= 1
        let session = sessionGeneration; let link = linkGeneration
        guard record("peer_discovered", fields: ["peer_session_id": remote.sessionID]) else { return }
        status = "Compatible Android found. Connecting…"
        discoverer.stopDiscovery()
        discoverer.requestConnection(to: endpointID, using: Data(local.encoded.utf8), mediums: [.ble]) { [weak self, weak manager] error in
            DispatchQueue.main.async {
                guard let self, let manager, self.isCurrent(manager, endpoint: endpointID),
                      self.sessionGeneration == session, self.linkGeneration == link, let error else { return }
                self.recordSDKError("connection_request_failed", error: error)
                self.recoverConnection(reason: "connection_request_failed")
            }
        }
        connectionDeadline = schedule(after: 20) { model in if !model.connected { model.recoverConnection(reason: "connection_timeout") } }
    }

    func discoverer(_ discoverer: Discoverer, didLose endpointID: EndpointID) {
        guard self.discoverer === discoverer else { return }
        if self.endpointID == endpointID, !connected { recoverConnection(reason: "peer_lost_while_connecting") }
    }

    func connectionManager(_ connectionManager: ConnectionManager, didReceive verificationCode: String,
                           from endpointID: EndpointID, verificationHandler: @escaping (Bool) -> Void) {
        let accepted = isCurrent(connectionManager, endpoint: endpointID) && mayStartWork
        if accepted { _ = record("sdk_verification_code_auto_accepted_test_mode") }
        verificationHandler(accepted && !awaitingResume)
    }

    func connectionManager(_ connectionManager: ConnectionManager, didReceive data: Data, withID payloadID: PayloadID, from endpointID: EndpointID) {
        guard isCurrent(connectionManager, endpoint: endpointID), connected else { return }
        guard inboundFrames < 256 else { recoverConnection(reason: "link_frame_limit"); return }
        inboundFrames += 1
        do {
            if ForegroundFrame.isHelloMessage(data) {
                let hello = try ForegroundFrame.decodeHelloMessage(data)
                guard hello.sessionID == peerSessionID, hello.peerSessionID == state?.sessionID,
                      hello.payloadSize == state?.payloadSize, hello.attemptCount == 20 else { recoverConnection(reason: "hello_mismatch"); return }
                helloReceived = true
                becomeReadyIfPossible()
            } else if ForegroundFrame.isFinishMessage(data) {
                receiveFinish(try ForegroundFrame.decodeFinishMessage(data))
            } else if ForegroundFrame.isSessionAckMessage(data) {
                receiveAck(try ForegroundFrame.decodeSessionAckMessage(data))
            } else {
                receiveData(try ForegroundFrame.decodeSessionDataMessage(data), manager: connectionManager, endpoint: endpointID)
            }
        } catch { _ = record("invalid_probe_frame") }
    }

    func connectionManager(_ connectionManager: ConnectionManager, didReceive stream: InputStream, withID payloadID: PayloadID,
                           from endpointID: EndpointID, cancellationToken token: CancellationToken) {
        token.cancel()
        if isCurrent(connectionManager, endpoint: endpointID) { _ = record("unexpected_stream_payload") }
    }

    func connectionManager(_ connectionManager: ConnectionManager, didStartReceivingResourceWithID payloadID: PayloadID,
                           from endpointID: EndpointID, at localURL: URL, withName name: String, cancellationToken token: CancellationToken) {
        token.cancel()
        if isCurrent(connectionManager, endpoint: endpointID) { _ = record("unexpected_file_payload") }
    }

    func connectionManager(_ connectionManager: ConnectionManager, didReceiveTransferUpdate update: TransferUpdate,
                           from endpointID: EndpointID, forPayload payloadID: PayloadID) {
        guard isCurrent(connectionManager, endpoint: endpointID) else { return }
        switch update {
        case .failure, .canceled:
            if pendingPayloadID == payloadID { transmissionFailed(reason: "nearby_transfer_failed") }
            else if finishAckPayloads.removeValue(forKey: payloadID) != nil { recoverConnection(reason: "finish_ack_transfer_failed") }
        case .success:
            if let remote = finishAckPayloads.removeValue(forKey: payloadID), var next = state {
                do {
                    try next.recordRemoteFinishAcknowledgementDelivered(to: remote)
                    if commit(next) { completePeerIfPossible() }
                } catch { recoverConnection(reason: "finish_ack_state_invalid") }
            }
        case .progress: break
        }
    }

    func connectionManager(_ connectionManager: ConnectionManager, didChangeTo state: ConnectionState, for endpointID: EndpointID) {
        guard isCurrent(connectionManager, endpoint: endpointID) else { return }
        switch state {
        case .connected:
            guard !connected else { return }
            connected = true
            connectionDeadline?.cancel()
            guard record("connected", fields: ["lifecycle": foreground ? "foreground" : "background"]) else { return }
            status = "Connected. Confirming the shared test session…"
            sendHello()
        case .connecting: status = "Connecting…"
        case .disconnected: recoverConnection(reason: "peer_disconnected")
        case .rejected: recoverConnection(reason: "connection_rejected")
        }
    }
}
