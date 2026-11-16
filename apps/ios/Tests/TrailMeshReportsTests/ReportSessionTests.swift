import Foundation
import XCTest
@testable import TrailMeshReports

@MainActor
final class ReportSessionTests: XCTestCase {
    private let area = RelevanceContext(manualArea: RelevanceArea(center: RelevancePoint(latitude: 426977000, longitude: 233219000), radius: 5000))
    func testTerminalDrainRetainsOwnershipUntilAllActionBatchesDispatch() {
        var drain = ReportActionDrain()
        // Receive owns a CLOSE batch but is suspended before radio dispatch.
        drain.begin()
        // An independent tick observes completion without producing output.
        drain.begin()
        drain.finish()
        XCTAssertFalse(drain.mayRelease(completed: true, pendingPayloads: 1))
        // A synchronous SDK completion can empty the payload map while the
        // owning action batch still has not finished its dispatch bookkeeping.
        XCTAssertFalse(drain.mayRelease(completed: true, pendingPayloads: 0))
        drain.finish()
        XCTAssertFalse(drain.mayRelease(completed: false, pendingPayloads: 0))
        XCTAssertFalse(drain.mayRelease(completed: true, pendingPayloads: 1))
        XCTAssertTrue(drain.mayRelease(completed: true, pendingPayloads: 0))
    }
    func testSeparateCallbackDoneBatchDispatchesBeforeLaterGracefulClose() async throws {
        let repository = try ReportRepository(path: ":memory:"), radio = FakeReportRadio()
        let coordinator = ReportSessionCoordinator(repository: repository, radio: radio, wallClock: { 0 }, monotonic: { 0 }, temporaryID: { "11111111111111111111111111111111" })
        let gate = SessionDispatchGate()
        coordinator.beforeDispatchForTesting = { bytes in
            if let frame = try? ExchangeWire.decode(bytes), case .done = frame.body { await gate.hold() }
        }
        coordinator.start(context: area, publicSharingConsent: true)
        let epoch = coordinator.radioEpoch
        coordinator.radioFound(endpoint: "peer", advertisement: advertisement(1), epoch: epoch)
        coordinator.radioConnected(endpoint: "peer", epoch: epoch)
        for _ in 0..<1000 { if !radio.sent.isEmpty { break }; try await Task.sleep(for: .milliseconds(1)) }
        let localNonce = try ExchangeWire.decode(XCTUnwrap(radio.sent.first).0).source
        func remote(_ body: ExchangeBody) throws -> Data {
            try ExchangeWire.encode(ExchangeFrame(source: Data(repeating: 4, count: 16), destination: localNonce, body: body))
        }
        let hello = ExchangeFrame(source: Data(repeating: 4, count: 16), destination: Data(repeating: 0, count: 16), body: .hello(features: 1, maxFrame: 16384, maxChunk: 1024))
        coordinator.radioReceived(try ExchangeWire.encode(hello), endpoint: "peer", epoch: epoch)
        for _ in 0..<1000 { if radio.sent.count >= 2 { break }; try await Task.sleep(for: .milliseconds(1)) }
        coordinator.radioReceived(try remote(.summary(page: 0, more: false, entries: [])), endpoint: "peer", epoch: epoch)
        for _ in 0..<1000 { if radio.sent.count >= 3 { break }; try await Task.sleep(for: .milliseconds(1)) }
        coordinator.radioReceived(try remote(.request([])), endpoint: "peer", epoch: epoch)
        for _ in 0..<1000 { if gate.entered { break }; try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(gate.entered)
        coordinator.radioReceived(try remote(.done), endpoint: "peer", epoch: epoch)
        for _ in 0..<1000 { if coordinator.readyActionBatchCount == 1 { break }; try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(coordinator.readyActionBatchCount, 1, "Later CLOSE must wait behind the owned DONE batch")
        XCTAssertFalse(try radio.sent.contains { if case .close = try ExchangeWire.decode($0.0).body { return true }; return false })
        gate.release()
        for _ in 0..<1000 { if radio.sent.count >= 5 { break }; try await Task.sleep(for: .milliseconds(1)) }
        let bodies = try radio.sent.map { try ExchangeWire.decode($0.0).body }
        XCTAssertEqual(Array(bodies.suffix(2)), [.done, .close(0)])
        for (_, endpoint, ticket) in radio.sent { coordinator.radioSent(ticket: ticket, succeeded: true, endpoint: endpoint, epoch: epoch) }
        for _ in 0..<1000 { if coordinator.activeLinkCount == 0 { break }; try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(coordinator.activeLinkCount, 0)
        coordinator.stop()
    }
    func testUntrustedPeerClose4DoesNotPauseHealthyLinksOrDiscovery() async throws {
        let repository = try ReportRepository(path: ":memory:"), radio = FakeReportRadio()
        let coordinator = ReportSessionCoordinator(repository: repository, radio: radio, wallClock: { 0 }, monotonic: { 0 }, temporaryID: { "11111111111111111111111111111111" })
        coordinator.start(context: area, publicSharingConsent: true)
        let epoch = coordinator.radioEpoch
        for i in 0..<4 { coordinator.radioFound(endpoint: "peer\(i)", advertisement: advertisement(i), epoch: epoch) }
        coordinator.radioConnected(endpoint: "peer0", epoch: epoch)
        for _ in 0..<1000 { if !radio.sent.isEmpty { break }; try await Task.sleep(for: .milliseconds(1)) }
        let nonce = try ExchangeWire.decode(XCTUnwrap(radio.sent.first).0).source
        let hello = ExchangeFrame(source: Data(repeating: 4, count: 16), destination: Data(repeating: 0, count: 16), body: .hello(features: 1, maxFrame: 16384, maxChunk: 1024))
        coordinator.radioReceived(try ExchangeWire.encode(hello), endpoint: "peer0", epoch: epoch)
        for _ in 0..<1000 { if radio.sent.count >= 2 { break }; try await Task.sleep(for: .milliseconds(1)) }
        let close = ExchangeFrame(source: Data(repeating: 4, count: 16), destination: nonce, body: .close(4))
        coordinator.radioReceived(try ExchangeWire.encode(close), endpoint: "peer0", epoch: epoch)
        for _ in 0..<1000 {
            for (_, endpoint, ticket) in radio.sent { coordinator.radioSent(ticket: ticket, succeeded: true, endpoint: endpoint, epoch: epoch) }
            if coordinator.activeLinkCount == 3 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(coordinator.state, .running)
        XCTAssertEqual(coordinator.activeLinkCount, 3)
        XCTAssertFalse(coordinator.events.contains { $0.code == "storage_failure" })
        coordinator.radioFound(endpoint: "replacement", advertisement: advertisement(8), epoch: epoch)
        XCTAssertEqual(coordinator.activeLinkCount, 4)
        XCTAssertTrue(radio.connects.contains("replacement"))
        XCTAssertEqual(coordinator.radioEpoch, epoch)
        coordinator.stop()
    }
    func testStopResumeKeepsOldBlockedPayloadChargedUntilItsDispatchReturns() async throws {
        let repository = try ReportRepository(path: ":memory:"), radio = FakeReportRadio()
        let coordinator = ReportSessionCoordinator(repository: repository, radio: radio, wallClock: { 0 }, monotonic: { 0 }, temporaryID: { "11111111111111111111111111111111" })
        let gate = SessionDispatchGate()
        coordinator.beforeDispatchForTesting = { bytes in
            if let frame = try? ExchangeWire.decode(bytes), case .close = frame.body { await gate.hold() }
        }
        coordinator.start(context: area, publicSharingConsent: true)
        let oldEpoch = coordinator.radioEpoch
        coordinator.radioFound(endpoint: "old", advertisement: advertisement(0), epoch: oldEpoch)
        coordinator.radioConnected(endpoint: "old", epoch: oldEpoch)
        for _ in 0..<1000 { if !radio.sent.isEmpty { break }; try await Task.sleep(for: .milliseconds(1)) }
        let hello = ExchangeFrame(source: Data(repeating: 4, count: 16), destination: Data(repeating: 0, count: 16), body: .hello(features: 1, maxFrame: 16384, maxChunk: 1024))
        coordinator.radioReceived(try ExchangeWire.encode(hello), endpoint: "old", epoch: oldEpoch)
        for _ in 0..<1000 { if radio.sent.count >= 2 { break }; try await Task.sleep(for: .milliseconds(1)) }
        coordinator.radioReceived(Data(count: 200000), endpoint: "old", epoch: oldEpoch)
        for _ in 0..<1000 { if gate.entered { break }; try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(gate.entered)
        XCTAssertEqual(coordinator.queuedByteCount, 200000)
        coordinator.stop()
        XCTAssertEqual(coordinator.queuedByteCount, 200000, "Stop invalidates generations, not retained-payload ownership")
        coordinator.start(context: area, publicSharingConsent: true)
        let newEpoch = coordinator.radioEpoch
        coordinator.radioFound(endpoint: "new", advertisement: advertisement(1), epoch: newEpoch)
        coordinator.radioConnected(endpoint: "new", epoch: newEpoch)
        coordinator.radioReceived(Data(count: 70000), endpoint: "new", epoch: newEpoch)
        XCTAssertTrue(coordinator.events.contains { $0.code == "queue_overflow" })
        XCTAssertEqual(coordinator.queuedByteCount, 200000)
        gate.release()
        for _ in 0..<1000 { if coordinator.queuedCallbackCount == 0 { break }; try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(coordinator.queuedCallbackCount, 0)
        XCTAssertEqual(coordinator.queuedByteCount, 0)
        XCTAssertFalse(try radio.sent.contains { if case .close = try ExchangeWire.decode($0.0).body { return true }; return false }, "Old-generation output must never dispatch after Resume")
        coordinator.stop()
    }
    func testSharedProductSessionProfile() throws {
        let url = try XCTUnwrap(TestResources.bundle.url(forResource: "session-v1-profile", withExtension: "json"))
        let profile = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let limits = try XCTUnwrap(profile["limits"] as? [String: Int])
        XCTAssertEqual(profile["service_id"] as? String, ReportAdvertisement.serviceID)
        XCTAssertEqual(profile["advertisement_prefix"] as? String, "TMR1|")
        XCTAssertEqual(profile["advertisement_bytes"] as? Int, 37)
        XCTAssertEqual(profile["test_note_prefix"] as? String, SyntheticTestReport.notePrefix)
        XCTAssertEqual(limits["active_links"], ReportSessionCoordinator.maximumLinks)
        XCTAssertEqual(limits["waiting_candidates"], ReportSessionCoordinator.maximumCandidates)
        XCTAssertEqual(limits["queued_callbacks"], ReportSessionCoordinator.maximumQueuedCallbacks)
        XCTAssertEqual(limits["queued_bytes"], ReportSessionCoordinator.maximumQueuedBytes)
        XCTAssertEqual(limits["terminal_drain_ms"], Int(ReportSessionCoordinator.terminalDrainMS))
    }
    func testConsentConfigurationAndAdvertisementBoundary() throws {
        XCTAssertNil(ReportAdvertisement.parse(Data("TMR1|00000000000000000000000000000000".utf8)))
        XCTAssertNil(ReportAdvertisement.parse(Data("TMR1|ABCDEF01234567890123456789012345".utf8)))
        let id = "11111111111111111111111111111111"
        XCTAssertEqual(ReportAdvertisement.parse(Data("TMR1|\(id)".utf8))?.sessionID, id)
        let radio = FakeReportRadio(), repository = try ReportRepository(path: ":memory:")
        let coordinator = ReportSessionCoordinator(repository: repository, radio: radio)
        coordinator.start(context: area, publicSharingConsent: false)
        XCTAssertEqual(coordinator.state, .paused(.consentRequired)); XCTAssertTrue(radio.starts.isEmpty)
        coordinator.start(context: RelevanceContext(), publicSharingConsent: true)
        XCTAssertEqual(coordinator.state, .paused(.configurationRequired)); XCTAssertTrue(radio.starts.isEmpty)
    }
    func testFourLinksFIFOEndpointTombstonesAndNoLifetimePeerCap() async throws {
        let repository = try ReportRepository(path: ":memory:"), radio = FakeReportRadio()
        let coordinator = ReportSessionCoordinator(repository: repository, radio: radio, temporaryID: { "11111111111111111111111111111111" })
        coordinator.start(context: area, publicSharingConsent: true)
        let epoch = coordinator.radioEpoch
        for i in 0..<12 { coordinator.radioFound(endpoint: "e\(i)", advertisement: advertisement(i), epoch: epoch) }
        XCTAssertEqual(coordinator.activeLinkCount, 4); XCTAssertEqual(coordinator.waitingCandidateCount, 8)
        for i in 0..<8 { coordinator.radioDisconnected(endpoint: "e\(i)", epoch: epoch) }
        XCTAssertEqual(coordinator.activeLinkCount, 4); XCTAssertEqual(coordinator.waitingCandidateCount, 0)
        coordinator.radioFound(endpoint: "e0", advertisement: advertisement(20), epoch: epoch)
        XCTAssertEqual(coordinator.activeLinkCount, 4)
        coordinator.stop()
        XCTAssertEqual(coordinator.activeLinkCount, 0); XCTAssertEqual(coordinator.state, .stopped)
    }
    func testAggregateIngressBoundBeforeTasksAndStopInvalidatesOutput() async throws {
        let repository = try ReportRepository(path: ":memory:"), radio = FakeReportRadio()
        let coordinator = ReportSessionCoordinator(repository: repository, radio: radio, temporaryID: { "11111111111111111111111111111111" })
        coordinator.start(context: area, publicSharingConsent: true)
        let epoch = coordinator.radioEpoch
        coordinator.radioFound(endpoint: "peer", advertisement: advertisement(1), epoch: epoch)
        coordinator.radioConnected(endpoint: "peer", epoch: epoch)
        coordinator.radioReceived(Data(count: 262145), endpoint: "peer", epoch: epoch)
        XCTAssertEqual(coordinator.queuedCallbackCount, 0)
        XCTAssertTrue(coordinator.events.contains { $0.code == "queue_overflow" })
        coordinator.stop()
        await Task.yield()
        XCTAssertTrue(radio.sent.isEmpty)
    }
    func testCallbackCountOverflowReleasesOnlyOffendingPeer() async throws {
        let repository = try ReportRepository(path: ":memory:"), radio = FakeReportRadio()
        let coordinator = ReportSessionCoordinator(repository: repository, radio: radio, temporaryID: { "11111111111111111111111111111111" })
        coordinator.start(context: area, publicSharingConsent: true)
        let epoch = coordinator.radioEpoch
        for i in 0..<4 {
            coordinator.radioFound(endpoint: "peer\(i)", advertisement: advertisement(i), epoch: epoch)
            coordinator.radioConnected(endpoint: "peer\(i)", epoch: epoch)
        }
        // Main-actor synchronous callbacks reserve capacity before any receive Task runs.
        for _ in 0..<65 { coordinator.radioReceived(Data([0]), endpoint: "peer0", epoch: epoch) }
        XCTAssertEqual(coordinator.queuedCallbackCount, 64)
        XCTAssertLessThanOrEqual(coordinator.queuedByteCount, 262144)
        XCTAssertEqual(coordinator.activeLinkCount, 3)
        XCTAssertTrue(radio.disconnected.contains("peer0")); XCTAssertFalse(radio.disconnected.contains("peer1"))
        coordinator.radioFound(endpoint: "replacement", advertisement: advertisement(5), epoch: epoch)
        XCTAssertEqual(coordinator.activeLinkCount, 4)
        coordinator.stop()
    }
    func testRepositoryClockFailureProducesVisiblePause() async throws {
        let (wire, now, _) = try exchangeFixture()
        let repository = try ReportRepository(path: ":memory:"), radio = FakeReportRadio()
        _ = try await repository.ingest(wire, now: now)
        let coordinator = ReportSessionCoordinator(repository: repository, radio: radio, wallClock: { now - 1 }, monotonic: { 0 }, temporaryID: { "11111111111111111111111111111111" })
        coordinator.start(context: area, publicSharingConsent: true)
        let epoch = coordinator.radioEpoch
        coordinator.radioFound(endpoint: "peer", advertisement: advertisement(0), epoch: epoch)
        coordinator.radioConnected(endpoint: "peer", epoch: epoch)
        let hello = try ExchangeWire.encode(ExchangeFrame(source: Data(repeating: 4, count: 16), destination: Data(repeating: 0, count: 16), body: .hello(features: 1, maxFrame: 16384, maxChunk: 1024)))
        coordinator.radioReceived(hello, endpoint: "peer", epoch: epoch)
        for _ in 0..<1000 {
            for (_, endpoint, ticket) in radio.sent { coordinator.radioSent(ticket: ticket, succeeded: true, endpoint: endpoint, epoch: epoch) }
            if coordinator.state == .paused(.storageFailure) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(coordinator.state, .paused(.storageFailure))
        coordinator.stop()
    }
    func testForegroundPauseResumeContextAndTimeout() async throws {
        let clock = SessionTestClock(), repository = try ReportRepository(path: ":memory:"), radio = FakeReportRadio()
        let coordinator = ReportSessionCoordinator(repository: repository, radio: radio, monotonic: { clock.value }, temporaryID: { "11111111111111111111111111111111" })
        coordinator.start(context: area, publicSharingConsent: true)
        let epoch = coordinator.radioEpoch
        coordinator.radioFound(endpoint: "stalled", advertisement: advertisement(1), epoch: epoch)
        clock.value = 15001; coordinator.tick()
        XCTAssertEqual(coordinator.activeLinkCount, 0)
        coordinator.setForeground(false)
        XCTAssertEqual(coordinator.state, .paused(.foregroundRequired))
        coordinator.setForeground(true)
        XCTAssertEqual(coordinator.state, .running)
        XCTAssertNotEqual(epoch, coordinator.radioEpoch)
        coordinator.updateContext(RelevanceContext())
        XCTAssertEqual(coordinator.state, .paused(.configurationRequired))
    }
    func testFourSimultaneousSignedPeersExchangeThroughRealRepositories() async throws {
        let (_, now, _) = try exchangeFixture()
        let repository = try ReportRepository(path: ":memory:"), radio = FakeReportRadio()
        let identity = try ReportIdentity.create(store: ExchangeMemoryKeyStore())
        _ = try await repository.authorSyntheticTestReport(identity: identity, now: now)
        let coordinator = ReportSessionCoordinator(repository: repository, radio: radio, wallClock: { now }, monotonic: { 0 }, temporaryID: { "11111111111111111111111111111111" })
        coordinator.start(context: area, publicSharingConsent: true)
        let epoch = coordinator.radioEpoch
        let commonRepository = try ReportRepository(path: ":memory:")
        let commonIdentity = try ReportIdentity.create(store: ExchangeMemoryKeyStore())
        guard case let .stored(commonID) = try await commonRepository.authorSyntheticTestReport(identity: commonIdentity, now: now) else { return XCTFail("shared fixture") }
        let commonLoaded = try await commonRepository.loadOutgoing(commonID, now: now)
        let common = try XCTUnwrap(commonLoaded).wire
        var peers: [String: ExchangeSession] = [:], repositories: [ReportRepository] = []
        for i in 0..<4 {
            let remote = try ReportRepository(path: ":memory:")
            let remoteIdentity = try ReportIdentity.create(store: ExchangeMemoryKeyStore())
            _ = try await remote.authorSyntheticTestReport(identity: remoteIdentity, now: now)
            _ = try await remote.ingestTransferred(common, offeredHops: 3, now: now)
            repositories.append(remote)
            let endpoint = "peer\(i)"
            let engine = ExchangeSession(store: SelectedReportExchangeStore(repository: remote, context: area), nonce: Data(repeating: UInt8(i + 2), count: 16), generation: UInt64(i + 1), wallClock: { now })
            peers[endpoint] = engine
            coordinator.radioFound(endpoint: endpoint, advertisement: advertisement(i), epoch: epoch)
            coordinator.radioConnected(endpoint: endpoint, epoch: epoch)
            let hello = await engine.start(elapsed: 0)
            for action in hello { coordinator.radioReceived(action.bytes, endpoint: endpoint, epoch: epoch) }
        }
        XCTAssertEqual(coordinator.activeLinkCount, 4)
        for _ in 0..<2000 {
            if !radio.sent.isEmpty {
                let (bytes, endpoint, ticket) = radio.sent.removeFirst()
                if let peer = peers[endpoint], let index = Int(endpoint.dropFirst(4)) {
                    let responses = await peer.receive(bytes, generation: UInt64(index + 1), elapsed: 0)
                    coordinator.radioSent(ticket: ticket, succeeded: true, endpoint: endpoint, epoch: epoch)
                    for response in responses { coordinator.radioReceived(response.bytes, endpoint: endpoint, epoch: epoch) }
                }
            } else { await Task.yield() }
            let local = try await repository.savedTestReportEvidence(now: now)
            if local.count == 6, coordinator.activeLinkCount == 0 { break }
        }
        let local = try await repository.savedTestReportEvidence(now: now)
        XCTAssertEqual(local.count, 6)
        XCTAssertEqual(local.first { $0.bundleID == commonID }?.remainingHops, 1)
        XCTAssertTrue(local.contains { $0.remainingHops == 2 })
        for remote in repositories {
            let reports = try await remote.savedTestReportEvidence(now: now)
            XCTAssertGreaterThanOrEqual(reports.count, 2)
        }
        XCTAssertTrue(coordinator.events.contains { $0.code == "report_stored" })
        XCTAssertTrue(coordinator.events.contains { $0.code == "peer_received_claim" })
        coordinator.stop()
    }
    func testTerminalCloseWaitsForSDKCompletionBeforeDisconnect() async throws {
        let (_, now, _) = try exchangeFixture()
        let clock = SessionTestClock(), repository = try ReportRepository(path: ":memory:"), radio = FakeReportRadio()
        let coordinator = ReportSessionCoordinator(repository: repository, radio: radio, wallClock: { now }, monotonic: { clock.value }, temporaryID: { "11111111111111111111111111111111" })
        coordinator.start(context: area, publicSharingConsent: true)
        let epoch = coordinator.radioEpoch
        coordinator.radioFound(endpoint: "peer", advertisement: advertisement(0), epoch: epoch)
        coordinator.radioConnected(endpoint: "peer", epoch: epoch)
        let peerRepository = try ReportRepository(path: ":memory:")
        let peer = ExchangeSession(store: peerRepository, nonce: Data(repeating: 4, count: 16), generation: 7, wallClock: { now })
        for action in await peer.start(elapsed: 0) { coordinator.radioReceived(action.bytes, endpoint: "peer", epoch: epoch) }
        for _ in 0..<1000 {
            if radio.sent.contains(where: { guard let frame = try? ExchangeWire.decode($0.0) else { return false }; if case .summary = frame.body { return true }; return false }) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        // Retain all SDK tickets uncompleted, then force the engine total deadline.
        clock.value = 30000; coordinator.tick()
        for _ in 0..<1000 {
            if radio.sent.contains(where: { guard let frame = try? ExchangeWire.decode($0.0) else { return false }; if case .close = frame.body { return true }; return false }) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(coordinator.activeLinkCount, 1)
        XCTAssertFalse(radio.disconnected.contains("peer"))
        for (_, endpoint, ticket) in radio.sent { coordinator.radioSent(ticket: ticket, succeeded: true, endpoint: endpoint, epoch: epoch) }
        XCTAssertEqual(coordinator.activeLinkCount, 0)
        XCTAssertTrue(radio.disconnected.contains("peer"))
        coordinator.stop()
    }
    private func advertisement(_ index: Int) -> Data { Data(("TMR1|" + "222222222222222222222222" + String(format: "%08x", index + 100)).utf8) }
}
@MainActor
final class FakeReportRadio: ReportSessionRadio {
    weak var delegate: (any ReportSessionRadioDelegate)?
    var starts: [(Data, UInt64)] = [], connects: [String] = [], disconnected: [String] = []
    var sent: [(Data, String, UInt64)] = []
    func start(advertisement: Data, epoch: UInt64) { starts.append((advertisement, epoch)) }
    func stop() { }
    func connect(endpoint: String, advertisement: Data, epoch: UInt64) { connects.append(endpoint) }
    func disconnect(endpoint: String) { disconnected.append(endpoint) }
    func send(_ bytes: Data, endpoint: String, ticket: UInt64) throws { sent.append((bytes, endpoint, ticket)) }
}
final class SessionTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int64 = 0
    var value: Int64 { get { lock.lock(); defer { lock.unlock() }; return stored } set { lock.lock(); stored = newValue; lock.unlock() } }
}

@MainActor
private final class SessionDispatchGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func hold() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
