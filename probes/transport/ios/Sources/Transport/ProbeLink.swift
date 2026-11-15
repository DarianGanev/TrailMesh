import Foundation

/// One serialized journal owner is shared by all links. Its commit must finish
/// before a link sends an acceptance acknowledgement.
protocol ProbeLinkHost: AnyObject {
    var sessionState: ProbeSessionState? { get }
    var mayStartWork: Bool { get }
    var finishingInBackground: Bool { get }
    func isCurrent(_ link: ProbeLink) -> Bool
    func commit(_ next: ProbeSessionState) -> Bool
    func append(_ event: String, fields: [String: String], to next: inout ProbeSessionState)
    func linkChanged(_ link: ProbeLink, successfulAttempt: Bool)
    func linkFailed(_ link: ProbeLink, reason: String)
    func linkCompleted(_ link: ProbeLink)
}

/// All mutable protocol state and deadlines belong to this one reservation.
/// SDK callbacks must be routed by endpoint; asynchronous completions additionally
/// retain this instance, never a lookup of a replacement link.
final class ProbeLink {
    typealias SendBytes = (Data, Int64, @escaping (Error?) -> Void) -> Void
    let reservation: ProbePeerReservation
    let catchUp: Bool
    private weak var host: (any ProbeLinkHost)?
    private let sendBytes: SendBytes
    private(set) var connected = false
    private(set) var ready = false
    private(set) var pendingAttempt: Int?
    private var valid = true
    private var helloReceived = false
    private var helloSent = false
    private var helloTransmissions = 0
    private var finishTransmissions = 0
    private var inboundFrames = 0
    private var pendingDigest: Data?
    private var pendingPayloadID: Int64?
    private var finishAckPayloads: Set<Int64> = []
    private var connectionDeadline: DispatchWorkItem?
    private var helloDeadline: DispatchWorkItem?
    private var ackDeadline: DispatchWorkItem?
    private var finishDeadline: DispatchWorkItem?
    private var peerProgressDeadline: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?
    private var completionWork: DispatchWorkItem?

    init(reservation: ProbePeerReservation, catchUp: Bool, host: any ProbeLinkHost,
         sendBytes: @escaping SendBytes) {
        self.reservation = reservation
        self.catchUp = catchUp
        self.host = host
        self.sendBytes = sendBytes
    }

    var remote: String { reservation.candidate.context.sessionID }
    var endpointID: String { reservation.candidate.endpointID }
    var isLive: Bool { valid && host?.isCurrent(self) == true }
    private var outgoingDirection: String {
        reservation.candidate.context.platform == .ios ? "iphone-to-iphone" : "iphone-to-android"
    }
    private var incomingDirection: String {
        reservation.candidate.context.platform == .ios ? "iphone-to-iphone" : "android-to-iphone"
    }

    func beginConnecting() {
        connectionDeadline = schedule(after: 20) { link in
            if !link.connected { link.fail("connection_timeout") }
        }
    }

    func didConnect() {
        guard isLive, !connected else { return }
        connected = true
        connectionDeadline?.cancel()
        guard record("connected") else { return }
        sendHello()
    }

    func resumeWork() {
        guard isLive else { return }
        sendNextAttempt()
        sendFinishIfNeeded()
    }

    func cancel() {
        valid = false
        [connectionDeadline, helloDeadline, ackDeadline, finishDeadline,
         peerProgressDeadline, retryWork, completionWork].forEach { $0?.cancel() }
        pendingAttempt = nil
        pendingDigest = nil
        pendingPayloadID = nil
        finishAckPayloads.removeAll()
    }

    private func schedule(after delay: TimeInterval, action: @escaping (ProbeLink) -> Void) -> DispatchWorkItem {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isLive else { return }
            action(self)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return work
    }

    private func fail(_ reason: String) {
        guard isLive else { return }
        host?.linkFailed(self, reason: reason)
    }

    @discardableResult
    private func record(_ event: String, fields: [String: String] = [:]) -> Bool {
        guard isLive, let host, var next = host.sessionState else { return false }
        var fields = fields
        fields["peer_session_id"] = remote
        host.append(event, fields: fields, to: &next)
        return host.commit(next) && isLive
    }

    private func send(_ bytes: Data, id: Int64 = Int64.random(in: 1...Int64.max),
                      completion: @escaping (ProbeLink, Error?) -> Void) {
        guard isLive else { return }
        sendBytes(bytes, id) { [weak self] error in
            guard let self, self.isLive else { return }
            completion(self, error)
        }
    }

