package org.trailmesh.foregroundprobe

import org.junit.Assert.*
import org.junit.Test

class SessionLedgerTest {
    private val local = "0".repeat(32)
    private val remote = "1".repeat(32)

    @Test fun noiseCannotEvictSessionBoundaryOrFinalAttemptEvidence() {
        val ledger = SessionLedger(SessionCheckpoint(local, 2048)) {}
        ledger.record(ProbeEvent("session_started", "time"))
        repeat(320) { ledger.record(ProbeEvent("attempt_result", "time")) }
        repeat(1000) { ledger.record(ProbeEvent("invalid_probe_frame", "time")) }
        assertEquals(512, ledger.checkpoint.events.size)
        assertEquals("session_started", ledger.checkpoint.events.first().name)
        assertEquals(320, ledger.checkpoint.events.count { it.name == "attempt_result" })
        assertEquals(809L, ledger.checkpoint.evictedRecords)
    }

    @Test fun receiverPersistsBeforeReturningPositiveAcknowledgement() {
        val saved = mutableListOf<SessionCheckpoint>()
        val ledger = SessionLedger(SessionCheckpoint(local, 2048)) { saved.add(it) }
        ledger.selectPeer(remote, "ios")
        val result = ledger.receive(remote, 0, true)
        assertTrue(result.accepted)
        assertEquals(1, saved.last().peers.single().receivedAccepted)
        assertTrue(ledger.receive(remote, 0, true).duplicate)
        assertEquals(1, ledger.checkpoint.peers.single().receivedAccepted)
    }

    @Test fun failedPersistenceCannotAcceptBytesOrAdvanceSender() {
        var failing = false
        val ledger = SessionLedger(SessionCheckpoint(local, 2048)) {
            if (failing) throw java.io.IOException("disk unavailable")
        }
        ledger.selectPeer(remote, "ios")
        ledger.beginTransmission(remote)
        failing = true
        assertThrows(java.io.IOException::class.java) { ledger.receive(remote, 0, true) }
        assertEquals(0, ledger.checkpoint.peers.single().receivedAccepted)
        assertThrows(java.io.IOException::class.java) { ledger.completeOutgoing(remote, true) }
        assertEquals(0, ledger.checkpoint.peers.single().nextOutgoing)
    }

    @Test fun unacknowledgedAttemptAndTransmissionBudgetSurviveReconnectAndResume() {
        val ledger = SessionLedger(SessionCheckpoint(local, 8192)) {}
        ledger.selectPeer(remote, "android")
        repeat(3) { assertTrue(ledger.beginTransmission(remote)) }
        assertFalse(ledger.beginTransmission(remote))
        assertEquals(0, ledger.peer(remote)!!.nextOutgoing)
        val resumed = SessionLedger(ledger.checkpoint) {}
        assertFalse(resumed.beginTransmission(remote))
        resumed.completeOutgoing(remote, false)
        assertEquals(1, resumed.peer(remote)!!.nextOutgoing)
        assertEquals(1, resumed.peer(remote)!!.failedOutgoing)
        assertTrue(resumed.beginTransmission(remote))
    }

    @Test fun recoveryAndRosterAreFiniteAndCompletedPeersAreSkipped() {
        val ledger = SessionLedger(SessionCheckpoint(local, 256)) {}
        ledger.selectPeer(remote, "ios")
        repeat(5) { assertNotNull(ledger.nextRecovery(remote)) }
        assertNull(ledger.nextRecovery(remote))
        repeat(20) { ledger.beginTransmission(remote); ledger.completeOutgoing(remote, true) }
        ledger.remoteFinished(remote, 20, 0)
        ledger.markComplete(remote)
        assertNull(ledger.selectPeer(remote, "ios"))
        for (index in 2..8) assertNotNull(ledger.selectPeer(index.toString(16).padStart(32, '0'), "android"))
        assertNull(ledger.selectPeer("9".repeat(32), "android"))
        assertEquals(8, ledger.checkpoint.peers.size)
    }

