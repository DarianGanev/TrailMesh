import XCTest
@testable import TrailMeshTransportProbe

final class ProbePeerPoolTests: XCTestCase {
    private func candidate(_ value: Int, endpoint: String? = nil) -> ProbePeerCandidate {
        ProbePeerCandidate(endpointID: endpoint ?? "endpoint-\(value)",
                           context: ProbePeerContext(platform: .android,
                                                     sessionID: String(format: "%032x", value), payloadSize: 2048))
    }

    func testFourIndependentReservationsAndWaitingPeerRefillsReleasedSlot() throws {
        var pool = ProbePeerPool()
        for value in 1...6 { XCTAssertTrue(pool.offer(candidate(value))) }
        let slots = try (0..<4).map { _ in try XCTUnwrap(pool.reserveNext { _ in true }) }
        XCTAssertNil(pool.reserveNext { _ in true })
        XCTAssertEqual(pool.activeCount, 4)
        XCTAssertEqual(pool.waitingCount, 2)
        XCTAssertTrue(pool.release(slots[1]))
        let next = try XCTUnwrap(pool.reserveNext { _ in true })
        XCTAssertEqual(next.candidate.endpointID, "endpoint-5")
        XCTAssertTrue(pool.contains(slots[0]))
        XCTAssertTrue(pool.contains(slots[2]))
        XCTAssertTrue(pool.contains(slots[3]))
        XCTAssertFalse(pool.contains(slots[1]))
    }

    func testDiscoveryFloodAndDuplicateSessionsStayBounded() throws {
        var pool = ProbePeerPool()
        for value in 1...100 { _ = pool.offer(candidate(value)) }
        XCTAssertEqual(pool.waitingCount, 32)
        let first = try XCTUnwrap(pool.reserveNext { _ in true })
        XCTAssertFalse(pool.offer(candidate(1, endpoint: "duplicate-endpoint")))
        XCTAssertNil(pool.reserveIncoming(candidate(1, endpoint: "duplicate-endpoint")))
        XCTAssertTrue(pool.contains(first))
        XCTAssertEqual(pool.waitingCount, 31)
    }

    func testIncomingCapacityAndStaleReservationCannotReleaseReplacement() throws {
        var pool = ProbePeerPool()
        let old = try XCTUnwrap(pool.reserveIncoming(candidate(1)))
        XCTAssertTrue(pool.release(old))
        XCTAssertNil(pool.reserveIncoming(candidate(1)))
        XCTAssertFalse(pool.offer(candidate(1)))
        pool.reset()
        let replacement = try XCTUnwrap(pool.reserveIncoming(candidate(1)))
        XCTAssertNotEqual(old.generation, replacement.generation)
        XCTAssertFalse(pool.release(old))
        XCTAssertTrue(pool.contains(replacement))
        for value in 2...4 { XCTAssertNotNil(pool.reserveIncoming(candidate(value))) }
        XCTAssertNil(pool.reserveIncoming(candidate(5)))
    }

    func testLostWaitingCandidateAndBlockedPeerLeaveHealthyPeersAvailable() throws {
        var pool = ProbePeerPool()
        for value in 1...4 { _ = pool.offer(candidate(value)) }
        pool.removeWaiting(endpointID: "endpoint-2")
        let first = try XCTUnwrap(pool.reserveNext { $0.endpointID != "endpoint-1" })
        XCTAssertEqual(first.candidate.endpointID, "endpoint-3")
        XCTAssertEqual(pool.waitingCount, 2)
        pool.removeWaiting(endpointID: first.candidate.endpointID)
        XCTAssertTrue(pool.contains(first))
        pool.reset()
        XCTAssertEqual(pool.activeCount, 0)
        XCTAssertEqual(pool.waitingCount, 0)
        XCTAssertFalse(pool.contains(first))
        let next = try XCTUnwrap(pool.reserveIncoming(candidate(3)))
        XCTAssertNotEqual(next.generation, first.generation)
    }

    func testChangedQueuedIdentityRejectedAndPeerEndpointRefreshPreservesTurn() throws {
        var pool = ProbePeerPool()
        XCTAssertTrue(pool.offer(candidate(1)))
        XCTAssertTrue(pool.offer(candidate(2)))
        XCTAssertNil(pool.reserveIncoming(candidate(3, endpoint: "endpoint-1")))
        XCTAssertFalse(pool.offer(candidate(3, endpoint: "endpoint-1")))
        XCTAssertTrue(pool.offer(candidate(1, endpoint: "updated-endpoint")))
        let first = try XCTUnwrap(pool.reserveNext { _ in true })
        XCTAssertEqual(first.candidate.endpointID, "updated-endpoint")
        XCTAssertEqual(pool.waitingCount, 1)
    }

    func testRetirementBoundRequiresNewSDKGenerationBeforeFurtherAdmission() throws {
        var pool = ProbePeerPool()
        for value in 1...32 {
            let slot = try XCTUnwrap(pool.reserveIncoming(candidate(value)))
            XCTAssertTrue(pool.release(slot))
        }
        XCTAssertEqual(pool.retiredCount, 32)
        XCTAssertNil(pool.reserveIncoming(candidate(33)))
        pool.reset()
        XCTAssertNotNil(pool.reserveIncoming(candidate(33)))
    }
}