    private func sendHello() {
        guard isLive, connected, let state = host?.sessionState else { return }
        helloDeadline?.cancel()
        guard helloTransmissions < 3 else { fail("hello_timeout"); return }
        helloTransmissions += 1
        do {
            let bytes = try ForegroundFrame.encodeHelloMessage(sessionID: state.sessionID,
                                                              peerSessionID: remote, payloadSize: state.payloadSize)
            send(bytes) { link, error in
                guard error == nil else { link.fail("hello_send_failed"); return }
                link.helloSent = true
                link.becomeReadyIfPossible()
            }
            helloDeadline = schedule(after: 10) { link in if !link.ready { link.sendHello() } }
        } catch { fail("hello_encoding_failed") }
    }

    private func becomeReadyIfPossible() {
        guard isLive, !ready, helloSent, helloReceived, connected else { return }
        ready = true
        helloDeadline?.cancel()
        guard record("peer_ready", fields: ["direction": "bidirectional"]) else { return }
        if let peer = host?.sessionState?.peer(remote), peer.remoteFinished {
            sendRemoteFinishAcknowledgement(successful: peer.remoteSuccessful!, failed: peer.remoteFailed!)
        }
        resumeWork()
        host?.linkChanged(self, successfulAttempt: false)
    }

    private func sendNextAttempt() {
        guard isLive, host?.mayStartWork == true, host?.finishingInBackground == false,
              ready, pendingAttempt == nil, let host, var next = host.sessionState,
              let peer = next.peer(remote) else { return }
        guard !peer.outgoingComplete else { sendFinishIfNeeded(); return }
        if peer.transmissions >= 3 {
            finishAttempt(success: false, reason: "transmission_limit", attempt: peer.nextAttempt)
            return
        }
        do {
            let attempt = try next.beginTransmission(to: remote)
            let payload = try ForegroundFrame.makeTestPayload(size: next.payloadSize, attemptIndex: attempt)
            let digest = ForegroundFrame.digest(payload)
            let bytes = try ForegroundFrame.encodeSessionDataMessage(sessionID: next.sessionID,
                                                                     attemptIndex: attempt, payload: payload)
            host.append("payload_sent", fields: ["attempt_index": "\(attempt)", "payload_size_bytes": "\(next.payloadSize)",
                        "transmission": "\(next.peer(remote)!.transmissions)", "peer_session_id": remote,
                        "expected_sha256": ForegroundFrame.hex(digest), "direction": outgoingDirection], to: &next)
            guard host.commit(next), isLive else { return }
            pendingAttempt = attempt
            pendingDigest = digest
            let id = Int64.random(in: 1...Int64.max)
            pendingPayloadID = id
            send(bytes, id: id) { link, error in
                if link.pendingAttempt == attempt, link.pendingPayloadID == id, error != nil {
                    link.transmissionFailed(reason: "payload_send_failed")
                }
            }
            ackDeadline = schedule(after: 15) { link in
                if link.pendingAttempt == attempt, link.pendingPayloadID == id {
                    link.transmissionFailed(reason: "acknowledgement_timeout")
                }
            }
        } catch { fail("payload_encoding_failed") }
    }

    private func transmissionFailed(reason: String) {
        guard isLive, let attempt = pendingAttempt, let peer = host?.sessionState?.peer(remote) else { return }
        ackDeadline?.cancel()
        pendingAttempt = nil
        pendingDigest = nil
        pendingPayloadID = nil
        guard record("transmission_failed", fields: ["attempt_index": "\(attempt)", "failure_reason": reason]) else { return }
        if peer.transmissions >= 3 { finishAttempt(success: false, reason: reason, attempt: attempt) }
        else if host?.finishingInBackground == true || host?.mayStartWork != true { host?.linkChanged(self, successfulAttempt: false) }
        else {
            retryWork?.cancel()
            retryWork = schedule(after: 0.5) { $0.sendNextAttempt() }
        }
    }

    private func finishAttempt(success: Bool, reason: String?, attempt: Int, receivedDigest: Data? = nil) {
        guard isLive, let host, var next = host.sessionState else { return }
        do {
            guard try next.finishAttempt(to: remote, attempt: attempt, success: success) else { return }
            let expected = try ForegroundFrame.makeTestPayload(size: next.payloadSize, attemptIndex: attempt)
            var fields = ["attempt_index": "\(attempt)", "success": "\(success)", "payload_size_bytes": "\(next.payloadSize)",
                          "peer_session_id": remote, "direction": outgoingDirection,
                          "expected_sha256": ForegroundFrame.digestHex(expected)]
            if let reason { fields["failure_reason"] = reason }
            if let receivedDigest { fields["received_sha256"] = ForegroundFrame.hex(receivedDigest) }
            host.append("attempt_result", fields: fields, to: &next)
            guard host.commit(next), isLive else { return }
            ackDeadline?.cancel()
            pendingAttempt = nil
            pendingDigest = nil
            pendingPayloadID = nil
            host.linkChanged(self, successfulAttempt: success)
            guard isLive, !host.finishingInBackground, host.mayStartWork else { return }
            retryWork?.cancel()
            retryWork = schedule(after: 0.1) { $0.resumeWork() }
        } catch { fail("attempt_state_invalid") }
    }

