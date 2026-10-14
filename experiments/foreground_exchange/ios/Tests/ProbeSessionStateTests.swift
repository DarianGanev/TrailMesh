import XCTest
@testable import TrailMeshTransportProbe

final class ProbeSessionStateTests: XCTestCase {
    private let local = String(repeating: "1", count: 32)
    private let remote = String(repeating: "2", count: 32)

    func testNoiseCannotEvictFinalEvidenceAndTruncationSurvivesCheckpoint() throws {
        var state = ProbeSessionState(sessionID: local, payloadSize: 2048)
        let timestamp = "2026-10-05T00:00:00Z"
        state.appendRecord(ProbeLogEntry(event: "session_started", observedAt: timestamp, fields: [:]))
        for _ in 0..<320 {
            state.appendRecord(ProbeLogEntry(event: "attempt_result", observedAt: timestamp, fields: [:]))
        }
        for _ in 0..<1000 {
            state.appendRecord(ProbeLogEntry(event: "invalid_probe_frame", observedAt: timestamp, fields: [:]))
        }
        XCTAssertEqual(state.records.count, 512)
        XCTAssertEqual(state.records.filter { $0.event == "attempt_result" }.count, 320)
        XCTAssertEqual(state.records.first?.event, "session_started")
        XCTAssertEqual(state.evictedRecords, 809)
        let restored = try JSONDecoder().decode(ProbeSessionState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.evictedRecords, 809)
        XCTAssertTrue(restored.isValid)
    }

    func testUnknownPeerSkipIsDeduplicatedAndDeduplicationIsBounded() throws {
        var state = ProbeSessionState(sessionID: local, payloadSize: 2048)
        for _ in 0..<1000 {
            state.appendRecord(ProbeLogEntry(event: "unknown_peer_skipped_journal_full", observedAt: "now",
                                             fields: ["peer_session_id": remote]))
        }
        XCTAssertEqual(state.records.count, 1)
        for value in 3...100 {
            state.appendRecord(ProbeLogEntry(event: "unknown_peer_skipped_journal_full", observedAt: "now",
                                             fields: ["peer_session_id": String(format: "%032x", value)]))
        }
        XCTAssertEqual(state.records.count, 64)
        XCTAssertEqual(state.skippedPeerSessionIDs?.count, 64)
        XCTAssertEqual(state.evictedRecords, 35)
        XCTAssertTrue(state.isValid)
    }

