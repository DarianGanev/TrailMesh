import Foundation
import Combine
import NearbyConnections
import UIKit

enum ProbeRole: String, CaseIterable, Identifiable {
    case sender
    case receiver

    var id: String { rawValue }
    var title: String { self == .sender ? "Find and send" : "Advertise and receive" }
}

final class ProbeModel: ObservableObject {
    @Published private(set) var status = "Not running"
    @Published private(set) var sessionActive = false
    @Published private(set) var successfulAttempts = 0
    @Published private(set) var failedAttempts = 0
    @Published private(set) var logs: [String] = []

    private var role: ProbeRole?
    private var payloadSize = 2048
    private var attemptIndex = 0
    private var pendingDigest: Data?
    private var endpointID: EndpointID?
    private var connectionManager: ConnectionManager?
    private var advertiser: Advertiser?
    private var discoverer: Discoverer?
    private let serviceID = "org.trailmesh.foregroundprobe"
    private let attemptsPerBatch = 20
    private let ackTimeoutSeconds: TimeInterval = 15
    private var records: [[String: Any]] = []
    private var sessionGeneration = 0

    var exportJSON: String {
        let device = UIDevice.current
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "unknown"
        let document: [String: Any] = [
            "schema": "trailmesh.foreground-probe-log",
            "version": 1,
            "platform": "ios",
            "device": ["model": device.model, "os_version": device.systemVersion,
                       "app_version": appVersion, "build": build],
            "transport": "Google Nearby Connections",
            "strategy": "pointToPoint",
            "underlying_medium": "SDK selected; not exposed by the probe",
            "automatic_test_acceptance": true,
            "internet_disabled": NSNull(),
            "attempts": records,
        ]
        guard JSONSerialization.isValidJSONObject(document),
              let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"Unable to create a redacted test log\"}"
        }
        return text
    }

    func start(role: ProbeRole, payloadSize: Int) {
        stop(reason: "Restarting test session.", writeStatus: false)
        sessionGeneration &+= 1
        self.role = role
        self.payloadSize = payloadSize
        attemptIndex = 0
        pendingDigest = nil
        endpointID = nil
        successfulAttempts = 0
        failedAttempts = 0
        logs.removeAll()
        records.removeAll()
        sessionActive = true
        status = role == .sender ? "Searching for the receiving phone…" : "Ready to receive from the sending phone…"
        record(["event": "session_started", "role": role.rawValue,
                "payload_size_bytes": payloadSize, "foreground_only": true])

        let manager = ConnectionManager(serviceID: serviceID, strategy: .pointToPoint)
        manager.delegate = self
        connectionManager = manager

        if role == .receiver {
            let newAdvertiser = Advertiser(connectionManager: manager)
            newAdvertiser.delegate = self
            advertiser = newAdvertiser
            newAdvertiser.startAdvertising(using: Data("TrailMesh probe v1".utf8)) { [weak self] error in
                guard let self else { return }
                if error != nil {
                    self.status = "Advertising failed. Check Bluetooth and Local Network permissions."
                    self.record(["event": "advertising_failed"])
                } else {
                    self.status = "Ready to receive; foreground session active."
                    self.record(["event": "advertising_started"])
                }
            }
        } else {
            let newDiscoverer = Discoverer(connectionManager: manager)
            newDiscoverer.delegate = self
            discoverer = newDiscoverer
            newDiscoverer.startDiscovery { [weak self] error in
                guard let self else { return }
                if error != nil {
                    self.status = "Discovery failed. Check Bluetooth and Local Network permissions."
                    self.record(["event": "discovery_failed"])
                } else {
                    self.status = "Searching for a receiver; foreground session active."
                    self.record(["event": "discovery_started"])
                }
            }
        }
    }

    func stop(reason: String, writeStatus: Bool = true) {
        guard sessionActive || writeStatus else { return }
        sessionActive = false
        clearPendingTimeout()
        advertiser?.stopAdvertising()
        discoverer?.stopDiscovery()
        if let endpointID {
            connectionManager?.disconnect(from: endpointID)
        }
        advertiser = nil
        discoverer = nil
        connectionManager = nil
        endpointID = nil
        pendingDigest = nil
        role = nil
        if writeStatus {
            status = reason
            record(["event": "session_stopped", "reason": reason])
        }
    }

    private func sendNextAttempt() {
        guard sessionActive, role == .sender, let endpointID, let manager = connectionManager else { return }
        guard attemptIndex < attemptsPerBatch else {
            status = "Batch complete: \(successfulAttempts) succeeded, \(failedAttempts) failed out of \(attemptsPerBatch)."
            record(["event": "batch_complete"])
            return
        }
        do {
            let payload = try ForegroundFrame.makeTestPayload(size: payloadSize, attemptIndex: attemptIndex)
            let digest = ForegroundFrame.digest(payload)
            let message = try ForegroundFrame.encodeDataMessage(attemptIndex: attemptIndex, payload: payload)
            pendingDigest = digest
            let attempt = attemptIndex
            let generation = sessionGeneration
            record(["event": "payload_sent", "attempt_index": attempt,
                    "payload_size_bytes": payloadSize, "expected_sha256": ForegroundFrame.hex(digest)])
            _ = manager.send(message, to: [endpointID], id: Int64(attempt + 1)) { [weak self] error in
                guard let self, self.sessionActive,
                      self.sessionGeneration == generation, self.attemptIndex == attempt,
                      self.pendingDigest != nil, error != nil else { return }
                self.completeAttempt(success: false, reason: "payload_send_failed", receivedDigest: nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + ackTimeoutSeconds) { [weak self] in
                guard let self, self.sessionActive,
                      self.sessionGeneration == generation, self.attemptIndex == attempt,
                      self.pendingDigest != nil else { return }
                self.completeAttempt(success: false, reason: "acknowledgement_timeout", receivedDigest: nil)
            }
        } catch {
            completeAttempt(success: false, reason: "payload_generation_failed", receivedDigest: nil)
        }
    }

    private func handleData(_ message: ProbeDataMessage, from endpointID: EndpointID) {
        guard let manager = connectionManager else { return }
        do {
            let expected = try ForegroundFrame.makeTestPayload(
                size: message.frame.payload.count, attemptIndex: message.attemptIndex)
            let accepted = expected == message.frame.payload
            let receivedDigest = ForegroundFrame.digest(message.frame.payload)
            record(["event": "payload_received", "attempt_index": message.attemptIndex,
                    "payload_size_bytes": message.frame.payload.count,
                    "expected_sha256": ForegroundFrame.hex(ForegroundFrame.digest(expected)),
                    "received_sha256": ForegroundFrame.hex(receivedDigest), "success": accepted])
            if accepted { successfulAttempts += 1 } else { failedAttempts += 1 }
            status = "Received \(message.frame.payload.count) bytes: \(accepted ? "checksum matches" : "payload mismatch")."
            let ack = try ForegroundFrame.encodeAckMessage(
                attemptIndex: message.attemptIndex, accepted: accepted, digest: receivedDigest)
            _ = manager.send(ack, to: [endpointID], id: Int64(1001 + message.attemptIndex))
        } catch {
            record(["event": "invalid_probe_frame"])
        }
    }

    private func handleAck(_ message: ProbeAckMessage) {
        guard role == .sender, message.attemptIndex == attemptIndex else {
            record(["event": "unexpected_acknowledgement"])
            return
        }
        let accepted = message.accepted && pendingDigest == message.digest
        completeAttempt(success: accepted,
                        reason: accepted ? nil : "acknowledgement_or_checksum_mismatch",
                        receivedDigest: message.digest)
    }

    private func completeAttempt(success: Bool, reason: String?, receivedDigest: Data?) {
        guard pendingDigest != nil else { return }
        let expectedDigest = pendingDigest
        record(["event": "attempt_result", "attempt_index": attemptIndex,
                "payload_size_bytes": payloadSize,
                "direction": role == .sender ? "iphone-to-android" : "android-to-iphone",
                "expected_sha256": jsonValue(expectedDigest.map(ForegroundFrame.hex)),
                "received_sha256": jsonValue(receivedDigest.map(ForegroundFrame.hex)),
                "success": success, "failure_reason": jsonValue(reason)])
        if success { successfulAttempts += 1 } else { failedAttempts += 1 }
        pendingDigest = nil
        attemptIndex += 1
        status = "\(successfulAttempts) succeeded, \(failedAttempts) failed out of \(attemptsPerBatch)."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.sendNextAttempt() }
    }

    private func clearPendingTimeout() {
        // Invalidate send and timeout callbacks captured by the previous session.
        sessionGeneration &+= 1
        pendingDigest = nil
    }

    private func record(_ record: [String: Any]) {
        var item = record
        item["observed_at"] = ISO8601DateFormatter().string(from: Date())
        records.append(item)
        let event = record["event"] as? String ?? "event"
        if let attempt = record["attempt_index"] as? Int {
            let result = (record["success"] as? Bool).map { $0 ? "success" : "failed" } ?? "pending"
            logs.append("\(event) #\(attempt): \(result)")
        } else {
            logs.append(event)
        }
    }
}

