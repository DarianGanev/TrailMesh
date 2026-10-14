package org.trailmesh.foregroundprobe

import org.junit.Assert.*
import org.junit.Test

class LinkExchangeTest {
    private val local = ProbePeerContext(ProbePlatform.ANDROID, "0".repeat(32), 2048)
    private val remote = ProbePeerContext(ProbePlatform.IOS, "1".repeat(32), 2048)
    private fun ready() = LinkExchange().apply {
        hello(ForegroundFrame.HelloMessage(remote.sessionID, local.sessionID, 2048, 20), local, remote)
    }

    @Test fun onlyOnePendingSendCanBeAcknowledgedByItsSessionAndIndex() {
        val link = ready()
        val digest = ForegroundFrame.sha256(byteArrayOf(1))
        link.beginSend(0, digest)
        assertThrows(IllegalArgumentException::class.java) { link.beginSend(1, digest) }
        assertFalse(link.matchesAck(ForegroundFrame.SessionAckMessage(remote.sessionID, 0, true, digest), local.sessionID))
        assertFalse(link.matchesAck(ForegroundFrame.SessionAckMessage(local.sessionID, 1, true, digest), local.sessionID))
        assertFalse(link.matchesAck(ForegroundFrame.SessionAckMessage(local.sessionID, 0, true, ByteArray(32)), local.sessionID))
        assertTrue(link.matchesAck(ForegroundFrame.SessionAckMessage(local.sessionID, 0, true, digest), local.sessionID))
        link.clearPending()
        assertFalse(link.matchesAck(ForegroundFrame.SessionAckMessage(local.sessionID, 0, true, digest), local.sessionID))
    }

    @Test fun lostFinishAckRequiresControlReplayAfterDisconnectWithoutRepeatingData() {
        val ledger = SessionLedger(SessionCheckpoint(local.sessionID, 2048)) {}
        ledger.selectPeer(remote.sessionID, "ios")
        repeat(20) { ledger.beginTransmission(remote.sessionID); ledger.completeOutgoing(remote.sessionID, true) }
        ledger.remoteFinished(remote.sessionID, 20, 0)
        val link = ready()
        link.remoteFinished()
        link.finishAckDelivered()
        assertFalse(link.canDepart(true)) // The peer's ACK of our FINISH was lost.
        val reconnected = ready()
        assertEquals(20, SessionLedger(ledger.checkpoint) {}.peer(remote.sessionID)!!.nextOutgoing)
        reconnected.remoteFinished()
        reconnected.finishAckDelivered()
        reconnected.finishAck(ForegroundFrame.FinishMessage(remote.sessionID, local.sessionID, true, 20, 0),
            local.sessionID, ledger.peer(remote.sessionID)!!)
        assertTrue(reconnected.canDepart(true))
        assertFalse(reconnected.canDepart(false))
    }

    @Test fun queuedFinishAckDoesNotPermitDepartureBeforeActualTransferSuccess() {
        val link = ready()
        val peer = PeerJournal(remote.sessionID, "ios", nextOutgoing = 20, successfulOutgoing = 20)
        link.remoteFinished()
        link.finishAck(ForegroundFrame.FinishMessage(remote.sessionID, local.sessionID, true, 20, 0), local.sessionID, peer)
        assertFalse(link.canDepart(true))
        link.finishAckDelivered()
        assertTrue(link.canDepart(true))
    }

    @Test fun replayFloodAndHelloMismatchAreBounded() {
        val link = LinkExchange()
        repeat(256) { assertTrue(link.acceptPacket()) }
        assertFalse(link.acceptPacket())
        assertThrows(IllegalArgumentException::class.java) {
            link.hello(ForegroundFrame.HelloMessage(remote.sessionID, "2".repeat(32), 2048, 20), local, remote)
        }
        assertFalse(link.helloReceived)
    }

    @Test fun repeatedFinishRequiresItsNewAcknowledgementBeforeDeparture() {
        val link = ready()
        val peer = PeerJournal(remote.sessionID, "ios", nextOutgoing = 20, successfulOutgoing = 20)
        link.remoteFinished()
        link.finishAck(ForegroundFrame.FinishMessage(remote.sessionID, local.sessionID, true, 20, 0), local.sessionID, peer)
        link.finishAckDelivered()
        assertTrue(link.canDepart(true))
        link.remoteFinished() // Peer retries FINISH during the departure grace period.
        assertFalse(link.canDepart(true))
        link.finishAckDelivered()
        assertTrue(link.canDepart(true))
    }
}