    @Test fun differentSessionIndicesAndInvalidTotalsAreRejectedWithoutMutation() {
        val ledger = SessionLedger(SessionCheckpoint(local, 2048)) {}
        ledger.selectPeer(remote, "ios")
        assertThrows(IllegalArgumentException::class.java) { ledger.receive(local, 0, true) }
        assertThrows(IllegalArgumentException::class.java) { ledger.receive(remote, 20, true) }
        assertThrows(IllegalArgumentException::class.java) { ledger.remoteFinished(remote, 21, 0) }
        assertThrows(IllegalArgumentException::class.java) { ledger.markComplete(remote) }
        assertEquals(0, ledger.peer(remote)!!.receivedAccepted)
    }

    @Test fun stopClosesResumeCheckpointAndEventsStayBounded() {
        val ledger = SessionLedger(SessionCheckpoint(local, 2048)) {}
        repeat(600) { ledger.record(ProbeEvent("test", "time", mapOf("index" to "$it"))) }
        assertEquals(512, ledger.checkpoint.events.size)
        assertEquals("88", ledger.checkpoint.events.first().fields["index"])
        ledger.close()
        assertFalse(ledger.checkpoint.open)
    }

    @Test fun unsentAttemptCannotBeCompletedAndExplicitResumeRestoresRecoveryBudgetOnly() {
        val ledger = SessionLedger(SessionCheckpoint(local, 2048)) {}
        ledger.selectPeer(remote, "ios")
        assertThrows(IllegalArgumentException::class.java) { ledger.completeOutgoing(remote, true) }
        ledger.beginTransmission(remote)
        ledger.completeOutgoing(remote, true)
        ledger.beginTransmission(remote)
        ledger.receive(remote, 0, true)
        repeat(5) { ledger.nextRecovery(remote) }
        ledger.abandon(remote)
        ledger.resume()
        val peer = ledger.peer(remote)!!
        assertEquals(0, peer.recoveries)
        assertFalse(peer.exhausted)
        assertEquals(1, peer.nextOutgoing)
        assertEquals(1, peer.transmissions)
        assertEquals(1, peer.receivedAccepted)
    }

    @Test fun acceptanceAndSenderOutcomeCommitEvidenceTogetherWithTheirProgress() {
        val snapshots = mutableListOf<SessionCheckpoint>()
        val ledger = SessionLedger(SessionCheckpoint(local, 2048)) { snapshots.add(it) }
        ledger.selectPeer(remote, "ios")
        val receipt = ProbeEvent("payload_received", "time")
        ledger.receive(remote, 0, true, receipt)
        assertEquals(receipt, snapshots.last().events.last())
        assertEquals(1, snapshots.last().peers.single().receivedAccepted)
        ledger.beginTransmission(remote)
        val result = ProbeEvent("attempt_result", "time")
        ledger.completeOutgoing(remote, true, result)
        assertEquals(result, snapshots.last().events.last())
        assertEquals(1, snapshots.last().peers.single().successfulOutgoing)
    }

    @Test fun completedPeerCanReplayOnlyBoundedControlWithinOneMinute() {
        val ledger = SessionLedger(SessionCheckpoint(local, 2048)) {}
        ledger.selectPeer(remote, "ios")
        repeat(20) { ledger.beginTransmission(remote); ledger.completeOutgoing(remote, true) }
        ledger.remoteFinished(remote, 20, 0)
        ledger.markComplete(remote)
        val time = ledger.peer(remote)!!.completedAt
        assertTrue(ledger.canReplayCompletion(remote, time + 59_999))
        assertFalse(ledger.canReplayCompletion(remote, time + 60_001))
        repeat(3) { assertTrue(ledger.beginCompletionReplay(remote, time + 1)) }
        assertFalse(ledger.beginCompletionReplay(remote, time + 1))
        assertEquals(20, ledger.peer(remote)!!.nextOutgoing)
        assertEquals(0, ledger.peer(remote)!!.recoveries)
        assertNull(ledger.selectPeer(remote, "ios"))
        ledger.markComplete(remote)
        assertTrue(ledger.peer(remote)!!.completionReconciled)
        assertFalse(ledger.canReplayCompletion(remote, time + 2))
    }
}