private func jsonValue(_ value: String?) -> Any {
    guard let value else { return NSNull() }
    return value
}

extension ProbeModel: AdvertiserDelegate, DiscovererDelegate, ConnectionManagerDelegate {
    func advertiser(_ advertiser: Advertiser, didReceiveConnectionRequestFrom endpointID: EndpointID,
                    with context: Data, connectionRequestHandler: @escaping (Bool) -> Void) {
        record(["event": "connection_request_received"])
        connectionRequestHandler(sessionActive)
    }

    func discoverer(_ discoverer: Discoverer, didFind endpointID: EndpointID, with context: Data) {
        guard sessionActive, role == .sender, self.endpointID == nil else { return }
        self.endpointID = endpointID
        status = "Found a receiver; connecting automatically."
        record(["event": "peer_discovered"])
        discoverer.stopDiscovery()
        discoverer.requestConnection(to: endpointID, using: Data("TrailMesh probe v1".utf8)) { [weak self] error in
            if error != nil {
                self?.endpointID = nil
                self?.status = "Connection request failed."
                self?.record(["event": "connection_request_failed"])
            }
        }
    }

    func discoverer(_ discoverer: Discoverer, didLose endpointID: EndpointID) {
        record(["event": "peer_lost"])
    }

    func connectionManager(_ connectionManager: ConnectionManager, didReceive verificationCode: String,
                           from endpointID: EndpointID, verificationHandler: @escaping (Bool) -> Void) {
        record(["event": "sdk_verification_code_auto_accepted_test_mode"])
        verificationHandler(sessionActive)
    }