    func receive(_ data: Data) {
        guard isLive, connected else { return }
        // SDK delegates run directly on main. There is no application data queue;
        // four links each process at most 256 callbacks and 8 KiB test payloads.
        guard inboundFrames < 256, data.count <= 8192 + 60 else { fail("link_frame_limit"); return }
        inboundFrames += 1
        do {
            if ForegroundFrame.isHelloMessage(data) {
                let hello = try ForegroundFrame.decodeHelloMessage(data)
                guard hello.sessionID == remote, hello.peerSessionID == host?.sessionState?.sessionID,
                      hello.payloadSize == host?.sessionState?.payloadSize, hello.attemptCount == 20 else {
                    fail("hello_mismatch"); return
                }
                helloReceived = true
                becomeReadyIfPossible()
            } else if ForegroundFrame.isFinishMessage(data) {
                receiveFinish(try ForegroundFrame.decodeFinishMessage(data))
            } else if ForegroundFrame.isSessionAckMessage(data) {
                receiveAck(try ForegroundFrame.decodeSessionAckMessage(data))
            } else { receiveData(try ForegroundFrame.decodeSessionDataMessage(data)) }
        } catch { _ = record("invalid_probe_frame") }
    }

    func rejectUnsupportedPayload() {
        fail("unsupported_payload_type")
    }

    private func receiveData(_ message: ProbeSessionDataMessage) {
        guard ready, message.sessionID == remote, let host, var next = host.sessionState,
              message.frame.payload.count == next.payloadSize, (0..<20).contains(message.attemptIndex) else {
            _ = record("unexpected_session_data"); return
        }
        do {
            let expected = try ForegroundFrame.makeTestPayload(size: next.payloadSize, attemptIndex: message.attemptIndex)
            let accepted = expected == message.frame.payload
            let unique: Bool
            if accepted { unique = try next.recordReceived(from: remote, attempt: message.attemptIndex) }
            else { unique = false }
            host.append(unique ? "payload_received" : accepted ? "duplicate_payload_received" : "payload_rejected",
                        fields: ["attempt_index": "\(message.attemptIndex)", "payload_size_bytes": "\(next.payloadSize)",
                                 "peer_session_id": remote, "expected_sha256": ForegroundFrame.digestHex(expected),
                                 "received_sha256": ForegroundFrame.hex(message.frame.digest), "success": "\(accepted)",
                                 "direction": incomingDirection], to: &next)
            // Commit deduplication before acknowledging. A failed write never emits a positive ACK.
            guard host.commit(next), isLive else { return }
            if let peer = next.peer(remote), ProbeRecoveryPolicy.shouldRenewReciprocalDeadline(uniqueReceived: unique, peer: peer) {
                armReciprocalProgressDeadline()
            }
            let ack = try ForegroundFrame.encodeSessionAckMessage(sessionID: remote, attemptIndex: message.attemptIndex,
                                                                 accepted: accepted, digest: message.frame.digest)
            send(ack) { link, error in if error != nil { _ = link.record("acknowledgement_send_failed") } }
            host.linkChanged(self, successfulAttempt: false)
        } catch { _ = record("invalid_session_data") }
    }

    private func receiveAck(_ message: ProbeSessionAckMessage) {
        guard ready, message.sessionID == host?.sessionState?.sessionID,
              message.attemptIndex == pendingAttempt, let expected = pendingDigest else {
            _ = record("unexpected_acknowledgement"); return
        }
        if message.accepted && message.digest == expected {
            finishAttempt(success: true, reason: nil, attempt: message.attemptIndex, receivedDigest: message.digest)
        } else { transmissionFailed(reason: "acknowledgement_or_checksum_mismatch") }
    }

