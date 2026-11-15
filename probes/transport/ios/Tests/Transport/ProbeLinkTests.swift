import XCTest
@testable import TrailMeshTransportProbe

final class ProbeLinkTests: XCTestCase {
    func testFourPeersRoutePayloadsAndAcknowledgementsIndependently() throws {
        let host = try TestHost()
        defer { host.stop() }
        let links = try (1...4).map { try host.attach($0) }
        for link in links { try host.makeReady(link) }
        XCTAssertEqual(links.map(\.pendingAttempt), [0, 0, 0, 0])
        let payload = try ForegroundFrame.makeTestPayload(size: 2048, attemptIndex: 0)
        let ack = try ForegroundFrame.encodeSessionAckMessage(sessionID: host.state.sessionID,
                                                            attemptIndex: 0, accepted: true, digest: ForegroundFrame.digest(payload))
        links[1].receive(ack)
        XCTAssertEqual(host.state.peer(links[1].remote)?.successful, 1)
        for link in [links[0], links[2], links[3]] {
            XCTAssertEqual(host.state.peer(link.remote)?.successful, 0)
            XCTAssertEqual(link.pendingAttempt, 0)
        }
        let incoming = try ForegroundFrame.makeTestPayload(size: 2048, attemptIndex: 7)
        links[2].receive(try ForegroundFrame.encodeSessionDataMessage(sessionID: links[2].remote, attemptIndex: 7, payload: incoming))
        XCTAssertEqual(host.state.peer(links[2].remote)?.receivedAttempts, [7])
        XCTAssertEqual(host.state.peer(links[0].remote)?.receivedAttempts, [])
        let receipt = try XCTUnwrap(host.sent.last)
        XCTAssertEqual(receipt.endpoint, links[2].endpointID)
        XCTAssertEqual(try ForegroundFrame.decodeSessionAckMessage(receipt.bytes).sessionID, links[2].remote)
        XCTAssertEqual(host.successfulAdvances, [links[1].remote])
    }

    func testMalformedOrUnsupportedPeerReleasesOnlyItsSlotAndRefillsWaitingPeer() throws {
        let host = try TestHost()
        defer { host.stop() }
        let links = try (1...4).map { try host.attach($0) }
        for link in links { try host.makeReady(link) }
        XCTAssertTrue(host.pool.offer(host.candidate(5)))
        links[1].rejectUnsupportedPayload()
        XCTAssertFalse(links[1].isLive)
        for link in [links[0], links[2], links[3]] { XCTAssertTrue(link.isLive) }
        XCTAssertEqual(host.failures.map { $0.1 }, ["unsupported_payload_type"])
        let replacement = try host.attachNext()
        XCTAssertEqual(replacement.remote, host.candidate(5).context.sessionID)
        XCTAssertEqual(host.pool.activeCount, 4)
        let wrongHello = try ForegroundFrame.encodeHelloMessage(sessionID: String(repeating: "e", count: 32),
                                                                peerSessionID: host.state.sessionID, payloadSize: 2048)
        links[0].receive(wrongHello)
        XCTAssertFalse(links[0].isLive)
        XCTAssertTrue(links[2].isLive)
        XCTAssertTrue(replacement.isLive)
    }

    func testCancelledSendCompletionCannotReviveLinkOrTouchReplacement() throws {
        let host = try TestHost()
        defer { host.stop() }
        host.holdCompletions = true
        let old = try host.attach(1)
        old.didConnect()
        old.receive(try host.hello(for: old))
        let completion = try XCTUnwrap(host.sent.first?.completion)
        host.linkFailed(old, reason: "test_disconnect")
        XCTAssertNil(host.pool.reserveIncoming(host.candidate(1)))
        host.pool.reset()
        let replacement = try host.attach(1)
        completion(nil)
        old.receive(try host.hello(for: old))
        XCTAssertFalse(old.isLive)
        XCTAssertTrue(replacement.isLive)
        XCTAssertFalse(replacement.ready)
        XCTAssertEqual(host.state.peer(old.remote)?.transmissions, 0)
        host.stop()
        completion(NSError(domain: "late", code: 1))
        XCTAssertEqual(host.failures.count, 1)
    }