    func connectionManager(_ connectionManager: ConnectionManager, didReceive data: Data,
                           withID payloadID: PayloadID, from endpointID: EndpointID) {
        do {
            if ForegroundFrame.isAckMessage(data) {
                handleAck(try ForegroundFrame.decodeAckMessage(data))
            } else {
                handleData(try ForegroundFrame.decodeDataMessage(data), from: endpointID)
            }
        } catch {
            record(["event": "invalid_probe_frame"])
        }
    }

    func connectionManager(_ connectionManager: ConnectionManager, didReceive stream: InputStream,
                           withID payloadID: PayloadID, from endpointID: EndpointID,
                           cancellationToken token: CancellationToken) {
        token.cancel()
        record(["event": "unexpected_stream_payload"])
    }

    func connectionManager(_ connectionManager: ConnectionManager, didStartReceivingResourceWithID payloadID: PayloadID,
                           from endpointID: EndpointID, at localURL: URL, withName name: String,
                           cancellationToken token: CancellationToken) {
        token.cancel()
        record(["event": "unexpected_file_payload"])
    }

    func connectionManager(_ connectionManager: ConnectionManager, didReceiveTransferUpdate update: TransferUpdate,
                           from endpointID: EndpointID, forPayload payloadID: PayloadID) {
        if case .failure = update {
            record(["event": "nearby_transfer_failed"])
        }
    }

    func connectionManager(_ connectionManager: ConnectionManager, didChangeTo state: ConnectionState,
                           for endpointID: EndpointID) {
        switch state {
        case .connected:
            self.endpointID = endpointID
            status = "Connected. Exchanging generated test payloads."
            record(["event": "connected_foreground"])
            if role == .sender { sendNextAttempt() }
        case .connecting:
            status = "Connecting…"
            record(["event": "connecting"])
        case .disconnected:
            if self.endpointID == endpointID { self.endpointID = nil }
            status = "Peer disconnected. Stop and restart the session to retry."
            record(["event": "disconnected_foreground"])
        case .rejected:
            if self.endpointID == endpointID { self.endpointID = nil }
            status = "Connection rejected."
            record(["event": "connection_rejected"])
        }
    }
}