    private func sendFinishIfNeeded() {
        guard isLive, host?.mayStartWork == true, ready, let state = host?.sessionState, let peer = state.peer(remote),
              peer.outgoingComplete, !peer.localFinishAcknowledged, finishDeadline == nil else { return }
        guard finishTransmissions < 3 else { fail("finish_timeout"); return }
        finishTransmissions += 1
        do {
            let bytes = try ForegroundFrame.encodeFinishMessage(sessionID: state.sessionID, peerSessionID: remote,
                                                                acknowledgement: false, successfulAttempts: peer.successful,
                                                                failedAttempts: peer.failed)
            send(bytes) { link, error in if error != nil { link.fail("finish_send_failed") } }
            finishDeadline = schedule(after: 10) { link in link.finishDeadline = nil; link.sendFinishIfNeeded() }
        } catch { fail("finish_encoding_failed") }
    }

    private func receiveFinish(_ message: ProbeFinishMessage) {
        guard ready, message.sessionID == remote, let host, var next = host.sessionState,
              message.peerSessionID == next.sessionID else { _ = record("unexpected_finish"); return }
        do {
            if message.acknowledgement {
                let wasAcknowledged = next.peer(remote)?.localFinishAcknowledged == true
                try next.recordLocalFinishAcknowledgement(from: remote, successful: message.successfulAttempts, failed: message.failedAttempts)
                host.append("local_finish_acknowledged", fields: ["peer_session_id": remote], to: &next)
                guard host.commit(next), isLive else { return }
                finishDeadline?.cancel(); finishDeadline = nil
                if !wasAcknowledged { armReciprocalProgressDeadline() }
            } else {
                try next.recordRemoteFinish(from: remote, successful: message.successfulAttempts, failed: message.failedAttempts)
                completionWork?.cancel(); completionWork = nil
                host.append("remote_batch_finished", fields: ["peer_session_id": remote], to: &next)
                guard host.commit(next), isLive else { return }
                if peerProgressDeadline == nil { armReciprocalProgressDeadline() }
                sendRemoteFinishAcknowledgement(successful: message.successfulAttempts, failed: message.failedAttempts)
            }
            completePeerIfPossible()
        } catch { _ = record("invalid_finish") }
    }

    private func sendRemoteFinishAcknowledgement(successful: Int, failed: Int) {
        guard isLive, let state = host?.sessionState else { return }
        // Duplicate FINISH frames cannot allocate an unbounded SDK payload map.
        guard finishAckPayloads.count < 3 else { fail("finish_ack_queue_limit"); return }
        do {
            let bytes = try ForegroundFrame.encodeFinishMessage(sessionID: state.sessionID, peerSessionID: remote,
                                                                acknowledgement: true, successfulAttempts: successful, failedAttempts: failed)
            let id = Int64.random(in: 1...Int64.max)
            finishAckPayloads.insert(id)
            send(bytes, id: id) { link, error in
                if error != nil {
                    link.finishAckPayloads.remove(id)
                    link.fail("finish_ack_send_failed")
                }
            }
        } catch { fail("finish_ack_encoding_failed") }
    }

    func transferUpdated(payloadID: Int64, succeeded: Bool) {
        guard isLive else { return }
        if !succeeded, pendingPayloadID == payloadID { transmissionFailed(reason: "nearby_transfer_failed") }
        guard finishAckPayloads.remove(payloadID) != nil else { return }
        guard succeeded else { fail("finish_ack_transfer_failed"); return }
        guard let host, var next = host.sessionState else { return }
        do {
            try next.recordRemoteFinishAcknowledgementDelivered(to: remote)
            if host.commit(next), isLive { completePeerIfPossible() }
        } catch { fail("finish_ack_state_invalid") }
    }

    private func completePeerIfPossible() {
        guard isLive, host?.sessionState?.peer(remote)?.complete == true,
              finishAckPayloads.isEmpty, completionWork == nil else { return }
        peerProgressDeadline?.cancel(); peerProgressDeadline = nil
        completionWork = schedule(after: 1) { link in
            guard link.host?.sessionState?.peer(link.remote)?.complete == true, link.finishAckPayloads.isEmpty else {
                link.completionWork = nil
                link.armReciprocalProgressDeadline()
                return
            }
            guard link.record("peer_batch_complete") else { return }
            link.host?.linkCompleted(link)
        }
    }

    private func armReciprocalProgressDeadline() {
        guard host?.sessionState?.peer(remote)?.needsReciprocalProgressDeadline == true else { return }
        peerProgressDeadline?.cancel()
        peerProgressDeadline = schedule(after: ProbeRecoveryPolicy.reciprocalProgressTimeout) { link in
            if link.host?.sessionState?.peer(link.remote)?.needsReciprocalProgressDeadline == true {
                link.fail("reciprocal_progress_timeout")
            }
        }
    }
}