    func testFailedCheckpointSuppressesAcceptanceAndInvalidatesAllLinks() throws {
        let host = try TestHost()
        defer { host.stop() }
        let links = try (1...3).map { try host.attach($0) }
        for link in links { try host.makeReady(link) }
        host.sent.removeAll()
        host.failWrites = true
        let payload = try ForegroundFrame.makeTestPayload(size: 2048, attemptIndex: 3)
        links[0].receive(try ForegroundFrame.encodeSessionDataMessage(sessionID: links[0].remote, attemptIndex: 3, payload: payload))
        XCTAssertTrue(host.sent.isEmpty)
        XCTAssertEqual(host.state.peer(links[0].remote)?.receivedAttempts, [])
        XCTAssertTrue(links.allSatisfy { !$0.isLive })
        XCTAssertEqual(host.pool.activeCount, 0)
    }

    func testFrameLimitClosesOnlyFloodingPeer() throws {
        let host = try TestHost()
        defer { host.stop() }
        let first = try host.attach(1)
        let second = try host.attach(2)
        try host.makeReady(first)
        try host.makeReady(second)
        for _ in 0..<256 { first.receive(Data()) }
        XCTAssertFalse(first.isLive)
        XCTAssertTrue(second.isLive)
        XCTAssertEqual(host.failures.last?.1, "link_frame_limit")
    }

    func testBackgroundDrainDoesNotStartAnotherAttempt() throws {
        let host = try TestHost()
        defer { host.stop() }
        let link = try host.attach(1)
        try host.makeReady(link)
        host.finishingInBackground = true
        host.mayStartWork = false
        let payload = try ForegroundFrame.makeTestPayload(size: 2048, attemptIndex: 0)
        link.receive(try ForegroundFrame.encodeSessionAckMessage(sessionID: host.state.sessionID,
                                                               attemptIndex: 0, accepted: true, digest: ForegroundFrame.digest(payload)))
        link.resumeWork()
        XCTAssertEqual(host.state.peer(link.remote)?.nextAttempt, 1)
        XCTAssertNil(link.pendingAttempt)
        XCTAssertEqual(host.sent.filter { String(decoding: $0.bytes.prefix(4), as: UTF8.self) == "TMD2" }.count, 1)
    }

    func testCompletionWaitsForFinishAcknowledgementDeliveryAndLeavesOtherPeerLive() throws {
        let host = try TestHost()
        defer { host.stop() }
        let link = try host.attach(1)
        let other = try host.attach(2)
        try host.makeReady(link)
        try host.makeReady(other)
        for attempt in 0..<20 {
            link.resumeWork()
            let payload = try ForegroundFrame.makeTestPayload(size: 2048, attemptIndex: attempt)
            link.receive(try ForegroundFrame.encodeSessionAckMessage(sessionID: host.state.sessionID,
                                                                   attemptIndex: attempt, accepted: true,
                                                                   digest: ForegroundFrame.digest(payload)))
        }
        link.resumeWork()
        link.receive(try ForegroundFrame.encodeFinishMessage(sessionID: link.remote, peerSessionID: host.state.sessionID,
                                                            acknowledgement: false, successfulAttempts: 20, failedAttempts: 0))
        let remoteAcknowledgement = try XCTUnwrap(host.sent.last)
        XCTAssertTrue(try ForegroundFrame.decodeFinishMessage(remoteAcknowledgement.bytes).acknowledgement)
        link.receive(try ForegroundFrame.encodeFinishMessage(sessionID: link.remote, peerSessionID: host.state.sessionID,
                                                            acknowledgement: true, successfulAttempts: 20, failedAttempts: 0))
        XCTAssertFalse(host.state.peer(link.remote)!.complete)
        XCTAssertTrue(link.isLive)
        link.transferUpdated(payloadID: remoteAcknowledgement.id, succeeded: true)
        XCTAssertTrue(host.state.peer(link.remote)!.complete)
        let grace = expectation(description: "Per-peer completion grace")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { grace.fulfill() }
        wait(for: [grace], timeout: 3)
        XCTAssertFalse(link.isLive)
        XCTAssertTrue(other.isLive)
        XCTAssertEqual(host.pool.activeCount, 1)
    }