    func testOlderV2CheckpointWithoutDiagnosticCountersStillLoads() throws {
        let state = ProbeSessionState(sessionID: local, payloadSize: 2048)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        json.removeValue(forKey: "evictedRecords")
        json.removeValue(forKey: "skippedPeerSessionIDs")
        let restored = try JSONDecoder().decode(ProbeSessionState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(restored.evictedRecords)
        XCTAssertTrue(restored.isValid)
    }

    func testCheckpointKeepsUnacknowledgedAttemptIdentityAndTransmissionBudget() throws {
        var state = ProbeSessionState(sessionID: local, payloadSize: 2048)
        try state.bindPeer(remote)
        XCTAssertEqual(try state.beginTransmission(to: remote), 0)
        let restored = try JSONDecoder().decode(ProbeSessionState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.sessionID, local)
        XCTAssertEqual(restored.peer(remote)?.nextAttempt, 0)
        XCTAssertEqual(restored.peer(remote)?.transmissions, 1)
        XCTAssertTrue(restored.intendedActive)
    }

    func testDuplicateReceptionIsAcknowledgedWithoutCountingItAgain() throws {
        var state = ProbeSessionState(sessionID: local, payloadSize: 2048)
        try state.bindPeer(remote)
        XCTAssertTrue(try state.recordReceived(from: remote, attempt: 7))
        XCTAssertFalse(try state.recordReceived(from: remote, attempt: 7))
        XCTAssertEqual(state.peer(remote)?.receivedAttempts, [7])
        XCTAssertEqual(state.peer(remote)?.duplicates, 1)
    }

    func testOnlyMatchingAcknowledgementAdvancesAnAttempt() throws {
        var state = ProbeSessionState(sessionID: local, payloadSize: 2048)
        try state.bindPeer(remote)
        _ = try state.beginTransmission(to: remote)
        XCTAssertFalse(try state.finishAttempt(to: remote, attempt: 1, success: true))
        XCTAssertTrue(try state.finishAttempt(to: remote, attempt: 0, success: true))
        XCTAssertFalse(try state.finishAttempt(to: remote, attempt: 0, success: true))
        XCTAssertEqual(state.peer(remote)?.nextAttempt, 1)
        XCTAssertEqual(state.peer(remote)?.successful, 1)
    }

    func testThreeTransmissionsAreTheLimitAcrossReconnects() throws {
        var state = ProbeSessionState(sessionID: local, payloadSize: 2048)
        try state.bindPeer(remote)
        for _ in 0..<3 { XCTAssertEqual(try state.beginTransmission(to: remote), 0) }
        XCTAssertThrowsError(try state.beginTransmission(to: remote))
        XCTAssertTrue(try state.finishAttempt(to: remote, attempt: 0, success: false))
        XCTAssertEqual(try state.beginTransmission(to: remote), 1)
    }

    func testPeerOnlyCompletesAfterBothFinishControlsAreAcknowledged() throws {
        var state = ProbeSessionState(sessionID: local, payloadSize: 2048)
        try state.bindPeer(remote)
        for attempt in 0..<20 {
            _ = try state.beginTransmission(to: remote)
            _ = try state.finishAttempt(to: remote, attempt: attempt, success: true)
        }
        XCTAssertFalse(state.peer(remote)!.complete)
        try state.recordRemoteFinish(from: remote, successful: 18, failed: 2)
        try state.recordLocalFinishAcknowledgement(from: remote, successful: 20, failed: 0)
        XCTAssertFalse(state.peer(remote)!.complete)
        try state.recordRemoteFinishAcknowledgementDelivered(to: remote)
        XCTAssertTrue(state.peer(remote)!.complete)
        XCTAssertThrowsError(try state.recordLocalFinishAcknowledgement(from: remote, successful: 19, failed: 1))
    }

    func testJournalIsBoundedAndStopIntentionSurvivesReload() throws {
        var state = ProbeSessionState(sessionID: local, payloadSize: 2048)
        for value in 2...9 { try state.bindPeer(String(format: "%032x", value)) }
        XCTAssertThrowsError(try state.bindPeer(String(repeating: "a", count: 32)))
        state.intendedActive = false
        let restored = try JSONDecoder().decode(ProbeSessionState.self, from: JSONEncoder().encode(state))
        XCTAssertFalse(restored.intendedActive)
        XCTAssertEqual(restored.peers.count, 8)
    }

    func testRetryBackoffIsCappedAndForegroundRecoveryPreservesIntention() {
        XCTAssertEqual(ProbeRecoveryPolicy.delay(forRetry: 1), 1)
        XCTAssertEqual(ProbeRecoveryPolicy.delay(forRetry: 5), 16)
        XCTAssertEqual(ProbeRecoveryPolicy.delay(forRetry: 10), 30)
        XCTAssertTrue(ProbeRecoveryPolicy.canRetry(5))
        XCTAssertFalse(ProbeRecoveryPolicy.canRetry(6))
        XCTAssertTrue(ProbeRecoveryPolicy.shouldResume(intendedActive: true, foreground: true, transportRunning: false))
        XCTAssertFalse(ProbeRecoveryPolicy.shouldResume(intendedActive: false, foreground: true, transportRunning: false))
    }

    func testRejectsCorruptCheckpointBeforeRestoringRadios() throws {
        var state = ProbeSessionState(sessionID: local, payloadSize: 2048)
        try state.bindPeer(remote)
        XCTAssertTrue(state.isValid)
        state.peers[0].nextAttempt = 30
        XCTAssertFalse(state.isValid)
    }

    func testCorruptCounterCannotOverflowCheckpointValidation() throws {
        var state = ProbeSessionState(sessionID: local, payloadSize: 2048)
        try state.bindPeer(remote)
        state.peers[0].remoteSuccessful = Int.max
        state.peers[0].remoteFailed = Int.max
        XCTAssertFalse(state.isValid)
    }

    func testCompletedDateCannotMarkAnUnfinishedCheckpointComplete() throws {
        var state = ProbeSessionState(sessionID: local, payloadSize: 2048)
        try state.bindPeer(remote)
        state.peers[0].completedAt = Date()
        XCTAssertFalse(state.isValid)
    }

    func testLocalFinishAcknowledgementStillRequiresReciprocalDeadline() throws {
        var state = ProbeSessionState(sessionID: local, payloadSize: 2048)
        try state.bindPeer(remote)
        for attempt in 0..<20 {
            _ = try state.beginTransmission(to: remote)
            _ = try state.finishAttempt(to: remote, attempt: attempt, success: true)
        }
        try state.recordLocalFinishAcknowledgement(from: remote, successful: 20, failed: 0)
        XCTAssertTrue(state.peer(remote)!.needsReciprocalProgressDeadline)
        let unique = try state.recordReceived(from: remote, attempt: 0)
        XCTAssertTrue(ProbeRecoveryPolicy.shouldRenewReciprocalDeadline(uniqueReceived: unique, peer: state.peer(remote)!))
        let duplicate = try state.recordReceived(from: remote, attempt: 0)
        XCTAssertFalse(ProbeRecoveryPolicy.shouldRenewReciprocalDeadline(uniqueReceived: duplicate, peer: state.peer(remote)!))
        try state.recordRemoteFinish(from: remote, successful: 20, failed: 0)
        XCTAssertTrue(state.peer(remote)!.needsReciprocalProgressDeadline)
        try state.recordRemoteFinishAcknowledgementDelivered(to: remote)
        XCTAssertFalse(state.peer(remote)!.needsReciprocalProgressDeadline)
    }

    func testRepeatedFinishRequiresItsNewAcknowledgementBeforeDeparture() throws {
        var state = ProbeSessionState(sessionID: local, payloadSize: 2048)
        try state.bindPeer(remote)
        for attempt in 0..<20 {
            _ = try state.beginTransmission(to: remote)
            _ = try state.finishAttempt(to: remote, attempt: attempt, success: true)
        }
        try state.recordRemoteFinish(from: remote, successful: 20, failed: 0)
        try state.recordLocalFinishAcknowledgement(from: remote, successful: 20, failed: 0)
        try state.recordRemoteFinishAcknowledgementDelivered(to: remote)
        XCTAssertTrue(state.peer(remote)!.complete)
        try state.recordRemoteFinish(from: remote, successful: 20, failed: 0)
        XCTAssertFalse(state.peer(remote)!.complete)
        XCTAssertTrue(state.peer(remote)!.needsReciprocalProgressDeadline)
        XCTAssertNotNil(state.peer(remote)!.completedAt)
    }

    func testReconnectReplaysFinishWithoutLosingDataProgress() throws {
        var state = ProbeSessionState(sessionID: local, payloadSize: 2048)
        try state.bindPeer(remote)
        for attempt in 0..<20 {
            _ = try state.beginTransmission(to: remote)
            _ = try state.finishAttempt(to: remote, attempt: attempt, success: true)
        }
        try state.recordRemoteFinish(from: remote, successful: 20, failed: 0)
        try state.recordLocalFinishAcknowledgement(from: remote, successful: 20, failed: 0)
        try state.recordRemoteFinishAcknowledgementDelivered(to: remote)
        try state.prepareLink(to: remote)
        XCTAssertEqual(state.peer(remote)?.nextAttempt, 20)
        XCTAssertEqual(state.peer(remote)?.successful, 20)
        XCTAssertNotNil(state.peer(remote)?.completedAt)
        XCTAssertFalse(state.peer(remote)!.complete)
    }

    func testFailedCheckpointSavePreservesLastCommittedState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProbeCheckpointStore(url: directory.appendingPathComponent("checkpoint.json"))
        var committed = ProbeSessionState(sessionID: local, payloadSize: 2048)
        try committed.bindPeer(remote)
        try store.save(committed)
        var invalid = committed
        invalid.peers[0].nextAttempt = 100
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(try store.load()?.peer(remote)?.nextAttempt, 0)
    }

    func testRejectsOversizedCheckpointBeforeDecoding() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("checkpoint.json")
        try Data(repeating: 32, count: 256 * 1024 + 1).write(to: url)
        XCTAssertThrowsError(try ProbeCheckpointStore(url: url).load())
    }

    func testUnknownNinthPeerDoesNotStopEightUnfinishedPeers() throws {
        var state = ProbeSessionState(sessionID: local, payloadSize: 2048)
        let ids = (2...9).map { String(format: "%032x", $0) }
        for id in ids { try state.bindPeer(id) }
        XCTAssertThrowsError(try state.bindPeer(String(repeating: "a", count: 32)))
        XCTAssertFalse(state.shouldPauseForFullJournal)
        for id in ids {
            for attempt in 0..<20 {
                _ = try state.beginTransmission(to: id)
                _ = try state.finishAttempt(to: id, attempt: attempt, success: true)
            }
            try state.recordRemoteFinish(from: id, successful: 20, failed: 0)
            try state.recordLocalFinishAcknowledgement(from: id, successful: 20, failed: 0)
            try state.recordRemoteFinishAcknowledgementDelivered(to: id)
        }
        XCTAssertTrue(state.shouldPauseForFullJournal)
        try state.prepareLink(to: ids[0])
        XCTAssertNotNil(state.peer(ids[0])?.completedAt)
        XCTAssertFalse(state.shouldPauseForFullJournal)
    }
}