    func testDuplicatePayloadPersistsOneReceiptAndAcknowledgesBothCopies() throws {
        let host = try TestHost()
        defer { host.stop() }
        let link = try host.attach(1)
        try host.makeReady(link)
        host.sent.removeAll()
        let payload = try ForegroundFrame.makeTestPayload(size: 2048, attemptIndex: 2)
        let frame = try ForegroundFrame.encodeSessionDataMessage(sessionID: link.remote, attemptIndex: 2, payload: payload)
        link.receive(frame)
        link.receive(frame)
        XCTAssertEqual(host.state.peer(link.remote)?.receivedAttempts, [2])
        XCTAssertEqual(host.state.peer(link.remote)?.duplicates, 1)
        XCTAssertEqual(host.sent.count, 2)
        for receipt in host.sent {
            XCTAssertTrue(try ForegroundFrame.decodeSessionAckMessage(receipt.bytes).accepted)
        }
    }

    private final class TestHost: ProbeLinkHost {
        struct Sent {
            let endpoint: String
            let bytes: Data
            let id: Int64
            let completion: (Error?) -> Void
        }
        var state: ProbeSessionState
        var sessionState: ProbeSessionState? { state }
        var mayStartWork = true
        var finishingInBackground = false
        var pool = ProbePeerPool()
        var live: [String: ProbeLink] = [:]
        var sent: [Sent] = []
        var failures: [(String, String)] = []
        var successfulAdvances: [String] = []
        var failWrites = false
        var holdCompletions = false

        init() throws {
            state = ProbeSessionState(sessionID: String(repeating: "f", count: 32), payloadSize: 2048)
        }
        func candidate(_ value: Int) -> ProbePeerCandidate {
            ProbePeerCandidate(endpointID: "endpoint-\(value)", context: ProbePeerContext(platform: .android,
                                                                                       sessionID: String(format: "%032x", value), payloadSize: 2048))
        }
        func attach(_ value: Int) throws -> ProbeLink {
            try attach(try XCTUnwrap(pool.reserveIncoming(candidate(value))))
        }
        func attachNext() throws -> ProbeLink {
            try attach(try XCTUnwrap(pool.reserveNext { _ in true }))
        }
        private func attach(_ reservation: ProbePeerReservation) throws -> ProbeLink {
            try state.bindPeer(reservation.candidate.context.sessionID)
            try state.prepareLink(to: reservation.candidate.context.sessionID)
            let endpoint = reservation.candidate.endpointID
            let link = ProbeLink(reservation: reservation, catchUp: false, host: self) { [weak self] bytes, id, completion in
                guard let self else { return }
                self.sent.append(Sent(endpoint: endpoint, bytes: bytes, id: id, completion: completion))
                if !self.holdCompletions { completion(nil) }
            }
            live[endpoint] = link
            link.beginConnecting()
            return link
        }
        func hello(for link: ProbeLink) throws -> Data {
            try ForegroundFrame.encodeHelloMessage(sessionID: link.remote, peerSessionID: state.sessionID, payloadSize: 2048)
        }
        func makeReady(_ link: ProbeLink) throws {
            link.didConnect()
            link.receive(try hello(for: link))
            XCTAssertTrue(link.ready)
        }
        func isCurrent(_ link: ProbeLink) -> Bool { live[link.endpointID] === link && pool.contains(link.reservation) }
        func commit(_ next: ProbeSessionState) -> Bool {
            if failWrites { stop(); return false }
            state = next
            return true
        }
        func append(_ event: String, fields: [String: String], to next: inout ProbeSessionState) {
            next.appendRecord(ProbeLogEntry(event: event, observedAt: "test", fields: fields))
        }
        func linkChanged(_ link: ProbeLink, successfulAttempt: Bool) {
            if successfulAttempt { successfulAdvances.append(link.remote) }
        }
        func linkFailed(_ link: ProbeLink, reason: String) {
            guard isCurrent(link) else { return }
            failures.append((link.remote, reason))
            live.removeValue(forKey: link.endpointID)
            _ = pool.release(link.reservation)
            link.cancel()
        }
        func linkCompleted(_ link: ProbeLink) {
            live.removeValue(forKey: link.endpointID)
            _ = pool.release(link.reservation)
            link.cancel()
        }
        func stop() {
            let previous = Array(live.values)
            live.removeAll()
            pool.reset()
            for link in previous { link.cancel() }
        }
    }
}
